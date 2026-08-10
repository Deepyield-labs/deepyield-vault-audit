// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDedicatedVenue, IDedicatedVenueV2} from "./interfaces/IDedicatedVenue.sol";
import {
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "./interfaces/IVaultBExecutionV2.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @notice Vault B MainV2 prototype. It is intentionally deployed halted and
/// direct-Pancake-only. Aggregator calldata and temporal slicing are outside
/// this contract's first rollout.
contract DedicatedVaultMainV2 is AccessControl, ReentrancyGuard {
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

    Mode public mode = Mode.HALTED;
    uint256 public activePositionId;
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
    error InvalidAmount();
    error InvalidDeadline();
    error CapitalCapExceeded(uint256 requested, uint256 cap);
    error SwapCapExceeded(uint256 requested, uint256 cap);
    error DailySwapCapExceeded(uint256 requested, uint256 cap);
    error InvalidJobId();
    error JobKindMismatch(JobKind expected, JobKind actual);
    error JobAlreadyCompleted();
    error DuplicateChunk(uint32 chunkIndex);
    error SlicingDisabled();
    error InvalidPositionId();
    error OpenNotTwoSided();
    error CloseValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error WithdrawalExists();
    error WithdrawalUnknown();
    error WithdrawalNotReady();
    error OutstandingWithdrawals(uint256 requests);
    error WithdrawalBatchCommitted();
    error WithdrawalBatchEmpty();

    event ModeChanged(Mode indexed oldMode, Mode indexed newMode);
    event OperationalCapsUpdated(uint256 canaryOpenCap, uint256 swapPerJobCap, uint256 dailySwapLimit);
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
    event WithdrawalRequested(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCycleCommitted(uint256 requests);
    event WithdrawalExecutionLossRecorded(uint256 incrementalLoss, uint256 cumulativeLoss);
    event WithdrawalCycleCleared();
    event WithdrawalClaimed(bytes32 indexed requestId, uint256 assets);
    event WithdrawalCanceled(bytes32 indexed requestId);
    event IdleWithdrawnToVault(uint256 assets);

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

    function fundFromVault(uint256 amount) external onlyVault nonReentrant {
        if (mode != Mode.OPERATING) revert OpensDisabled(mode);
        if (amount == 0) revert InvalidAmount();
        uint256 postFundAssets = totalAssetsUsdt() + amount;
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
        if (activePositionId != 0 || pairedToken.balanceOf(address(this)) != 0) return false;
        return address(rewardToken) == address(0) || rewardToken.balanceOf(address(this)) == 0;
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

        _reserveSwapNotional(job, p.swapAssetIn, false);

        asset.forceApprove(address(executionAdapter), p.swapAssetIn);
        uint256 pairedOut = executionAdapter.swapAssetToPaired(p.swapAssetIn, p.keeperPairedMinOut, p.deadline, false);
        asset.forceApprove(address(executionAdapter), 0);

        uint256 assetForMint = p.assetBudget - p.swapAssetIn;
        (uint256 assetExpected, uint256 pairedExpected) =
            venue.previewOpenAmounts(assetForMint, pairedOut, p.tickLower, p.tickUpper);
        if (assetExpected == 0 || pairedExpected == 0) revert OpenNotTwoSided();
        uint256 amount0Min = _boundedLpMinimum(assetExpected, mintLossBps);
        uint256 amount1Min = _boundedLpMinimum(pairedExpected, mintLossBps);

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

        activePositionId = positionId;
        job.cumulativeInput = p.swapAssetIn;
        job.cumulativeOutput = pairedOut;
        _completeJob(job);
        emit PositionOpened(p.jobId, positionId, p.assetBudget, pairedOut);
    }

    function closeToInventory(bytes32 jobId, uint256 deadline, bool emergency) external nonReentrant {
        if (emergency) _checkRole(GUARDIAN_ROLE, msg.sender);
        else _checkRole(KEEPER_ROLE, msg.sender);
        Job storage job = _beginChunk(jobId, JobKind.CLOSE_TO_INVENTORY, 0);
        if (deadline < block.timestamp || deadline > block.timestamp + 600) revert InvalidDeadline();

        uint256 positionId = activePositionId;
        if (positionId == 0) revert NoActivePosition();

        // Validate Chainlink/TWAP coherence even when LP geometry is 100% USDT
        // and later inventory valuation has no WBNB leg. For emergency closes
        // this also proves the finite, expiring guardian budget is active.
        priceGuard.minimumOut(WBNB, USDT, 1e18, emergency);

        (uint256 spotAssetExpected, uint256 spotPairedExpected) = venue.previewCloseAmounts(positionId);
        uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
        (uint256 twapAssetExpected, uint256 twapPairedExpected) =
            venue.previewCloseAmountsAtSqrtPrice(positionId, twapSqrtPrice);

        uint16 lossBps = emergency ? emergencyCloseLossBps : normalCloseLossBps;
        uint256 amount0Min = _boundedLpMinimum(spotAssetExpected, lossBps);
        uint256 amount1Min = _boundedLpMinimum(spotPairedExpected, lossBps);
        uint256 expectedFairValue = _fairInventoryValue(twapAssetExpected, twapPairedExpected);
        uint256 expectedExecutionValue =
            emergency ? _inventoryValue(twapAssetExpected, twapPairedExpected, true) : expectedFairValue;
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

    /// @notice Atomic direct-Pancake liquidation. `chunkIndex` and `finalChunk`
    /// are explicit and stored for restart-safe idempotency, but v1 rejects
    /// temporal slicing: the only valid operation is chunk 0 over all WBNB.
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
        if (chunkIndex != 0 || !finalChunk) revert SlicingDisabled();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_WBNB, chunkIndex);

        uint256 amountIn = pairedToken.balanceOf(address(this));
        if (amountIn == 0) revert InvalidAmount();
        uint256 notional = priceGuard.fairValue(WBNB, USDT, amountIn);
        _reserveSwapNotional(job, notional, emergency);

        pairedToken.forceApprove(address(executionAdapter), amountIn);
        amountOut = executionAdapter.swapPairedToAsset(amountIn, keeperMinOut, deadline, emergency);
        pairedToken.forceApprove(address(executionAdapter), 0);
        uint256 remaining = pairedToken.balanceOf(address(this));
        if (remaining != 0) revert InventoryRemaining(remaining);
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput = amountIn;
        job.cumulativeOutput = amountOut;
        _completeJob(job);
        emit WbnbLiquidated(jobId, amountIn, amountOut, emergency);
    }

    /// @notice Atomic direct-Pancake liquidation of all canonical CAKE.
    /// It is a separate durable job so reward failures cannot block LP close
    /// or WBNB realization. Temporal slicing remains disabled in MainV2 v1.
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
        if (chunkIndex != 0 || !finalChunk) revert SlicingDisabled();
        Job storage job = _beginChunk(jobId, JobKind.LIQUIDATE_REWARD, chunkIndex);

        uint256 amountIn = rewardToken.balanceOf(address(this));
        if (amountIn == 0) revert InvalidAmount();
        uint256 notional = rewardPriceGuard.fairValue(amountIn);
        _reserveSwapNotional(job, notional, emergency);

        rewardToken.forceApprove(address(rewardExecutionAdapter), amountIn);
        amountOut = rewardExecutionAdapter.swapRewardToAsset(amountIn, keeperMinOut, deadline, emergency);
        rewardToken.forceApprove(address(rewardExecutionAdapter), 0);
        uint256 remaining = rewardToken.balanceOf(address(this));
        if (remaining != 0) revert RewardInventoryRemaining(remaining);
        _recordWithdrawalExecutionLoss(notional, amountOut);

        job.cumulativeInput = amountIn;
        job.cumulativeOutput = amountOut;
        _completeJob(job);
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
            uint160 twapSqrtPrice = priceGuard.twapSqrtPriceX96();
            (uint256 positionAsset, uint256 positionPaired) =
                venue.previewCloseAmountsAtSqrtPrice(activePositionId, twapSqrtPrice);
            total += positionAsset;
            if (positionPaired != 0) {
                total += priceGuard.minimumOut(WBNB, USDT, positionPaired, false);
            }
        }
        uint256 rewards = rewardToken.balanceOf(address(this));
        if (rewards != 0) total += rewardPriceGuard.minimumOut(rewards, false);
    }

    function rewardInventory() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
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

    function _boundedLpMinimum(uint256 expected, uint16 lossBps) internal pure returns (uint256) {
        if (expected == 0) return 0;
        uint256 minimum = FullMath.mulDiv(expected, BPS - lossBps, BPS);
        return minimum == 0 ? 1 : minimum;
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
        if (emergency) return;

        uint64 day = uint64(block.timestamp / 1 days);
        uint256 dayTotal = dailySwapNotional[day] + notional;
        if (dayTotal > dailySwapLimit) revert DailySwapCapExceeded(dayTotal, dailySwapLimit);
        dailySwapNotional[day] = dayTotal;
    }

    function _setMode(Mode newMode) internal {
        Mode oldMode = mode;
        mode = newMode;
        emit ModeChanged(oldMode, newMode);
    }

    function _commitWithdrawalCycleIfQueued() internal {
        if (queuedWithdrawalCount == 0 || withdrawalCycleCommitted) return;
        withdrawalCycleCommitted = true;
        emit WithdrawalCycleCommitted(queuedWithdrawalCount);
    }

    function _recordWithdrawalExecutionLoss(uint256 expected, uint256 actual) internal {
        if (!withdrawalCycleBatchCommitted || actual >= expected) return;
        uint256 incremental = expected - actual;
        withdrawalCycleExecutionLoss += incremental;
        emit WithdrawalExecutionLossRecorded(incremental, withdrawalCycleExecutionLoss);
    }
}
