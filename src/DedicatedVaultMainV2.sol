// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {IDedicatedVenue, IDedicatedVenueV2} from "./interfaces/IDedicatedVenue.sol";

/// @dev Recovery surface added to the venue by B4-T1 (staged, resumable close and
/// stranded-position write-off). Declared here so Main can drive it without
/// changing the venue or its shared interface; `venue` is the sole caller the
/// venue trusts (`onlyController`).
interface IVenueRecovery {
    function closeUnstake(uint256 positionId) external;
    function closeDecrease(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;
    function closeCollect(uint256 positionId) external;
    function closeBurn(uint256 positionId) external;
    function writeOffStrandedPosition() external returns (uint256 strandedId);
}

/// @dev Minimal pool surface used to read the live spot price for the
/// spot-vs-oracle coherence gate. Reached via `venue.poolAddress()` so Main need
/// not be extended into the venue.
interface IV3PoolSpot {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint32, bool);
}
import {
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @notice Vault B MainV2 prototype. It is intentionally deployed halted and
/// direct-Pancake-only. Aggregator calldata is outside this contract's first
/// rollout; temporal slicing of paired/reward liquidation is supported (see
/// `liquidateAllWbnb` / `liquidateAllReward`).
contract DedicatedVaultMainV2 is AccessControl, ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96
    uint24 internal constant POOL_FEE = 100;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant VAULT_B_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;

    IERC20 public constant asset = IERC20(USDT);
    IERC20 public constant pairedToken = IERC20(WBNB);

    enum Mode {
        HALTED,
        OPERATING,
        CLOSED_TO_INVENTORY
    }
    enum JobKind {
        NONE,
        OPEN,
        CLOSE_TO_INVENTORY,
        LIQUIDATE_WBNB,
        LIQUIDATE_REWARD
    }
    enum JobStatus {
        NONE,
        ACTIVE,
        COMPLETED
    }
    enum WithdrawalStatus {
        NONE,
        REQUESTED,
        CLAIMED,
        CANCELED
    }

    struct Job {
        JobKind kind;
        JobStatus status;
        uint64 createdAt;
        uint64 completedAt;
        uint32 chunks;
        uint256 cumulativeInput;
        uint256 cumulativeOutput;
        uint256 cumulativeNotionalAsset;
    }

    struct WithdrawalRequest {
        uint256 assets;
        WithdrawalStatus status;
    }

    struct OpenParams {
        bytes32 jobId;
        int24 tickLower;
        int24 tickUpper;
        uint256 assetBudget;
        uint256 swapAssetIn;
        uint256 keeperPairedMinOut;
        uint256 deadline;
    }

    address public immutable vault;
    IDedicatedVenueV2 public immutable venue;
    IVaultBExecutionAdapterV2 public immutable executionAdapter;
    IVaultBPriceGuard public immutable priceGuard;
    IVaultBRewardExecutionAdapterV2 public immutable rewardExecutionAdapter;
    IVaultBRewardPriceGuard public immutable rewardPriceGuard;
    IERC20 public immutable rewardToken;

    uint16 public immutable mintLossBps;
    uint16 public immutable normalCloseLossBps;
    uint16 public immutable emergencyCloseLossBps;
    uint256 public immutable hardMaxActiveAssets;
    uint256 public immutable hardMaxSwapPerJob;
    uint256 public immutable hardDailySwapLimit;

    uint256 public canaryOpenCap;
    uint256 public swapPerJobCap;
    uint256 public dailySwapLimit;

    /// @notice Max allowed deviation of the live pool spot price from the oracle
    /// (Chainlink) price before a close is rejected. This is the missing guard: a
    /// flash swap moves spot but not the oracle, so |spot - oracle| catches
    /// manipulation while an honestly lagging TWAP (spot ~= oracle) passes. Never
    /// zero, capped hard. The emergency threshold is wider for guardian recovery.
    uint16 public constant HARD_MAX_SPOT_ORACLE_DEVIATION_BPS = 2_000;
    uint16 public maxSpotOracleDeviationBps;
    uint16 public emergencySpotOracleDeviationBps;
    /// @notice Allowed width (in ticks) of an opened position. A too-narrow range
    /// is trivially pushed out of range by a small spot move; there is also a hard
    /// ceiling so admin can never widen it without bound. Defaults are set in the
    /// constructor so the deploy signature is unchanged.
    int24 public constant HARD_MAX_TICK_WIDTH = 200_000;
    int24 public minTickWidth;
    int24 public maxTickWidth;

    /// @notice Residual paired-token (WBNB, 18 decimals) balance tolerated by
    /// `isWithdrawalReady()` and by `sweepPairedDust()`. WBNB and USDT are both
    /// plain BEP-20: anyone can raise this contract's balance with an ordinary
    /// `transfer`, so gating readiness on an exact-zero balance lets an outsider
    /// freeze all withdrawals for the cost of a 1-wei transfer. Derived from a
    /// ~$0.05 notional target at ~$600/BNB (this repo's own fork-time quote for
    /// the same WBNB/USDT pool is ~$640/BNB, see docs/launch-runbook.md):
    /// 0.05 / 600 ~= 8.33e-5 BNB, rounded to a clean 1e14 wei (0.0001 BNB, ~$0.06
    /// at $600/BNB). That is far below the smallest amount this contract ever
    /// moves on purpose (canaryOpenCap / swapPerJobCap are hundreds to
    /// thousands of USDT, see script/DeployVaultBV2.config.example.json) and
    /// far above typical BSC transfer gas cost (~$0.05-$0.30), so it cannot be
    /// used to write off a meaningful amount either.
    uint256 public constant PAIRED_DUST_TOLERANCE = 1e14; // 0.0001 WBNB (~$0.06 @ $600/BNB)

    /// @notice Residual reward-token (CAKE, 18 decimals) balance tolerated the
    /// same way. Derived from the same ~$0.05 notional target at ~$1.50/CAKE
    /// (current market price ~$1.43 rounded up): 0.05 / 1.5 ~= 0.0333 CAKE,
    /// rounded to a clean 3e16 wei (0.03 CAKE, ~$0.045 @ $1.50/CAKE).
    uint256 public constant REWARD_DUST_TOLERANCE = 3e16; // 0.03 CAKE (~$0.045 @ $1.50/CAKE)

    Mode public mode = Mode.HALTED;
    uint256 public activePositionId;
    /// @notice Live count of DEFAULT_ADMIN_ROLE holders, so the last one cannot
    /// renounce/revoke themselves and brick the vault (enableOperations is the
    /// only path back to OPERATING and it is admin-only).
    uint256 private _adminCount;
    /// @notice Sum of request-time asset hints. Informational only: queued
    /// redeemers remain exposed to NAV until claim, so the claim amount is
    /// supplied by the immutable strategy adapter at settlement time.
    uint256 public queuedWithdrawalAssets;
    uint256 public queuedWithdrawalCount;
    bool public withdrawalCycleCommitted;
    bool public withdrawalCycleBatchCommitted;
    uint256 public withdrawalCycleExecutionLoss;

    mapping(bytes32 => Job) public jobs;
    mapping(bytes32 => mapping(uint32 => bool)) public usedChunks;
    mapping(uint64 => uint256) public dailySwapNotional;
    mapping(bytes32 => WithdrawalRequest) public withdrawals;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidConfiguration();
    error NotVault();
    error OpensDisabled(Mode mode);
    error AdapterNotBound();
    error InvalidExecutionAdapter();
    error InvalidVenueIdentity();
    error PositionActive();
    error NoActivePosition();
    error InventoryPresent(uint256 pairedBalance);
    error RewardInventoryPresent(uint256 rewardBalance);
    error InventoryRemaining(uint256 pairedBalance);
    error RewardInventoryRemaining(uint256 rewardBalance);
    error SwapBelowFloor(uint256 floor, uint256 amountOut);
    error InvalidAmount();
    error InvalidDeadline();
    error CapitalCapExceeded(uint256 requested, uint256 cap);
    error SwapCapExceeded(uint256 requested, uint256 cap);
    error DailySwapCapExceeded(uint256 requested, uint256 cap);
    error InvalidJobId();
    error JobKindMismatch(JobKind expected, JobKind actual);
    error JobAlreadyCompleted();
    error DuplicateChunk(uint32 chunkIndex);
    error InvalidPositionId();
    error OpenNotTwoSided();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error TwapOutsideTickRange();
    error MintValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error InvalidTickWidthBounds();
    error CloseValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error SpotDivergedFromOracle(uint256 spotUsdtPerWbnb, uint256 oracleUsdtPerWbnb);
    error InvalidSpotOracleDeviation();
    error HaltedKeeperPath();
    error LastAdminCannotBeRemoved();
    error WithdrawalExists();
    error WithdrawalUnknown();
    error WithdrawalNotReady();
    error OutstandingWithdrawals(uint256 requests);
    error WithdrawalBatchCommitted();
    error WithdrawalBatchEmpty();
    error DustAboveTolerance(uint256 amount, uint256 tolerance);

    event ModeChanged(Mode indexed oldMode, Mode indexed newMode);
    event OperationalCapsUpdated(uint256 canaryOpenCap, uint256 swapPerJobCap, uint256 dailySwapLimit);
    event SpotOracleDeviationUpdated(uint16 maxBps, uint16 emergencyBps);
    event TickWidthBoundsUpdated(int24 minTickWidth, int24 maxTickWidth);
    event Funded(uint256 assets);
    event PositionOpened(bytes32 indexed jobId, uint256 indexed positionId, uint256 assetBudget, uint256 pairedOut);
    event PositionClosedToInventory(
        bytes32 indexed jobId,
        uint256 indexed positionId,
        uint256 assetReceived,
        uint256 pairedReceived,
        uint256 amount0Min,
        uint256 amount1Min,
        bool emergency
    );
    event WbnbLiquidated(bytes32 indexed jobId, uint256 amountIn, uint256 amountOut, bool emergency);
    event RewardLiquidated(bytes32 indexed jobId, uint256 amountIn, uint256 amountOut, bool emergency);
    event PositionForceUnstaked(uint256 indexed positionId);
    event VenueCloseStageRecovered(uint256 indexed positionId, uint8 stage);
    event VenuePositionWrittenOff(uint256 indexed positionId, uint256 strandedTokenId, bool inventoryReturned);
    event WithdrawalRequested(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCycleCommitted(uint256 requests);
    event WithdrawalExecutionLossRecorded(uint256 incrementalLoss, uint256 cumulativeLoss);
    event WithdrawalCycleCleared();
    event WithdrawalClaimed(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCanceled(bytes32 indexed requestId);
    event IdleWithdrawnToVault(uint256 assets);
    event DustSwept(address indexed token, uint256 amount);

    constructor(
        address vault_,
        IDedicatedVenueV2 venue_,
        IVaultBExecutionAdapterV2 executionAdapter_,
        IVaultBPriceGuard priceGuard_,
        IVaultBRewardExecutionAdapterV2 rewardExecutionAdapter_,
        IVaultBRewardPriceGuard rewardPriceGuard_,
        IERC20 rewardToken_,
        uint16 mintLossBps_,
        uint16 normalCloseLossBps_,
        uint16 emergencyCloseLossBps_,
        uint256 hardMaxActiveAssets_,
        uint256 hardMaxSwapPerJob_,
        uint256 hardDailySwapLimit_,
        uint256 initialCanaryOpenCap_,
        uint256 initialSwapPerJobCap_,
        uint256 initialDailySwapLimit_,
        address admin_,
        address keeper_,
        address guardian_
    ) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (
            vault_ == address(0) || address(venue_) == address(0) || address(executionAdapter_) == address(0)
                || address(priceGuard_) == address(0) || address(rewardExecutionAdapter_) == address(0)
                || address(rewardPriceGuard_) == address(0) || admin_ == address(0) || keeper_ == address(0)
                || guardian_ == address(0)
        ) revert ZeroAddress();
        if (
            address(rewardToken_) != CAKE || mintLossBps_ == 0 || mintLossBps_ >= BPS || normalCloseLossBps_ == 0
                || normalCloseLossBps_ >= BPS || emergencyCloseLossBps_ < normalCloseLossBps_
                || emergencyCloseLossBps_ >= BPS || hardMaxActiveAssets_ == 0 || hardMaxSwapPerJob_ == 0
                || hardDailySwapLimit_ == 0 || initialCanaryOpenCap_ == 0
                || initialCanaryOpenCap_ > hardMaxActiveAssets_ || initialSwapPerJobCap_ == 0
                || initialSwapPerJobCap_ > hardMaxSwapPerJob_ || initialDailySwapLimit_ == 0
                || initialDailySwapLimit_ > hardDailySwapLimit_
        ) revert InvalidConfiguration();

        vault = vault_;
        venue = venue_;
        executionAdapter = executionAdapter_;
        priceGuard = priceGuard_;
        rewardExecutionAdapter = rewardExecutionAdapter_;
        rewardPriceGuard = rewardPriceGuard_;
        rewardToken = rewardToken_;
        mintLossBps = mintLossBps_;
        normalCloseLossBps = normalCloseLossBps_;
        emergencyCloseLossBps = emergencyCloseLossBps_;
        hardMaxActiveAssets = hardMaxActiveAssets_;
        hardMaxSwapPerJob = hardMaxSwapPerJob_;
        hardDailySwapLimit = hardDailySwapLimit_;
        canaryOpenCap = initialCanaryOpenCap_;
        swapPerJobCap = initialSwapPerJobCap_;
        dailySwapLimit = initialDailySwapLimit_;
        maxSpotOracleDeviationBps = 200; // 2%
        emergencySpotOracleDeviationBps = 1_000; // 10% for guardian recovery
        minTickWidth = 2;
        maxTickWidth = 20_000;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, keeper_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function setOperationalCaps(uint256 openCap, uint256 perJobCap, uint256 perDayCap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            openCap == 0 || openCap > hardMaxActiveAssets || perJobCap == 0 || perJobCap > hardMaxSwapPerJob
                || perDayCap == 0 || perDayCap > hardDailySwapLimit
        ) revert InvalidConfiguration();
        canaryOpenCap = openCap;
        swapPerJobCap = perJobCap;
        dailySwapLimit = perDayCap;
        emit OperationalCapsUpdated(openCap, perJobCap, perDayCap);
    }

    function setSpotOracleDeviationBps(uint16 maxBps, uint16 emergencyBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            maxBps == 0 || emergencyBps < maxBps || emergencyBps > HARD_MAX_SPOT_ORACLE_DEVIATION_BPS
        ) revert InvalidSpotOracleDeviation();
        maxSpotOracleDeviationBps = maxBps;
        emergencySpotOracleDeviationBps = emergencyBps;
        emit SpotOracleDeviationUpdated(maxBps, emergencyBps);
    }

    function setTickWidthBounds(int24 minWidth, int24 maxWidth) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minWidth < 1 || maxWidth < minWidth || maxWidth > HARD_MAX_TICK_WIDTH) revert InvalidTickWidthBounds();
        minTickWidth = minWidth;
        maxTickWidth = maxWidth;
        emit TickWidthBoundsUpdated(minWidth, maxWidth);
    }

    function enableOperations() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            executionAdapter.main() != address(this) || rewardExecutionAdapter.main() != address(this)
                || venue.controller() != address(this)
        ) {
            revert AdapterNotBound();
        }
        if (address(executionAdapter.priceGuard()) != address(priceGuard)) revert InvalidExecutionAdapter();
        if (
            address(rewardExecutionAdapter.priceGuard()) != address(rewardPriceGuard)
                || rewardExecutionAdapter.rewardToken() != CAKE || rewardExecutionAdapter.asset() != USDT
        ) revert InvalidExecutionAdapter();
        if (
            address(venue.asset()) != USDT || address(venue.paired()) != WBNB || venue.fee() != POOL_FEE
                || venue.poolAddress() != VAULT_B_POOL
        ) revert InvalidVenueIdentity();
        if (activePositionId != 0) revert PositionActive();
        uint256 inventory = pairedToken.balanceOf(address(this));
        if (inventory != 0) revert InventoryPresent(inventory);
        if (address(rewardToken) != address(0)) {
            uint256 rewards = rewardToken.balanceOf(address(this));
            if (rewards != 0) revert RewardInventoryPresent(rewards);
        }
        if (queuedWithdrawalCount != 0) revert OutstandingWithdrawals(queuedWithdrawalCount);
        _setMode(Mode.OPERATING);
    }

    function halt() external onlyRole(GUARDIAN_ROLE) {
        _setMode(Mode.HALTED);
    }

    /// @dev Track admin count and forbid removing the last admin. renounceRole and
    /// revokeRole both route through _revokeRole, so this covers both.
    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) _adminCount++;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        if (role == DEFAULT_ADMIN_ROLE && _adminCount <= 1 && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert LastAdminCannotBeRemoved();
        }
        revoked = super._revokeRole(role, account);
        if (revoked && role == DEFAULT_ADMIN_ROLE) _adminCount--;
    }

    function fundFromVault(uint256 amount) external onlyVault nonReentrant {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (amount == 0) revert InvalidAmount();
        // The capital ceiling limits EXPOSURE, so it must not be fed the
        // revenue-conservative NAV (minimumOut haircut + B1-T5 min(twap,spot)),
        // which understates exposure and lets more in the more the position skews
        // out of USDT. Value the exposure at fair mid, taking the HIGHER of the
        // TWAP/spot geometry so the ceiling cannot be gamed by under-valuation.
        uint256 postFundAssets = _fundingExposureUsdt() + amount;
        if (postFundAssets > hardMaxActiveAssets) {
            revert CapitalCapExceeded(postFundAssets, hardMaxActiveAssets);
        }
        asset.safeTransferFrom(vault, address(this), amount);
        emit Funded(amount);
    }

    function requestWithdrawal(bytes32 requestId, uint256 amount) external onlyVault nonReentrant {
        if (requestId == bytes32(0)) revert InvalidAmount();
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        if (withdrawals[requestId].status != WithdrawalStatus.NONE) revert WithdrawalExists();
        withdrawals[requestId] = WithdrawalRequest(amount, WithdrawalStatus.REQUESTED);
        queuedWithdrawalAssets += amount;
        queuedWithdrawalCount += 1;
        emit WithdrawalRequested(requestId, amount);
    }

    /// @notice Irreversibly commits the current request batch to an inventory
    /// close. Request admission and commit are separate so a dust request cannot
    /// force an immediate vault-wide LP unwind.
    function commitWithdrawalCycle() external onlyVault nonReentrant {
        if (queuedWithdrawalCount == 0) revert WithdrawalBatchEmpty();
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        withdrawalCycleCommitted = true;
        withdrawalCycleBatchCommitted = true;
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        emit WithdrawalCycleCommitted(queuedWithdrawalCount);
    }

    /// @notice Settle a queued withdrawal at its claim-time ERC-4626 NAV.
    /// `amount` may differ from the request-time hint because the queued shares
    /// remain exposed to gains/losses until claim. Egress remains hard-bound to
    /// the immutable adapter (`vault`).
    function claimWithdrawal(bytes32 requestId, uint256 amount) external onlyVault nonReentrant returns (uint256) {
        WithdrawalRequest storage request = withdrawals[requestId];
        if (request.status == WithdrawalStatus.NONE) revert WithdrawalUnknown();
        if (request.status != WithdrawalStatus.REQUESTED) revert WithdrawalNotReady();
        if (!isWithdrawalReady()) revert WithdrawalNotReady();
        if (asset.balanceOf(address(this)) < amount) revert WithdrawalNotReady();
        request.status = WithdrawalStatus.CLAIMED;
        queuedWithdrawalAssets -= request.assets;
        queuedWithdrawalCount -= 1;
        if (queuedWithdrawalCount == 0 && withdrawalCycleCommitted) {
            withdrawalCycleCommitted = false;
            withdrawalCycleBatchCommitted = false;
            withdrawalCycleExecutionLoss = 0;
            emit WithdrawalCycleCleared();
        }
        if (amount != 0) asset.safeTransfer(vault, amount);
        emit WithdrawalClaimed(requestId, amount);
        return amount;
    }

    function cancelWithdrawal(bytes32 requestId) external onlyVault nonReentrant {
        if (withdrawalCycleCommitted) revert WithdrawalBatchCommitted();
        WithdrawalRequest storage request = withdrawals[requestId];
        if (request.status == WithdrawalStatus.NONE) revert WithdrawalUnknown();
        if (request.status != WithdrawalStatus.REQUESTED) revert WithdrawalNotReady();
        request.status = WithdrawalStatus.CANCELED;
        queuedWithdrawalAssets -= request.assets;
        queuedWithdrawalCount -= 1;
        emit WithdrawalCanceled(requestId);
    }

    /// @notice Synchronous ERC-4626 liquidity path. It is available only when
    /// inventory is fully USDT and no older async request can be bypassed.
    function withdrawIdleToVault(uint256 amount) external onlyVault nonReentrant returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (queuedWithdrawalCount != 0) revert OutstandingWithdrawals(queuedWithdrawalCount);
        if (!isWithdrawalReady() || asset.balanceOf(address(this)) < amount) revert WithdrawalNotReady();
        asset.safeTransfer(vault, amount);
        emit IdleWithdrawnToVault(amount);
        return amount;
    }

    function isWithdrawalReady() public view returns (bool) {
        if (activePositionId != 0 || pairedToken.balanceOf(address(this)) > PAIRED_DUST_TOLERANCE) return false;
        return address(rewardToken) == address(0) || rewardToken.balanceOf(address(this)) <= REWARD_DUST_TOLERANCE;
    }

    /// @notice Guardian-only sweep of a paired-token remainder at or below
    /// `PAIRED_DUST_TOLERANCE`. Recipient is hardcoded to `vault` — there is no
    /// address parameter, so this cannot be used to route funds anywhere else.
    /// Reverts above tolerance so it can never double as a limit-bypass path;
    /// a remainder above tolerance must go through `liquidateAllWbnb` instead.
    function sweepPairedDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256 amount) {
        amount = pairedToken.balanceOf(address(this));
        if (amount == 0) revert InvalidAmount();
        if (amount > PAIRED_DUST_TOLERANCE) revert DustAboveTolerance(amount, PAIRED_DUST_TOLERANCE);
        pairedToken.safeTransfer(vault, amount);
        emit DustSwept(address(pairedToken), amount);
    }

    /// @notice Guardian-only sweep of a reward-token remainder at or below
    /// `REWARD_DUST_TOLERANCE`. Same hardcoded-recipient and above-tolerance
    /// revert guarantees as `sweepPairedDust()`.
    function sweepRewardDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256 amount) {
        amount = rewardToken.balanceOf(address(this));
        if (amount == 0) revert InvalidAmount();
        if (amount > REWARD_DUST_TOLERANCE) revert DustAboveTolerance(amount, REWARD_DUST_TOLERANCE);
        rewardToken.safeTransfer(vault, amount);
        emit DustSwept(address(rewardToken), amount);
    }

    function openPosition(OpenParams calldata p)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 positionId)
    {
        Job storage job = _beginChunk(p.jobId, JobKind.OPEN, 0);
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (executionAdapter.main() != address(this)) revert AdapterNotBound();
        if (activePositionId != 0) revert PositionActive();
        uint256 inventory = pairedToken.balanceOf(address(this));
        if (inventory != 0) revert InventoryPresent(inventory);
        if (address(rewardToken) != address(0)) {
            uint256 rewards = rewardToken.balanceOf(address(this));
            if (rewards != 0) revert RewardInventoryPresent(rewards);
        }
        if (
            p.assetBudget == 0 || p.swapAssetIn == 0 || p.swapAssetIn >= p.assetBudget
                || p.assetBudget > asset.balanceOf(address(this))
        ) revert InvalidAmount();
        if (p.assetBudget > canaryOpenCap) revert CapitalCapExceeded(p.assetBudget, canaryOpenCap);

        // Bound the tick range and require it to straddle the TWAP price (not just
        // the manipulable spot) before spending anything.
        uint160 twapSqrt = _validateOpenTicks(p.tickLower, p.tickUpper);

        _reserveSwapNotional(job, p.swapAssetIn, false);

        asset.forceApprove(address(executionAdapter), p.swapAssetIn);
        uint256 pairedOut = executionAdapter.swapAssetToPaired(p.swapAssetIn, p.keeperPairedMinOut, p.deadline, false);
        asset.forceApprove(address(executionAdapter), 0);

        uint256 assetForMint = p.assetBudget - p.swapAssetIn;
        // Expected mint geometry at the TWAP price, NOT the spot preview minted
        // against the same block's spot (which is tautological — it holds at any
        // price). A leg that rounds to zero at TWAP is not genuinely two-sided.
        (uint256 assetExpected, uint256 pairedExpected) =
            _expectedMintAmountsAtTwap(assetForMint, pairedOut, p.tickLower, p.tickUpper, twapSqrt);
        if (assetExpected == 0 || pairedExpected == 0) revert OpenNotTwoSided();
        uint256 amount0Min = _boundedLpMinimum(assetExpected, mintLossBps);
        uint256 amount1Min = _boundedLpMinimum(pairedExpected, mintLossBps);

        // Aggregate mint floor, one basis for both sides (priceGuard.fairValue):
        // what the position actually consumes must be worth at least the TWAP-fair
        // value of the intended deposit less the mint-loss budget. A spot pushed to
        // the range edge makes the mint consume a skewed, lower-value ratio and
        // trips this. Both legs valued the same way — no second basis to diverge.
        uint256 mintFloor = FullMath.mulDiv(_fairInventoryValue(assetExpected, pairedExpected), BPS - mintLossBps, BPS);
        uint256 assetBeforeMint = asset.balanceOf(address(this));
        uint256 pairedBeforeMint = pairedToken.balanceOf(address(this));

        asset.forceApprove(address(venue), assetForMint);
        pairedToken.forceApprove(address(venue), pairedOut);
        positionId = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: assetForMint,
                pairedAmount: pairedOut,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: p.deadline
            })
        );
        asset.forceApprove(address(venue), 0);
        pairedToken.forceApprove(address(venue), 0);
        if (positionId == 0) revert InvalidPositionId();

        // Net decrease of each token across the mint = what the position consumed
        // (the venue returns any leftover to this contract during open()).
        uint256 assetConsumed = assetBeforeMint - asset.balanceOf(address(this));
        uint256 pairedConsumed = pairedBeforeMint - pairedToken.balanceOf(address(this));
        uint256 deployedValue = _fairInventoryValue(assetConsumed, pairedConsumed);
        if (deployedValue < mintFloor) revert MintValueBelowFloor(mintFloor, deployedValue);

        activePositionId = positionId;
        job.cumulativeInput = p.swapAssetIn;
        job.cumulativeOutput = pairedOut;
        _completeJob(job);
        emit PositionOpened(p.jobId, positionId, p.assetBudget, pairedOut);
    }

    function closeToInventory(bytes32 jobId, uint256 deadline, bool emergency) external nonReentrant {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        // A halt must stop routine keeper activity. The guardian emergency branch
        // and the B4-T2 recovery entrypoints stay open on purpose.
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.CLOSE_TO_INVENTORY, 0);
        if (deadline < block.timestamp || deadline > block.timestamp + 600) revert InvalidDeadline();

        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();

        // Validate Chainlink/TWAP coherence even when LP geometry is 100% USDT
        // and later inventory valuation has no WBNB leg. For emergency closes
        // this also proves the finite, expiring guardian budget is active.
        priceGuard.minimumOut(WBNB, USDT, 1e18, emergency);

        // The missing guard: reject the close if the live pool spot price has been
        // pushed away from the oracle (a flash swap moves spot, not Chainlink). An
        // honestly lagging TWAP leaves spot ~= oracle and passes. Runs before any
        // minimum is computed.
        _requireSpotOracleCoherence(emergency);

        // Value the floor on ONE basis: the spot composition (what the close will
        // realize) valued at the oracle. Comparing this to the actual proceeds
        // (also spot composition, oracle-valued) measures execution slippage, not
        // the TWAP-vs-oracle drift the old TWAP-composition floor conflated it with.
        (uint256 spotAssetExpected, uint256 spotPairedExpected) = venue.previewCloseAmounts(positionId);

        uint16 lossBps = emergency ? emergencyCloseLossBps : normalCloseLossBps;
        uint256 amount0Min = _boundedLpMinimum(spotAssetExpected, lossBps);
        uint256 amount1Min = _boundedLpMinimum(spotPairedExpected, lossBps);
        uint256 expectedFairValue = _fairInventoryValue(spotAssetExpected, spotPairedExpected);
        uint256 expectedExecutionValue =
            emergency ? _inventoryValue(spotAssetExpected, spotPairedExpected, true) : expectedFairValue;
        uint256 aggregateFloor = FullMath.mulDiv(expectedExecutionValue, BPS - lossBps, BPS);

        uint256 assetBefore = asset.balanceOf(address(this));
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        _commitWithdrawalCycleIfQueued();
        _setMode(Mode.CLOSED_TO_INVENTORY);
        activePositionId = 0;
        venue.close(positionId, amount0Min, amount1Min, deadline);
        uint256 assetReceived = asset.balanceOf(address(this)) - assetBefore;
        uint256 pairedReceived = pairedToken.balanceOf(address(this)) - pairedBefore;
        uint256 actualFairValue = _fairInventoryValue(assetReceived, pairedReceived);
        uint256 actualExecutionValue =
            emergency ? _inventoryValue(assetReceived, pairedReceived, true) : actualFairValue;
        if (actualExecutionValue < aggregateFloor) {
            revert CloseValueBelowFloor(aggregateFloor, actualExecutionValue);
        }
        _recordWithdrawalExecutionLoss(expectedFairValue, actualFairValue);

        job.cumulativeInput = expectedFairValue;
        job.cumulativeOutput = actualFairValue;
        _completeJob(job);
        emit PositionClosedToInventory(
            jobId, positionId, assetReceived, pairedReceived, amount0Min, amount1Min, emergency
        );
    }

    /// @notice Guardian recovery when Masterchef harvest is broken. This only
    /// recovers the NFT to the venue; bounded LP close and WBNB liquidation
    /// remain separate subsequent operations.
    function forceUnstakeSkipHarvest() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        _commitWithdrawalCycleIfQueued();
        venue.forceUnstakeSkipHarvest(positionId);
        emit PositionForceUnstaked(positionId);
    }

    // ── Emergency venue-close recovery (B4-T2) ───────────────────────────────
    // Thin guardian-only pass-throughs that make the venue's staged close and
    // stranded-position write-off (B4-T1) reachable in production. They do NOT
    // gate on mode: a stuck position typically coincides with a halt, and an
    // emergency path that switches off exactly when it is needed is no path at
    // all. They recompute nothing — Main's only bookkeeping is `activePositionId`
    // and the mode, reconciled explicitly where the position actually goes away
    // (burn and write-off), so NAV never counts a phantom position.

    function recoverCloseUnstake() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        // Pause the vault for the manual close, mirroring closeToInventory; never
        // weaken an existing HALTED.
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeUnstake(positionId);
        emit VenueCloseStageRecovered(positionId, 1);
    }

    function recoverCloseDecrease(uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeDecrease(positionId, amount0Min, amount1Min, deadline);
        emit VenueCloseStageRecovered(positionId, 2);
    }

    function recoverCloseCollect() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeCollect(positionId);
        emit VenueCloseStageRecovered(positionId, 3);
    }

    /// @notice Final stage: the position is burned and its proceeds are now Main
    /// inventory (identical end-state to a normal close), so `activePositionId` is
    /// cleared here — after this `totalAssetsUsdt()` values only real inventory.
    function recoverCloseBurn() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        IVenueRecovery(address(venue)).closeBurn(positionId);
        activePositionId = 0;
        emit VenueCloseStageRecovered(positionId, 4);
    }

    /// @notice Abandon a position whose close cannot complete. The venue frees its
    /// slot (returning the NFT to this contract if it was unstaked, or recording
    /// it as stranded-in-masterchef otherwise); Main drops it from its books so
    /// `totalAssetsUsdt()` stops valuing it — a written-off position is not counted
    /// as NAV, phantom or otherwise. Any LP value still trapped in a returned NFT
    /// is deliberately excluded until an admin realizes it, never over-counted.
    /// Forces HALTED: a write-off is a serious abnormal event and must require an
    /// explicit admin review (enableOperations) before trading resumes.
    function writeOffStrandedPosition() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        uint256 stranded = IVenueRecovery(address(venue)).writeOffStrandedPosition();
        activePositionId = 0;
        _setMode(Mode.HALTED);
        bool inventoryReturned = pairedToken.balanceOf(address(this)) != pairedBefore;
        emit VenuePositionWrittenOff(positionId, stranded, inventoryReturned);
    }

    /// @notice Direct-Pancake liquidation of paired-token inventory. `chunkIndex`
    /// and `finalChunk` support draining a remainder whose notional exceeds this
    /// job's per-job cap headroom over several calls: when the current balance
    /// does not fit under the remaining headroom, this call swaps only the
    /// slice that does and leaves the rest for a later chunk (same job while
    /// headroom remains, a fresh jobId once it is exhausted). `finalChunk`
    /// asserts the balance has been driven down to `PAIRED_DUST_TOLERANCE` and
    /// completes the job. `_reserveSwapNotional`'s per-job and per-day caps are
    /// evaluated exactly as before on every call, so a chunk series only
    /// changes how a job's notional is split across calls, never the caps
    /// themselves — in particular the daily cap still accumulates across every
    /// chunk of every job, so a series of small calls cannot exceed it.
    function liquidateAllWbnb(
        bytes32 jobId,
        uint32 chunkIndex,
        uint256 keeperMinOut,
        uint256 deadline,
        bool finalChunk,
        bool emergency
    ) external nonReentrant returns (uint256 amountOut) {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_WBNB, chunkIndex);

        uint256 balance = pairedToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        uint256 notional = priceGuard.fairValue(WBNB, USDT, balance);
        uint256 amountIn = balance;
        // Slice down to per-job headroom only on a non-final chunk. A final
        // chunk whose notional exceeds the cap still reverts SwapCapExceeded in
        // `_reserveSwapNotional` (single-call cap semantics unchanged); an
        // oversized residual is drained by issuing one or more non-final chunks
        // first, then a final chunk once the remainder fits under the cap.
        if (notional > headroom && !finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            // fairValue is linear in amountIn, so scaling amountIn down by
            // headroom/notional scales the resulting notional down to fit.
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = priceGuard.fairValue(WBNB, USDT, amountIn);
        }
        _reserveSwapNotional(job, notional, emergency);

        pairedToken.forceApprove(address(executionAdapter), amountIn);
        amountOut = executionAdapter.swapPairedToAsset(amountIn, keeperMinOut, deadline, emergency);
        pairedToken.forceApprove(address(executionAdapter), 0);
        // Oracle floor on the realized output, computed from the price guard's
        // own swap budget for the amount actually swapped THIS chunk (post-slice
        // amountIn) — the same rule the execution adapter enforces, so the two
        // floors cannot diverge (a wider guard budget no longer DoS's a
        // legitimate liquidation, and an expired/unarmed emergency budget makes
        // the guard revert here too).
        uint256 floor = priceGuard.minimumOut(WBNB, USDT, amountIn, emergency);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (finalChunk) {
            uint256 remaining = pairedToken.balanceOf(address(this));
            if (remaining > PAIRED_DUST_TOLERANCE) revert InventoryRemaining(remaining);
            _completeJob(job);
        }
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
        emit WbnbLiquidated(jobId, amountIn, amountOut, emergency);
    }

    /// @notice Direct-Pancake liquidation of all canonical CAKE reward inventory.
    /// It is a separate durable job so reward failures cannot block LP close or
    /// WBNB realization. Chunking follows the same headroom-based slicing as
    /// `liquidateAllWbnb`; see that function's NatSpec for the mechanics and the
    /// daily-cap preservation argument.
    function liquidateAllReward(
        bytes32 jobId,
        uint32 chunkIndex,
        uint256 keeperMinOut,
        uint256 deadline,
        bool finalChunk,
        bool emergency
    ) external nonReentrant returns (uint256 amountOut) {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_REWARD, chunkIndex);

        uint256 balance = rewardToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        uint256 notional = rewardPriceGuard.fairValue(balance);
        uint256 amountIn = balance;
        // Slice only on a non-final chunk; a final chunk over the cap still
        // reverts SwapCapExceeded (see liquidateAllWbnb for the rationale).
        if (notional > headroom && !finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = rewardPriceGuard.fairValue(amountIn);
        }
        _reserveSwapNotional(job, notional, emergency);

        rewardToken.forceApprove(address(rewardExecutionAdapter), amountIn);
        amountOut = rewardExecutionAdapter.swapRewardToAsset(amountIn, keeperMinOut, deadline, emergency);
        rewardToken.forceApprove(address(rewardExecutionAdapter), 0);
        // Oracle floor from the reward guard's own swap budget for the amount
        // swapped THIS chunk (post-slice amountIn); see liquidateAllWbnb.
        uint256 floor = rewardPriceGuard.minimumOut(amountIn, emergency);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (finalChunk) {
            uint256 remaining = rewardToken.balanceOf(address(this));
            if (remaining > REWARD_DUST_TOLERANCE) revert RewardInventoryRemaining(remaining);
            _completeJob(job);
        }
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
        emit RewardLiquidated(jobId, amountIn, amountOut, emergency);
    }

    function totalAssetsUsdt() public view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        uint256 paired = pairedToken.balanceOf(address(this));
        if (paired != 0) total += priceGuard.minimumOut(WBNB, USDT, paired, false);
        if (activePositionId != 0) {
            // A one-sided-USDT position would otherwise bypass the oracle
            // cross-check because there is no WBNB amount to value below.
            priceGuard.minimumOut(WBNB, USDT, 1e18, false);
            // Value the position on both the TWAP and the spot composition (each
            // at the oracle) and take the LOWER. A spot manipulation inflates one
            // composition; min() takes the other, so NAV never inflates in either
            // direction. NOTE: min() can UNDER-value NAV on an honest TWAP/spot
            // divergence — that dilutes incoming depositors rather than exiting
            // holders, the opposite of the risk we guard, and deposits are frozen
            // while a redeem cycle is committed. Deliberate and accepted.
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = twapAsset + (twapPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, twapPaired, false) : 0);
            uint256 spotValue = spotAsset + (spotPaired != 0 ? priceGuard.minimumOut(WBNB, USDT, spotPaired, false) : 0);
            total += twapValue < spotValue ? twapValue : spotValue;
        }
        uint256 rewards = rewardToken.balanceOf(address(this));
        if (rewards != 0) total += rewardPriceGuard.minimumOut(rewards, false);
    }

    function rewardInventory() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    /// @notice Exposure of the strategy in USDT for the capital ceiling: fair-mid
    /// valued (no minimumOut haircut) and, for the active position, the HIGHER of
    /// the TWAP/spot geometry. Both choices point the same way — never understate
    /// exposure — the opposite of the revenue-conservative `totalAssetsUsdt`.
    function _fundingExposureUsdt() internal view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        uint256 paired = pairedToken.balanceOf(address(this));
        if (paired != 0) total += priceGuard.fairValue(WBNB, USDT, paired);
        if (activePositionId != 0) {
            priceGuard.minimumOut(WBNB, USDT, 1e18, false); // oracle coherence, as in NAV
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 twapAsset, uint256 twapPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            (uint256 spotAsset, uint256 spotPaired) = venue.previewCloseAmounts(activePositionId);
            uint256 twapValue = _fairInventoryValue(twapAsset, twapPaired);
            uint256 spotValue = _fairInventoryValue(spotAsset, spotPaired);
            total += twapValue > spotValue ? twapValue : spotValue;
        }
        uint256 rewards = rewardToken.balanceOf(address(this));
        if (rewards != 0) total += rewardPriceGuard.fairValue(rewards);
    }

    function _inventoryValue(uint256 assetAmount, uint256 pairedAmount, bool emergency)
        internal
        view
        returns (uint256 value)
    {
        value = assetAmount;
        if (pairedAmount != 0) {
            value += emergency
                ? priceGuard.minimumOut(WBNB, USDT, pairedAmount, true)
                : priceGuard.fairValue(WBNB, USDT, pairedAmount);
        }
    }

    function _fairInventoryValue(uint256 assetAmount, uint256 pairedAmount) internal view returns (uint256 value) {
        value = assetAmount;
        if (pairedAmount != 0) value += priceGuard.fairValue(WBNB, USDT, pairedAmount);
    }

    /// @notice Revert if the live pool spot price deviates from the oracle price
    /// by more than the allowed band. Reads spot from the pool via the venue;
    /// oracle price is the guard's fair USDT value of 1 WBNB.
    function _requireSpotOracleCoherence(bool emergency) internal view {
        uint256 oracleUsdtPerWbnb = priceGuard.fairValue(WBNB, USDT, 1e18);
        if (oracleUsdtPerWbnb == 0) revert SpotDivergedFromOracle(0, 0);
        (uint160 spotSqrt,,,,,,) = IV3PoolSpot(venue.poolAddress()).slot0();
        uint256 spotUsdtPerWbnb = _usdtPerWbnbFromSqrt(spotSqrt);
        uint256 diff =
            spotUsdtPerWbnb > oracleUsdtPerWbnb ? spotUsdtPerWbnb - oracleUsdtPerWbnb : oracleUsdtPerWbnb - spotUsdtPerWbnb;
        uint16 tol = emergency ? emergencySpotOracleDeviationBps : maxSpotOracleDeviationBps;
        if (FullMath.mulDiv(diff, BPS, oracleUsdtPerWbnb) > tol) {
            revert SpotDivergedFromOracle(spotUsdtPerWbnb, oracleUsdtPerWbnb);
        }
    }

    /// @notice USDT (18 dec) per 1e18 WBNB implied by a pool sqrtPriceX96. The
    /// pool is USDT(token0)/WBNB(token1), so price(token1/token0)=(sqrt/2^96)^2 is
    /// WBNB per USDT; its inverse, scaled by 1e18, is USDT per WBNB.
    function _usdtPerWbnbFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 tmp = FullMath.mulDiv(Q96, Q96, sqrtPriceX96); // 2^192 / sqrt
        return FullMath.mulDiv(tmp, 1e18, sqrtPriceX96); // (2^192/sqrt) * 1e18 / sqrt
    }

    function _boundedLpMinimum(uint256 expected, uint16 lossBps) internal pure returns (uint256) {
        if (expected == 0) return 0;
        uint256 minimum = FullMath.mulDiv(expected, BPS - lossBps, BPS);
        return minimum == 0 ? 1 : minimum;
    }

    /// @notice Validate the requested tick range and return the TWAP sqrt price.
    /// The range must have a bounded width and strictly straddle the TWAP price,
    /// so a manipulated spot cannot steer the keeper into a degenerate or
    /// out-of-range mint.
    function _validateOpenTicks(int24 tickLower, int24 tickUpper) internal view returns (uint160 twapSqrt) {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        int24 width = tickUpper - tickLower;
        if (width < minTickWidth || width > maxTickWidth) revert InvalidTickRange(tickLower, tickUpper);
        twapSqrt = priceGuard.twapSqrtPriceX96();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        if (twapSqrt <= sqrtLower || twapSqrt >= sqrtUpper) revert TwapOutsideTickRange();
    }

    /// @notice Amounts the mint would consume for `assetDesired`/`pairedDesired`
    /// evaluated at the TWAP price. Same geometry the venue previews, but anchored
    /// to TWAP rather than the current spot.
    function _expectedMintAmountsAtTwap(
        uint256 assetDesired,
        uint256 pairedDesired,
        int24 tickLower,
        int24 tickUpper,
        uint160 twapSqrt
    ) internal pure returns (uint256 assetExpected, uint256 pairedExpected) {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(twapSqrt, sqrtA, sqrtB, assetDesired, pairedDesired);
        (assetExpected, pairedExpected) = LiquidityAmounts.getAmountsForLiquidity(twapSqrt, sqrtA, sqrtB, liquidity);
    }

    function _beginChunk(bytes32 jobId, JobKind kind, uint32 chunkIndex) internal returns (Job storage job) {
        if (jobId == bytes32(0)) revert InvalidJobId();
        job = jobs[jobId];
        if (job.status == JobStatus.NONE) {
            job.kind = kind;
            job.status = JobStatus.ACTIVE;
            job.createdAt = uint64(block.timestamp);
        } else {
            if (job.kind != kind) revert JobKindMismatch(job.kind, kind);
            if (job.status == JobStatus.COMPLETED) revert JobAlreadyCompleted();
        }
        if (usedChunks[jobId][chunkIndex]) revert DuplicateChunk(chunkIndex);
        usedChunks[jobId][chunkIndex] = true;
        job.chunks += 1;
    }

    function _completeJob(Job storage job) internal {
        job.status = JobStatus.COMPLETED;
        job.completedAt = uint64(block.timestamp);
    }

    function _reserveSwapNotional(Job storage job, uint256 notional, bool emergency) internal {
        uint256 jobTotal = job.cumulativeNotionalAsset + notional;
        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        if (jobTotal > jobCap) revert SwapCapExceeded(jobTotal, jobCap);
        job.cumulativeNotionalAsset = jobTotal;

        // Always ACCOUNT the day's turnover, including emergency volume, so a
        // subsequent normal swap sees what the emergency already spent. Only the
        // daily-LIMIT check is skipped for emergencies (a deliberate relief); the
        // accounting blindness was not deliberate.
        uint64 day = uint64(block.timestamp / 1 days);
        uint256 dayTotal = dailySwapNotional[day] + notional;
        if (!emergency && dayTotal > dailySwapLimit) revert DailySwapCapExceeded(dayTotal, dailySwapLimit);
        dailySwapNotional[day] = dayTotal;
    }

    function _setMode(Mode newMode) internal {
        Mode oldMode = mode;
        mode = newMode;
        emit ModeChanged(oldMode, newMode);
    }

    /// @notice Auto-commit the queued batch when a keeper begins an inventory
    /// close with requests outstanding. This mirrors the explicit
    /// `commitWithdrawalCycle`: both the commit flag AND the batch flag are set
    /// together. Setting only the commit flag would leave the batch flag false,
    /// which (a) silently disables the execution-loss journal for the very close
    /// that motivates the cycle and (b) bricks a later `commitWithdrawalCycle`
    /// (it reverts forever on the one-way commit guard). The vault's batch
    /// settlement also requires the batch flag, so the two flags must move
    /// together on every commit path.
    function _commitWithdrawalCycleIfQueued() internal {
        if (queuedWithdrawalCount == 0 || withdrawalCycleCommitted) return;
        withdrawalCycleCommitted = true;
        withdrawalCycleBatchCommitted = true;
        emit WithdrawalCycleCommitted(queuedWithdrawalCount);
    }

    function _recordWithdrawalExecutionLoss(uint256 expected, uint256 actual) internal {
        if (!withdrawalCycleBatchCommitted || actual >= expected) return;
        uint256 incremental = expected - actual;
        withdrawalCycleExecutionLoss += incremental;
        emit WithdrawalExecutionLossRecorded(incremental, withdrawalCycleExecutionLoss);
    }
}
