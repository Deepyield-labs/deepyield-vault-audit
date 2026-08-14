// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {IDedicatedVenue, IDedicatedVenueV2} from "./interfaces/IDedicatedVenue.sol";

interface IVaultBWithdrawalCycleCommitReceiver {
    function prepareWithdrawalCycleCommit() external;
}

import {
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {MainV2Geometry} from "./libraries/MainV2Geometry.sol";
import {MainV2Valuation} from "./libraries/MainV2Valuation.sol";
import {JobKind, JobStatus, Job, MainV2Jobs} from "./libraries/MainV2Jobs.sol";
import {MainV2Liquidation, LiqParams} from "./libraries/MainV2Liquidation.sol";
import {MainV2Open, OpenCall, SwapChunkCall} from "./libraries/MainV2Open.sol";
import {MainV2Inventory, CloseInventoryCall, CloseInventoryResult} from "./libraries/MainV2Inventory.sol";

/// @notice Vault B MainV2 prototype. It is intentionally deployed halted and
/// direct-Pancake-only. Aggregator calldata is outside this contract's first
/// rollout; temporal slicing of paired/reward liquidation is supported (see
/// `liquidateAllWbnb` / `liquidateAllReward`).
contract DedicatedVaultMainV2 is AccessControl, ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant BPS = 10_000;
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
    enum WithdrawalStatus {
        NONE,
        REQUESTED,
        CLAIMED,
        CANCELED
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
    address public immutable redeemVault;
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

    /// @notice Residual canonical WBNB inventory tolerated by the withdrawal
    /// readiness gate. External ERC-20 donations are unaccounted and inert;
    /// canonical inventory above this line takes the bounded, oracle-floor
    /// liquidation route. 0.0001 WBNB = 1e14 wei (~$0.06 at $600/BNB).
    uint256 public constant PAIRED_DUST_TOLERANCE = 1e14; // 0.0001 WBNB (~$0.06 @ $600/BNB)

    /// @notice Residual canonical CAKE inventory tolerated by the withdrawal
    /// readiness gate. Direct CAKE donations remain unaccounted and inert.
    uint256 public constant REWARD_DUST_TOLERANCE = 3e16; // 0.03 CAKE (~$0.045 @ $1.50/CAKE)

    Mode public mode = Mode.HALTED;
    uint256 public activePositionId;
    /// @notice Canonical WBNB inventory observed through Main's own open/close/
    /// recovery paths. Direct ERC-20 transfers are deliberately not counted.
    uint256 public accountedPairedInventory;
    /// @notice Canonical CAKE inventory observed through Main's own close/
    /// recovery paths. Direct ERC-20 transfers are deliberately not counted.
    uint256 public accountedRewardInventory;
    /// @notice The single in-progress open series (B9-T1). openSwapChunk fixes it on
    /// the first chunk and refuses any other jobId until the series is minted or
    /// explicitly cancelled, so `canaryOpenCap` (accumulated per job) is the true
    /// AGGREGATE bound on the swap leg — a second jobId can no longer reset it.
    bytes32 public activeOpenJobId;

    /// @notice Immutable context of the in-progress open series (B11-T1). Captured by
    /// reserveOpenSeries BEFORE the first swap so the FULL position budget — not just
    /// the swap leg — is bounded by canaryOpenCap, the ticks are validated up front,
    /// and the mint deadline has an upper bound. openPosition must match it exactly;
    /// cancelOpenSeries clears it.
    struct OpenSeriesContext {
        uint256 assetBudget;
        uint256 swapLeg;
        int24 tickLower;
        int24 tickUpper;
        uint64 deadlineCeiling;
        bool set;
    }

    OpenSeriesContext public openSeriesContext;
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
    error NotRedeemVault();
    error OpensDisabled(Mode mode);
    error AdapterNotBound();
    error InvalidExecutionAdapter();
    error InvalidVenueIdentity();
    error PositionActive();
    error NoActivePosition();
    error InventoryPresent(uint256 pairedBalance);
    error OpenSeriesActive(bytes32 activeJobId);
    error NoActiveOpenSeries();
    error OpenSeriesContextMismatch();
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
    error NonSequentialChunk(uint32 provided, uint32 expected);
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
    error InventorySweepDisabled();
    error InventoryDeltaMismatch(uint256 reported, uint256 observed);

    event ModeChanged(Mode indexed oldMode, Mode indexed newMode);
    event OperationalCapsUpdated(uint256 canaryOpenCap, uint256 swapPerJobCap, uint256 dailySwapLimit);
    event SpotOracleDeviationUpdated(uint16 maxBps, uint16 emergencyBps);
    event TickWidthBoundsUpdated(int24 minTickWidth, int24 maxTickWidth);
    event Funded(uint256 assets);
    event PositionOpened(bytes32 indexed jobId, uint256 indexed positionId, uint256 assetBudget, uint256 pairedOut);
    event OpenSwapChunkExecuted(bytes32 indexed jobId, uint32 chunkIndex, uint256 amountIn, uint256 pairedOut);
    event OpenSeriesReserved(
        bytes32 indexed jobId, uint256 assetBudget, int24 tickLower, int24 tickUpper, uint256 deadlineCeiling
    );
    event OpenSeriesCancelled(bytes32 indexed jobId);
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

    constructor(
        address vault_,
        address redeemVault_,
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
            vault_ == address(0) || redeemVault_ == address(0) || address(venue_) == address(0)
                || address(executionAdapter_) == address(0) || address(priceGuard_) == address(0)
                || address(rewardExecutionAdapter_) == address(0) || address(rewardPriceGuard_) == address(0)
                || admin_ == address(0) || keeper_ == address(0) || guardian_ == address(0)
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
        redeemVault = redeemVault_;
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
        if (maxBps == 0 || emergencyBps < maxBps || emergencyBps > HARD_MAX_SPOT_ORACLE_DEVIATION_BPS) {
            revert InvalidSpotOracleDeviation();
        }
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
        // Liveness is determined by inventory Main observed through canonical
        // protocol calls, never by a permissionless ERC-20 donation.
        if (accountedPairedInventory > PAIRED_DUST_TOLERANCE) {
            revert InventoryPresent(accountedPairedInventory);
        }
        if (accountedRewardInventory > REWARD_DUST_TOLERANCE) {
            revert RewardInventoryPresent(accountedRewardInventory);
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
        _cancelWithdrawal(requestId);
    }

    function cancelWithdrawalFromVault(bytes32 requestId) external nonReentrant returns (bool canceled) {
        if (msg.sender != redeemVault) revert NotRedeemVault();
        _cancelWithdrawal(requestId);
        return true;
    }

    function _cancelWithdrawal(bytes32 requestId) internal {
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
        return activePositionId == 0 && accountedPairedInventory <= PAIRED_DUST_TOLERANCE
            && accountedRewardInventory <= REWARD_DUST_TOLERANCE;
    }

    /// @notice Disabled: `vault` accounts only for USDT, so forwarding WBNB to
    /// it would strand the token. The bounded raw-balance liquidation path is
    /// the recovery route for any unaccounted balance.
    function sweepPairedDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256) {
        revert InventorySweepDisabled();
    }

    /// @notice Disabled for the same reason as `sweepPairedDust`: the USDT vault
    /// cannot safely receive or account for CAKE.
    function sweepRewardDust() external onlyRole(GUARDIAN_ROLE) nonReentrant returns (uint256) {
        revert InventorySweepDisabled();
    }

    /// @notice Phase 1 of a chunked open (B8-T1): swap `amountIn` USDT to WBNB and
    /// accumulate it for the open series `jobId`. A swap leg larger than
    /// @notice B11-T1: reserve an open series before any swap. Fixes the immutable
    /// context (full budget, ticks, mint-deadline ceiling) and bounds the FULL
    /// position budget by canaryOpenCap HERE — the old design capped the swap leg in
    /// phase 1 and the budget in phase 2, measuring different quantities against one
    /// cap, so a swap leg equal to the cap could never be minted. Ticks are validated
    /// up front, so a bad range is rejected before any funds move.
    function reserveOpenSeries(
        bytes32 jobId,
        uint256 assetBudget,
        uint256 swapLeg,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadlineCeiling
    ) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (jobId == bytes32(0)) revert InvalidJobId();
        if (activeOpenJobId != bytes32(0)) revert OpenSeriesActive(activeOpenJobId);
        if (assetBudget == 0) revert InvalidAmount();
        if (assetBudget > canaryOpenCap) revert CapitalCapExceeded(assetBudget, canaryOpenCap);
        // B11-T1: fix the swap leg STRICTLY below the budget so the mint leg
        // (assetBudget - swapLeg) is positive BY CONSTRUCTION. Chunks are bounded by
        // swapLeg (below), so a series can never swap the whole budget.
        if (swapLeg == 0 || swapLeg >= assetBudget) revert InvalidAmount();
        if (deadlineCeiling < block.timestamp || deadlineCeiling > type(uint64).max) revert InvalidDeadline();
        // Validate the ticks against the live TWAP BEFORE the first swap (was phase-2-only).
        uint160 twapSqrt = priceGuard.twapSqrtPriceX96();
        MainV2Geometry.validateOpenTicks(tickLower, tickUpper, minTickWidth, maxTickWidth, twapSqrt);
        // Positive is not sufficient: a dust-sized remainder can still round one CL
        // leg to zero and make phase 2 permanently unmintable. Prove the RESERVED
        // plan is two-sided using the guard's conservative paired output before any
        // swap. Runtime phase 2 repeats the check against the actual accumulated leg.
        uint256 pairedMinimum = priceGuard.minimumOut(address(asset), address(pairedToken), swapLeg, false);
        (uint256 assetExpected, uint256 pairedExpected) = MainV2Geometry.expectedMintAmountsAtTwap(
            assetBudget - swapLeg, pairedMinimum, tickLower, tickUpper, twapSqrt
        );
        if (assetExpected == 0 || pairedExpected == 0) revert OpenNotTwoSided();
        activeOpenJobId = jobId;
        openSeriesContext = OpenSeriesContext({
            assetBudget: assetBudget,
            swapLeg: swapLeg,
            tickLower: tickLower,
            tickUpper: tickUpper,
            // Safe because values above uint64 max are rejected before assignment.
            // forge-lint: disable-next-line(unsafe-typecast)
            deadlineCeiling: uint64(deadlineCeiling),
            set: true
        });
        emit OpenSeriesReserved(jobId, assetBudget, tickLower, tickUpper, deadlineCeiling);
    }

    /// swapPerJobCap is filled over several chunks; openPosition then mints from the
    /// accumulated inventory. Body in the linked MainV2Open (delegatecall). Main
    /// keeps the role + mode gate; opening (including accumulation) is OPERATING-only
    /// — an aborted series is drained by liquidateAllWbnb, so it cannot lock funds.
    /// A series must be reserved (reserveOpenSeries) before the first chunk.
    function openSwapChunk(bytes32 jobId, uint32 chunkIndex, uint256 amountIn, uint256 keeperMinOut, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 pairedOut)
    {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        // Exactly one open series may accumulate at a time (B9-T1). The first chunk
        // fixes the series; any other jobId is refused until it is minted or
        // cancelled. Set before the swap so the whole tx (and this reservation) is
        // atomic — a reverting chunk unwinds the reservation too.
        // B11-T1: the series must be reserved first (reserveOpenSeries), which fixed
        // the full-budget context and the jobId. openSwapChunk no longer opens a
        // series implicitly, so no swap can run before the budget and ticks are bound.
        bytes32 active = activeOpenJobId;
        if (active == bytes32(0)) revert NoActiveOpenSeries();
        if (active != jobId) revert OpenSeriesActive(active);
        // The swap leg is bounded by the RESERVED position budget (itself <= canaryOpenCap),
        // enforced inside MainV2Open AFTER chunk-sequencing so a duplicate/sparse chunk
        // still reports its own error rather than the budget bound.
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        pairedOut = MainV2Open.openSwapChunk(
            jobs,
            usedChunks,
            dailySwapNotional,
            executionAdapter,
            asset,
            SwapChunkCall(
                jobId,
                chunkIndex,
                amountIn,
                keeperMinOut,
                deadline,
                activePositionId,
                openSeriesContext.swapLeg,
                swapPerJobCap,
                dailySwapLimit
            )
        );
        uint256 pairedAfter = pairedToken.balanceOf(address(this));
        accountedPairedInventory = MainV2Inventory.creditObserved(accountedPairedInventory, pairedBefore, pairedAfter);
        uint256 observedOut = pairedAfter - pairedBefore;
        if (pairedOut != observedOut) revert InventoryDeltaMismatch(pairedOut, observedOut);
        emit OpenSwapChunkExecuted(jobId, chunkIndex, amountIn, pairedOut);
    }

    /// @notice Phase 2 of a chunked open: mint from the WBNB accumulated by
    /// openSwapChunk for `p.jobId`. No swap here. `p.swapAssetIn` /
    /// `p.keeperPairedMinOut` are unused (kept for ABI stability). Body in the
    /// linked MainV2Open (delegatecall); Main keeps the role + mode gate, records
    /// the position id and emits.
    function openPosition(OpenParams calldata p)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 positionId)
    {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        // The mint may only finalize the in-progress series and is its sole normal
        // terminator; clearing the wrong series would strand the lock (B9-T1).
        if (p.jobId != activeOpenJobId || p.jobId == bytes32(0)) revert NoActiveOpenSeries();
        // B11-T1: the mint must finalize the RESERVED series with the same budget and
        // ticks — phase 2 cannot bring its own parameters and slip past the reserve.
        OpenSeriesContext memory ctx = openSeriesContext;
        if (
            !ctx.set || p.assetBudget != ctx.assetBudget || p.tickLower != ctx.tickLower || p.tickUpper != ctx.tickUpper
        ) revert OpenSeriesContextMismatch();
        // Mint deadline is bounded above (was unbounded): by the series ceiling fixed
        // at reserve, and — like closeToInventory — to block.timestamp + 600 so a stale
        // signed mint cannot execute far in the future.
        if (p.deadline < block.timestamp || p.deadline > block.timestamp + 600) revert InvalidDeadline();
        if (p.deadline > ctx.deadlineCeiling) revert InvalidDeadline();
        _requireSpotOracleCoherence(false);
        uint256 pairedAcquired;
        uint256 pairedConsumed;
        (positionId, pairedAcquired, pairedConsumed) = MainV2Open.openPosition(
            jobs,
            priceGuard,
            venue,
            asset,
            pairedToken,
            OpenCall(
                p.jobId,
                p.tickLower,
                p.tickUpper,
                p.assetBudget,
                p.deadline,
                activePositionId,
                canaryOpenCap,
                minTickWidth,
                maxTickWidth,
                mintLossBps
            )
        );
        accountedPairedInventory = MainV2Inventory.debitConsumed(accountedPairedInventory, pairedConsumed);
        activePositionId = positionId;
        activeOpenJobId = bytes32(0);
        delete openSeriesContext; // B11-T1: context lives and dies with the series
        emit PositionOpened(p.jobId, positionId, p.assetBudget, pairedAcquired);
    }

    /// @notice Release the open-series lock for an ABORTED series (B9-T1). Allowed
    /// only once the accumulated paired inventory has been drained to dust (via
    /// liquidateAllWbnb), so a cancel cannot become another cap bypass: without the
    /// drain check an operator could swap up to the cap, cancel, and repeat. The
    /// job is marked COMPLETED so its chunks cannot be reused.
    function cancelOpenSeries(bytes32 jobId) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (jobId == bytes32(0) || jobId != activeOpenJobId) revert NoActiveOpenSeries();
        if (accountedPairedInventory > PAIRED_DUST_TOLERANCE) revert InventoryPresent(accountedPairedInventory);
        activeOpenJobId = bytes32(0);
        delete openSeriesContext; // B11-T1: a cancelled series leaves no budget to inherit
        MainV2Jobs.completeJob(jobs[jobId]);
        emit OpenSeriesCancelled(jobId);
    }

    function closeToInventory(bytes32 jobId, uint256 deadline, bool emergency) external nonReentrant {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        // A halt must stop routine keeper activity. The guardian emergency branch
        // and the B4-T2 recovery entrypoints stay open on purpose.
        if (!emergency && mode == Mode.HALTED) revert HaltedKeeperPath();
        Job storage job = MainV2Jobs.beginChunk(jobs, usedChunks, jobId, JobKind.CLOSE_TO_INVENTORY, 0);
        if (deadline < block.timestamp || deadline > block.timestamp + 600) revert InvalidDeadline();

        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        _commitWithdrawalCycleIfQueued();
        // A guardian may close from HALTED, but that action only removes LP
        // exposure. It must not implicitly restore a keeper-operable mode.
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        activePositionId = 0;
        CloseInventoryResult memory closeResult = MainV2Inventory.closeAndCredit(
            venue,
            priceGuard,
            asset,
            pairedToken,
            rewardToken,
            CloseInventoryCall({
                positionId: positionId,
                deadline: deadline,
                emergency: emergency,
                normalCloseLossBps: normalCloseLossBps,
                emergencyCloseLossBps: emergencyCloseLossBps,
                maxSpotOracleDeviationBps: maxSpotOracleDeviationBps,
                emergencySpotOracleDeviationBps: emergencySpotOracleDeviationBps,
                accountedPaired: accountedPairedInventory,
                accountedReward: accountedRewardInventory
            })
        );
        accountedPairedInventory = closeResult.nextAccountedPaired;
        accountedRewardInventory = closeResult.nextAccountedReward;
        _recordWithdrawalExecutionLoss(closeResult.expectedFairValue, closeResult.actualFairValue);

        job.cumulativeInput = closeResult.expectedFairValue;
        job.cumulativeOutput = closeResult.actualFairValue;
        MainV2Jobs.completeJob(job);
        emit PositionClosedToInventory(
            jobId,
            positionId,
            closeResult.assetReceived,
            closeResult.pairedReceived,
            closeResult.amount0Min,
            closeResult.amount1Min,
            emergency
        );
    }

    /// @notice Guardian recovery when Masterchef harvest is broken. This only
    /// recovers the NFT to the venue; bounded LP close and WBNB liquidation
    /// remain separate subsequent operations.
    function forceUnstakeSkipHarvest() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        _commitWithdrawalCycleIfQueued();
        (accountedPairedInventory, accountedRewardInventory) = MainV2Inventory.forceUnstakeAndCredit(
            venue, pairedToken, rewardToken, positionId, accountedPairedInventory, accountedRewardInventory
        );
        emit PositionForceUnstaked(positionId);
    }

    // ── Emergency venue-close recovery (B4-T2) ───────────────────────────────
    // Thin guardian-only pass-throughs that make the venue's staged close and
    // stranded-position write-off (B4-T1) reachable in production. They do NOT
    // gate on mode: a stuck position typically coincides with a halt, and an
    // emergency path that switches off exactly when it is needed is no path at
    // all. Stage 2 additionally derives its execution minima from the live
    // venue preview and PriceGuard; Main's only position bookkeeping is
    // `activePositionId` and the mode, reconciled explicitly where the position
    // actually goes away (burn and write-off), so NAV never counts a phantom.

    function recoverCloseUnstake() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        // Freeze the redeem batch BEFORE the first irreversible venue step (B9-T2):
        // unstaking begins the staged close, so from here the proportion between
        // those who exit and those who stay is fixed and queued requests can no
        // longer be cancelled — exactly as a normal closeToInventory does. No-op
        // when the queue is empty, so the emergency path stays passable.
        _commitWithdrawalCycleIfQueued();
        // Pause the vault for the manual close, mirroring closeToInventory; never
        // weaken an existing HALTED.
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        (accountedPairedInventory, accountedRewardInventory) = MainV2Inventory.closeUnstakeAndCredit(
            address(venue), pairedToken, rewardToken, positionId, accountedPairedInventory, accountedRewardInventory
        );
        emit VenueCloseStageRecovered(positionId, 1);
    }

    /// @notice Decrease the unstaked LP with Main-derived minima. The two legacy
    /// minimum arguments remain in the ABI for callers already encoded against
    /// V2, but cannot weaken the oracle / geometry floor: calldata minima are
    /// applied only when stricter than Main's derived values. This one-shot,
    /// non-swap stage reads the emergency policy but leaves budget consumption
    /// to the later pinned execution adapter that actually trades inventory.
    function recoverCloseDecrease(uint256 callerAmount0Min, uint256 callerAmount1Min, uint256 deadline)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (deadline < block.timestamp || deadline > block.timestamp + 600) revert InvalidDeadline();
        (uint256 amount0Min, uint256 amount1Min) = MainV2Inventory.recoveryDecreaseMinimums(
            venue,
            priceGuard,
            positionId,
            normalCloseLossBps,
            emergencyCloseLossBps,
            maxSpotOracleDeviationBps,
            emergencySpotOracleDeviationBps
        );
        // Calldata can tighten the execution condition, never relax it.
        if (callerAmount0Min > amount0Min) amount0Min = callerAmount0Min;
        if (callerAmount1Min > amount1Min) amount1Min = callerAmount1Min;
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        (accountedPairedInventory, accountedRewardInventory) = MainV2Inventory.closeDecreaseAndCredit(
            address(venue),
            pairedToken,
            rewardToken,
            positionId,
            amount0Min,
            amount1Min,
            deadline,
            accountedPairedInventory,
            accountedRewardInventory
        );
        emit VenueCloseStageRecovered(positionId, 2);
    }

    function recoverCloseCollect() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        (accountedPairedInventory, accountedRewardInventory) = MainV2Inventory.closeCollectAndCredit(
            address(venue), pairedToken, rewardToken, positionId, accountedPairedInventory, accountedRewardInventory
        );
        emit VenueCloseStageRecovered(positionId, 3);
    }

    /// @notice Final stage: the position is burned and its proceeds are now Main
    /// inventory (identical end-state to a normal close), so `activePositionId` is
    /// cleared here — after this `totalAssetsUsdt()` values only real inventory.
    function recoverCloseBurn() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();
        if (mode == Mode.OPERATING) _setMode(Mode.CLOSED_TO_INVENTORY);
        (accountedPairedInventory, accountedRewardInventory) = MainV2Inventory.closeBurnAndCredit(
            address(venue), pairedToken, rewardToken, positionId, accountedPairedInventory, accountedRewardInventory
        );
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
        // A write-off is irreversible; freeze the redeem batch first (B9-T2) so a
        // queued request cannot be cancelled after the position is abandoned. The
        // abandoned LP value is deliberately excluded from NAV and not measurable
        // here, so no discrete close-loss is recorded — see the report. No-op on an
        // empty queue.
        _commitWithdrawalCycleIfQueued();
        uint256 pairedBefore;
        uint256 stranded;
        (stranded, accountedPairedInventory, accountedRewardInventory, pairedBefore) = MainV2Inventory.writeOffAndCredit(
            address(venue), pairedToken, rewardToken, accountedPairedInventory, accountedRewardInventory
        );
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
        // Body in the linked MainV2Liquidation (EIP-170); it runs via delegatecall,
        // so token balances/approvals and the mapping pointers act on this
        // contract. Main keeps the role/halt gate and the loss journal + event.
        uint256 amountIn;
        uint256 notional;
        (amountOut, amountIn, notional) = MainV2Liquidation.liquidateWbnb(
            jobs,
            usedChunks,
            dailySwapNotional,
            pairedToken,
            executionAdapter,
            priceGuard,
            LiqParams(
                jobId,
                chunkIndex,
                keeperMinOut,
                deadline,
                finalChunk,
                emergency,
                hardMaxActiveAssets,
                swapPerJobCap,
                dailySwapLimit,
                PAIRED_DUST_TOLERANCE
            )
        );
        accountedPairedInventory = MainV2Inventory.debitConsumed(accountedPairedInventory, amountIn);
        _recordWithdrawalExecutionLoss(notional, amountOut);
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
        // Body in the linked MainV2Liquidation (EIP-170), same delegatecall
        // arrangement as liquidateAllWbnb.
        uint256 amountIn;
        uint256 notional;
        (amountOut, amountIn, notional) = MainV2Liquidation.liquidateReward(
            jobs,
            usedChunks,
            dailySwapNotional,
            rewardToken,
            rewardExecutionAdapter,
            rewardPriceGuard,
            LiqParams(
                jobId,
                chunkIndex,
                keeperMinOut,
                deadline,
                finalChunk,
                emergency,
                hardMaxActiveAssets,
                swapPerJobCap,
                dailySwapLimit,
                REWARD_DUST_TOLERANCE
            )
        );
        accountedRewardInventory = MainV2Inventory.debitConsumed(accountedRewardInventory, amountIn);
        _recordWithdrawalExecutionLoss(notional, amountOut);
        emit RewardLiquidated(jobId, amountIn, amountOut, emergency);
    }

    /// @notice Revenue-conservative NAV in USDT (minimumOut haircut + the LOWER of
    /// the TWAP/spot geometry for the active position). Computation lives in the
    /// linked `MainV2Valuation` (EIP-170); all balances/state are read here and
    /// passed in. min() can UNDER-value NAV on an honest TWAP/spot divergence,
    /// which dilutes incoming depositors (frozen while a redeem cycle is
    /// committed), the opposite of the risk we guard — deliberate and accepted.
    function totalAssetsUsdt() public view returns (uint256) {
        (uint256 pairedBalance, uint256 rewardBalance) = _recognizedInventoryBalances();
        return MainV2Valuation.totalAssetsUsdt(
            venue,
            priceGuard,
            rewardPriceGuard,
            asset.balanceOf(address(this)),
            pairedBalance,
            rewardBalance,
            activePositionId
        );
    }

    /// @notice Deposit-conservative NAV (B10-T2): same oracle-valued legs as
    /// `totalAssetsUsdt`, but the active position uses the HIGHER of the TWAP/spot
    /// geometry so a downward spot push cannot under-value NAV and mint a depositor
    /// cheap shares. Consumed only by the vault's deposit/mint pricing; redemptions,
    /// reporting and the async claim keep using the min-based `totalAssetsUsdt`.
    function totalAssetsUsdtUpper() public view returns (uint256) {
        (uint256 pairedBalance, uint256 rewardBalance) = _recognizedInventoryBalances();
        return MainV2Valuation.totalAssetsUsdtUpper(
            venue,
            priceGuard,
            rewardPriceGuard,
            asset.balanceOf(address(this)),
            pairedBalance,
            rewardBalance,
            activePositionId
        );
    }

    function rewardInventory() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    /// @notice Exposure of the strategy in USDT for the capital ceiling: fair-mid
    /// valued (no minimumOut haircut) and, for the active position, the HIGHER of
    /// the TWAP/spot geometry. Both choices point the same way — never understate
    /// exposure — the opposite of the revenue-conservative `totalAssetsUsdt`.
    function _fundingExposureUsdt() internal view returns (uint256) {
        (uint256 pairedBalance, uint256 rewardBalance) = _recognizedInventoryBalances();
        return MainV2Valuation.fundingExposureUsdt(
            venue,
            priceGuard,
            rewardPriceGuard,
            asset.balanceOf(address(this)),
            pairedBalance,
            rewardBalance,
            activePositionId
        );
    }

    function _recognizedInventoryBalances() internal view returns (uint256 pairedBalance, uint256 rewardBalance) {
        return MainV2Inventory.recognizedBalances(
            pairedToken, rewardToken, accountedPairedInventory, accountedRewardInventory
        );
    }

    /// @notice Revert if the live pool spot price deviates from the oracle price
    /// by more than the allowed band. Reads spot from the pool via the venue;
    /// oracle price is the guard's fair USDT value of 1 WBNB.
    function _requireSpotOracleCoherence(bool emergency) internal view {
        MainV2Valuation.requireSpotOracleCoherence(
            venue, priceGuard, maxSpotOracleDeviationBps, emergencySpotOracleDeviationBps, emergency
        );
    }

    // Pure tick/LP geometry (`usdtPerWbnbFromSqrt`, `boundedLpMinimum`,
    // `validateOpenTicks`, `expectedMintAmountsAtTwap`) moved verbatim to the
    // linked library `MainV2Geometry` to keep `Main` under EIP-170. Behaviour is
    // unchanged; the TWAP/state reads stay on this side and are passed in.

    // Job lifecycle + chunk accounting (`beginChunk`/`completeJob`/
    // `reserveSwapNotional`) moved verbatim to the linked library `MainV2Jobs`
    // (EIP-170). Behaviour is unchanged; the jobs/usedChunks/dailySwapNotional
    // mappings are passed by storage reference and the caps by value.

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
        IVaultBWithdrawalCycleCommitReceiver(vault).prepareWithdrawalCycleCommit();
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
