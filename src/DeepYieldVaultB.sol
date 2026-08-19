// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVaultBAsyncStrategy} from "./interfaces/IVaultBAsyncStrategy.sol";
import {VaultBDepositLib} from "./libraries/VaultBDepositLib.sol";

/// @notice Standalone Vault B ERC-4626 with an explicit asynchronous redeem
/// surface. Standard ERC-4626 withdraw/redeem remain synchronous and never
/// return a fake partial result.
contract DeepYieldVaultB is ERC4626, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice B12-T1: delay for the two-step DEFAULT_ADMIN_ROLE transfer. Handing
    /// over root control is timelocked like every other privileged change (matches
    /// STRATEGY_TIMELOCK), and it can only complete when the incoming admin accepts —
    /// so a fat-fingered address never silently holds root. Hard-wired as a constant so
    /// the constructor ABI is unchanged and the deploy scripts keep working.
    uint48 public constant DEFAULT_ADMIN_TRANSFER_DELAY = 2 days;

    enum RedeemStatus {
        NONE,
        PENDING,
        CLAIMED,
        CANCELED
    }

    struct RedeemRequest {
        address owner;
        address receiver;
        uint128 shares;
        uint64 requestedAt;
        RedeemStatus status;
        bytes32 strategyRequestId;
    }

    IVaultBAsyncStrategy public strategy;
    /// @notice Asset holder pinned when the active strategy is installed. The
    /// vault reads this ERC20 balance directly as a deposit-time NAV floor; a
    /// strategy cannot redirect the source during a later view call.
    address public strategyAssetSource;
    address public treasury;
    uint256 public depositCap;
    uint256 public immutable MIN_DEPOSIT;
    uint256 public immutable MIN_REDEEM_SHARES;
    /// @notice Hard, immutable ceiling on the pending-redeem queue length (B10-T1
    /// finding 9). The live cap `maxPendingRedeems` is admin-tunable up to here so a
    /// sybil that fans minimum requests across many fresh addresses can be answered
    /// without redeploying — but never above this bound.
    uint256 public constant MAX_PENDING_REDEEMS_CEILING = 256;
    uint256 public maxPendingRedeems = 64;
    uint16 public constant MIN_BATCH_COMMIT_BPS = 500;
    uint16 public constant MAX_BATCH_EXECUTION_LOSS_BPS = 200;
    uint256 internal constant BPS = 10_000;

    uint256 public nextRequestId;
    uint256 public outstandingRedeemShares;
    uint256 public outstandingRedeemCount;
    /// @notice Supply snapshot taken when the redeem queue OPENS. It is retained
    /// as a floor against same-block dilution; commitThresholdShares also tracks
    /// later live-supply growth. Zero while the queue is empty.
    uint256 public redeemCycleThresholdBase;
    /// @notice F3 (Audit 2 delta): the pending-redeem ceiling frozen at queue-open, so
    /// the two full-queue COMMIT triggers key off the cap that was in force when the
    /// queue opened — an admin cannot retune `maxPendingRedeems` mid-queue to force an
    /// early commit of a live batch. Zero while the queue is empty. Mirrors
    /// {redeemCycleThresholdBase}.
    uint256 public redeemCycleMaxPendingAtOpen;
    uint256 public redeemCycleSupplySnapshot;
    uint256 public redeemCycleAssetsSnapshot;
    uint256 public redeemCycleCommittedShares;
    uint256 public redeemCyclePayoutAssets;
    uint256 public redeemCyclePayoutClaimed;
    uint256 public redeemCycleProtocolCredit;
    bool internal _redeemCycleCommitted;
    bool public redeemCycleSettlementInitialized;
    /// @notice B11-T3: when the cycle was committed (basis frozen). The strategy-free
    /// force-settle recovery timer starts here.
    uint64 public redeemCycleCommittedAt;
    /// @notice B11-T3: set when the cycle was force-settled from idle after the timeout,
    /// so claims pay from the frozen payout without ever calling the (broken) strategy.
    bool public redeemCycleForceSettled;
    mapping(uint256 => RedeemRequest) public redeemRequests;
    /// @notice The pending slot for an (owner, receiver) pair, stored as id+1 so 0
    /// means "no slot" (B11-T4). Re-keyed from owner-only: a repeat request from the
    /// same pair aggregates into its existing slot instead of taking a second one,
    /// and distinct receivers get distinct slots. Slot hygiene only — the full-queue
    /// commit trigger is what removes the queue-fill DoS.
    mapping(bytes32 => uint256) public pendingRedeemKeyPlusOne;

    /// @notice Assets owed to a receiver whose push payout failed (e.g. a
    /// blacklisted BSC-USD address). The request still settles so the cycle moves;
    /// the receiver pulls later with `withdrawClaimable`. Excluded from
    /// `totalAssets` because it is a liability, not shareholder value.
    mapping(address => uint256) public claimableAssets;
    uint256 public totalClaimableAssets;

    /// @notice Timelocked strategy change. `setStrategy` bootstraps the first
    /// strategy instantly; changing an existing one goes proposeStrategy -> wait
    /// STRATEGY_TIMELOCK -> applyStrategy, so holders can exit before the vault's
    /// unlimited allowance is redirected.
    uint256 public constant STRATEGY_TIMELOCK = 2 days;
    /// @notice B11-T3: how long after commit a stuck cycle (readiness source broken)
    /// may be force-settled from idle by anyone. A normal cycle closes in hours; a week
    /// means it is genuinely broken and avoids forcing a healthy cycle to book a loss.
    uint256 public constant REDEEM_CYCLE_TIMEOUT = 7 days;
    address public pendingStrategy;
    address internal _pendingStrategyAssetSource;
    uint64 public pendingStrategyReadyAt;

    error ZeroAddress();
    error ZeroAmount();
    error DepositCapExceeded();
    error DepositBelowMinimum(uint256 assets, uint256 required);
    error StrategyShortfall(uint256 requested, uint256 received);
    error StrategyNotEmpty();
    error StrategyUnset();
    error StrategyWiringMismatch();
    error InvalidStrategyAssetSource();
    error RedeemQueueActive(uint256 shares);
    error RedeemQueueFull();
    error InvalidMaxPendingRedeems(uint256 provided);
    error RedeemBelowMinimum(uint256 shares, uint256 required);
    error PendingRequestExists(uint256 requestId);
    error RedeemRequestUnknown();
    error RedeemNotReady();
    error NotRedeemOwner();
    error NotTreasury();
    error RedeemCycleLocked();
    /// @notice F6 (Audit 2 delta): the auto-commit trampoline is callable only by the
    /// contract itself.
    error OnlySelf();
    error RedeemCycleNotCommitted();
    error RedeemCycleAlreadySettled();
    error RedeemCycleTimeoutNotElapsed(uint256 nowTs, uint256 readyAt);
    error RedeemCycleStrategyResponsive();
    error RedeemCycleNotReady(uint256 queuedShares, uint256 thresholdShares);
    error RedeemCycleExecutionLossExceeded(uint256 effectiveLoss, uint256 maximumLoss, uint256 requiredTopUp);
    error RedeemCyclePayoutUnderfunded(uint256 payoutBeforeCharge, uint256 executionLossCharge);
    error TooManyShares();
    error NothingClaimable();
    error StrategyAlreadySet();
    error PendingStrategyActive(address strategy);
    error VaultNotEmpty();
    error NoPendingStrategy();
    error StrategyTimelockNotElapsed(uint64 readyAt);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event MaxPendingRedeemsUpdated(uint256 oldMax, uint256 newMax);
    event RedeemRequested(
        uint256 indexed requestId,
        bytes32 indexed strategyRequestId,
        address indexed owner,
        address receiver,
        uint256 shares
    );
    event RedeemCycleOpened(uint256 supply);
    event RedeemCycleCommittedEvent(
        uint256 queuedShares, uint256 thresholdShares, uint256 supplySnapshot, uint256 assetsSnapshot
    );
    event RedeemCycleSettlementInitialized(
        uint256 payoutAssets, uint256 measuredExecutionLoss, uint256 protocolCredit, uint256 chargedExecutionLoss
    );
    event RedeemCycleDeficitFunded(address indexed treasury, uint256 assets, uint256 cumulativeCredit);
    event RedeemCycleCleared();
    event RedeemCycleForceSettled(uint256 payout, uint256 batchShare, uint256 available);
    event RedeemClaimed(uint256 indexed requestId, address indexed receiver, uint256 shares, uint256 assets);
    event RedeemReceiverUpdated(uint256 indexed requestId, address indexed oldReceiver, address indexed newReceiver);
    /// @notice F4 (Audit 2 delta): a force-settled claim paid the receiver from idle but
    /// could not release the canonical strategy/Main handle (all fallback tiers failed).
    /// The handle is orphaned pending {releaseDeferredRedeemHandle}.
    event RedeemHandleReleaseDeferred(uint256 indexed requestId, bytes32 indexed strategyRequestId);
    /// @notice F4 (Audit 2 delta): an orphaned redeem handle was released by the admin
    /// escape hatch after the strategy/Main endpoint recovered.
    event RedeemHandleReleased(bytes32 indexed strategyRequestId);
    /// @notice F6 (Audit 2 delta): a full-queue-triggering request could not auto-commit
    /// because the strategy's one-way commit reverted; the request is still queued and the
    /// cycle stays committable via the permissionless path.
    event RedeemCycleAutoCommitDeferred(uint256 outstandingRedeemCount);
    event RedeemCanceled(uint256 indexed requestId, address indexed owner, uint256 shares);
    event RedeemEscrowed(address indexed receiver, uint256 assets);
    event ClaimableWithdrawn(address indexed owner, address indexed to, uint256 assets);
    event StrategyProposed(address indexed newStrategy, uint64 readyAt);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address guardian_,
        address treasury_,
        uint256 depositCap_
    ) ERC20(name_, symbol_) ERC4626(asset_) AccessControlDefaultAdminRules(DEFAULT_ADMIN_TRANSFER_DELAY, admin_) {
        if (address(asset_) == address(0) || admin_ == address(0) || guardian_ == address(0) || treasury_ == address(0))
        {
            revert ZeroAddress();
        }
        // DEFAULT_ADMIN_ROLE is granted to admin_ by the AccessControlDefaultAdminRules
        // constructor above; it can henceforth move only via the two-step, timelocked,
        // accept-required transfer. ADMIN_ROLE and GUARDIAN_ROLE keep DEFAULT_ADMIN_ROLE
        // as their role-admin, so the default admin still manages them normally.
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, guardian_);
        treasury = treasury_;
        depositCap = depositCap_;
        MIN_DEPOSIT = 10 ** IERC20Metadata(address(asset_)).decimals();
        MIN_REDEEM_SHARES = MIN_DEPOSIT * 1e6;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = address(strategy) == address(0) ? 0 : strategy.estimatedTotalAssets();
        // Escrowed (failed-payout) assets sit in idle but are owed out, so they
        // are not shareholder value. Deliberately still reverts if the strategy
        // reverts: a silent zero here would zero the ERC-4626 share price.
        return idle + deployed - totalClaimableAssets;
    }

    /// @notice Deposit-conservative NAV (B10-T2): mirror of totalAssets() but the
    /// strategy leg is the UPPER (max TWAP/spot geometry) estimate, so a transient
    /// downward spot push cannot under-value NAV and mint an incoming depositor
    /// cheap shares at the existing holders' expense. Used ONLY by the deposit/mint
    /// pricing below. Like totalAssets() it reverts if the strategy reverts, so the
    /// max* wrappers (which try/catch) still fail safe to 0 on an outage (B3-T2).
    function totalAssetsUpper() public view returns (uint256) {
        return VaultBDepositLib.totalAssetsUpper(
            IERC20(asset()), address(this), strategy, strategyAssetSource, totalClaimableAssets
        );
    }

    /// @notice Deposit/mint price on the UPPER NAV (B10-T2). OZ routes deposit()
    /// through previewDeposit and mint() through previewMint, so overriding just
    /// these two makes execution follow the upper valuation automatically — there is
    /// no separate branch in deposit()/mint() (a preview/execution split was exactly
    /// finding 5). The formulas mirror OZ _convertToShares/_convertToAssets, swapping
    /// only totalAssets() for totalAssetsUpper().
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToSharesUpper(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssetsUpper(shares, Math.Rounding.Ceil);
    }

    function _convertToSharesUpper(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), totalAssetsUpper() + 1, rounding);
    }

    function _convertToAssetsUpper(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(shares, totalAssetsUpper() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    // convertToShares/convertToAssets are intentionally NOT overridden (B10-T2): ERC-4626
    // permits convert* to ignore slippage/fees while preview* must not, so convert* stay on
    // the lower totalAssets() (redemption-conservative) and diverge from previewDeposit by
    // design. The divergence is asserted by a test — do not "reconcile" it.

    /// @notice Bootstrap the FIRST strategy instantly (no allowance/funds to rug
    /// yet). Changing an existing strategy must go through proposeStrategy ->
    /// applyStrategy so the timelock protects the redirected allowance.
    function setStrategy(address newStrategy) external onlyRole(ADMIN_ROLE) {
        if (address(strategy) != address(0)) revert StrategyAlreadySet();
        // A pending proposal pins a candidate and its asset source for the
        // timelocked path. Letting an immediate bootstrap bypass it would leave
        // a stale proposal that could later rotate the newly installed
        // allowance. Explicitly cancel it or finish the governed path instead.
        if (pendingStrategy != address(0)) revert PendingStrategyActive(pendingStrategy);
        // B11-T2: an immediate first activation grants an unlimited allowance, so it is
        // only safe on a pristine vault. The ERC-4626 admission boundary quarantines
        // new shares while the strategy is unset, but direct donations or historical
        // funded state can still make the vault non-pristine. Once shares or assets
        // exist, the first strategy must go through the same timelock as a change
        // (proposeStrategy -> applyStrategy), so holders can exit first. totalAssets()
        // reads only idle here (the strategy is unset, so it cannot revert).
        if (totalSupply() != 0 || totalAssets() != 0) revert VaultNotEmpty();
        _activateStrategy(newStrategy, address(0));
    }

    /// @notice Announce a strategy change; holders can exit during the timelock.
    function proposeStrategy(address newStrategy) external onlyRole(ADMIN_ROLE) {
        if (newStrategy == address(0)) revert ZeroAddress();
        IVaultBAsyncStrategy candidate = IVaultBAsyncStrategy(newStrategy);
        address source = VaultBDepositLib.validateCandidate(candidate, asset(), address(this));
        pendingStrategy = newStrategy;
        _pendingStrategyAssetSource = source;
        // block.timestamp plus the fixed two-day delay remains within uint64 for
        // the protocol's lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        pendingStrategyReadyAt = uint64(block.timestamp + STRATEGY_TIMELOCK);
        emit StrategyProposed(newStrategy, pendingStrategyReadyAt);
    }

    function applyStrategy() external onlyRole(ADMIN_ROLE) {
        address next = pendingStrategy;
        if (next == address(0)) revert NoPendingStrategy();
        if (block.timestamp < pendingStrategyReadyAt) revert StrategyTimelockNotElapsed(pendingStrategyReadyAt);
        _activateStrategy(next, _pendingStrategyAssetSource);
        pendingStrategy = address(0);
        _pendingStrategyAssetSource = address(0);
        pendingStrategyReadyAt = 0;
    }

    function cancelStrategyProposal() external onlyRole(ADMIN_ROLE) {
        pendingStrategy = address(0);
        _pendingStrategyAssetSource = address(0);
        pendingStrategyReadyAt = 0;
    }

    function _activateStrategy(address newStrategy, address expectedSource) internal {
        if (newStrategy == address(0)) revert ZeroAddress();
        if (outstandingRedeemShares != 0) revert RedeemQueueActive(outstandingRedeemShares);
        address oldStrategy = address(strategy);
        if (oldStrategy != address(0)) {
            if (strategy.estimatedTotalAssets() != 0 || IERC20(asset()).balanceOf(strategyAssetSource) != 0) {
                revert StrategyNotEmpty();
            }
            IERC20(asset()).forceApprove(oldStrategy, 0);
        }
        IVaultBAsyncStrategy candidate = IVaultBAsyncStrategy(newStrategy);
        address source = VaultBDepositLib.validateCandidate(candidate, asset(), address(this));
        if (expectedSource != address(0) && source != expectedSource) revert StrategyWiringMismatch();
        strategy = candidate;
        strategyAssetSource = source;
        IERC20(asset()).forceApprove(newStrategy, type(uint256).max);
        emit StrategyUpdated(oldStrategy, newStrategy);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setDepositCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        uint256 old = depositCap;
        depositCap = newCap;
        emit DepositCapUpdated(old, newCap);
    }

    /// @notice Tune the pending-redeem queue cap within the immutable ceiling
    /// (B10-T1 finding 9). Raising it lets honest demand or a sybil spike be
    /// absorbed without a redeploy; it can never exceed MAX_PENDING_REDEEMS_CEILING,
    /// and must stay >= 1 so the queue is never bricked to zero.
    function setMaxPendingRedeems(uint256 newMax) external onlyRole(ADMIN_ROLE) {
        if (newMax == 0 || newMax > MAX_PENDING_REDEEMS_CEILING) revert InvalidMaxPendingRedeems(newMax);
        // F3 (Audit 2 delta): while a queue is open, refuse to drop the ceiling below the
        // live queue depth. The commit triggers already read the frozen open-time cap, so
        // this only closes the residual admission-side griefing (locking new entrants out
        // of an in-flight queue) and keeps the live cap coherent with the frozen one.
        if (outstandingRedeemCount > 0 && newMax < outstandingRedeemCount) {
            revert InvalidMaxPendingRedeems(newMax);
        }
        uint256 old = maxPendingRedeems;
        maxPendingRedeems = newMax;
        emit MaxPendingRedeemsUpdated(old, newMax);
    }

    /// @notice F4 (Audit 2 delta): admin escape hatch to release a canonical redeem
    /// handle that a force-settled claim could not release (logged via
    /// {RedeemHandleReleaseDeferred}) because the strategy and Main endpoints were both
    /// unavailable at claim time. Retried through the strict (revert-on-failure) path, so
    /// it only succeeds once an endpoint can actually clear the handle — the receiver was
    /// already paid from idle, so this only reconciles the canonical journal.
    function releaseDeferredRedeemHandle(bytes32 strategyRequestId) external onlyRole(ADMIN_ROLE) {
        VaultBDepositLib.cancelWithdrawal(strategy, strategyAssetSource, strategyRequestId);
        emit RedeemHandleReleased(strategyRequestId);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice ERC-4626 requires max* not to revert. Every strategy call here is
    /// guarded so a reverting strategy fails safe to 0 (no new deposits) rather
    /// than reverting for integrators. totalAssets() is deliberately left able to
    /// revert (see there); this function does not call it.
    /// @notice ERC-4626 requires max* never to revert. B9-T2: the strategy can
    /// return `type(uint256).max` SUCCESSFULLY, so the internal try/catch (which
    /// only catches a revert) is not enough — `balance + deployed` then overflows
    /// outside any guard. Wrap the whole computation and fail safe to 0, exactly as
    /// maxWithdraw/maxRedeem do (P1-T1). maxMint short-circuits on a 0 here, so it
    /// inherits the same safety.
    function maxDeposit(address receiver) public view override returns (uint256) {
        try this.maxDepositStrict(receiver) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    function maxDepositStrict(address) external view returns (uint256) {
        return VaultBDepositLib.maxDepositStrict(
            IERC20(asset()),
            address(this),
            strategy,
            strategyAssetSource,
            // F8 (Audit 2 delta): combined committed view, matching the state-changing
            // deposit/mint guards, so reported capacity is not falsely nonzero during the
            // Main-auto-commit lazy-snapshot window. maxDeposit()'s try/catch maps a
            // strategy-outage revert here to 0, consistent with deposit reverting then too.
            paused() || redeemCycleCommitted() || pendingStrategy != address(0),
            totalSupply(),
            depositCap,
            totalClaimableAssets
        );
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        // maxDeposit already returned 0 on any strategy failure, so the upper
        // conversion (which reads totalAssetsUpper) is only reached when the
        // strategy is healthy. B10-T2: convert the asset cap on the same UPPER rate
        // the deposit is priced at (previewDeposit), so the cap and the price agree.
        if (assets == 0) return 0;
        return assets == type(uint256).max ? type(uint256).max : previewDeposit(assets);
    }

    function availableImmediateLiquidity() public view returns (uint256) {
        uint256 idle = _spendableIdle();
        if (address(strategy) == address(0)) return idle;
        // P1-T1: the strategy is external; a revert here must not brick the four
        // ERC-4626 max* views. On failure, degrade to the immediately-idle balance
        // rather than reverting.
        try strategy.availableWithdrawLimit() returns (uint256 limit) {
            return idle + limit;
        } catch {
            return idle;
        }
    }

    /// @notice ERC-4626 requires max* never to revert. Every strategy-backed input
    /// here can revert during an outage: `redeemCycleCommitted()` (reads the
    /// strategy's cycle flag), the share price via `totalAssets()`, and the
    /// liquidity query. On any such failure this fails safe to 0. Under a PARTIAL
    /// outage (only the liquidity query down) the strict path still runs and
    /// returns the idle-capped amount, per P1-T1. Under a FULL outage owner-max is
    /// unpriceable (totalAssets is deliberately left reverting, B3-T2), so 0 is the
    /// only correct non-reverting answer — never a fabricated value.
    function maxWithdraw(address owner) public view override returns (uint256) {
        try this.maxWithdrawStrict(owner) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        try this.maxRedeemStrict(owner) returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @dev Strict (revert-on-outage) inner implementations. `external` so the
    /// public views above can guard them with try/catch; not intended for direct
    /// integration use.
    function maxWithdrawStrict(address owner) external view returns (uint256) {
        if (redeemCycleCommitted()) return 0;
        uint256 ownerAssets = super.maxWithdraw(owner);
        uint256 liquid = availableImmediateLiquidity();
        return ownerAssets < liquid ? ownerAssets : liquid;
    }

    function maxRedeemStrict(address owner) external view returns (uint256) {
        if (redeemCycleCommitted()) return 0;
        uint256 ownerShares = super.maxRedeem(owner);
        uint256 liquid = availableImmediateLiquidity();
        if (liquid == 0) return 0;
        if (liquid >= totalAssets()) return ownerShares;
        uint256 liquidShares = convertToShares(liquid);
        return ownerShares < liquidShares ? ownerShares : liquidShares;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (assets == 0) revert ZeroAmount();
        if (assets < MIN_DEPOSIT) revert DepositBelowMinimum(assets, MIN_DEPOSIT);
        if (assets > maxDeposit(receiver)) revert DepositCapExceeded();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (shares == 0) revert ZeroAmount();
        assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert DepositBelowMinimum(assets, MIN_DEPOSIT);
        if (shares > maxMint(receiver)) revert DepositCapExceeded();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (assets == 0) revert ZeroAmount();
        if (assets > maxWithdraw(owner)) revert RedeemNotReady();
        _ensureLiquidity(assets);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (redeemCycleCommitted()) revert RedeemQueueActive(outstandingRedeemShares);
        if (shares == 0) revert ZeroAmount();
        if (shares > maxRedeem(owner)) revert RedeemNotReady();
        assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Queue an asynchronous redeem without reading NAV. Shares are
    /// escrowed, not burned, so the requester participates in gains/losses until
    /// claim-time settlement. Claims become order-independent after MainV2 has
    /// realized all strategy inventory into the accounting asset.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (shares > type(uint128).max) revert TooManyShares();
        if (shares < MIN_REDEEM_SHARES) revert RedeemBelowMinimum(shares, MIN_REDEEM_SHARES);
        if (redeemCycleCommitted()) revert RedeemCycleLocked();
        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        // B11-T4: a repeat request from the same (owner, receiver) aggregates into the
        // existing slot — shares sum, the slot count is unchanged, and the strategy
        // handle is NOT re-registered (Main reverts on a duplicate requestId; the hint
        // is always 0, so the extra shares realize at claim like the original). This is
        // queue hygiene; distinct receivers still take distinct slots. It does not by
        // itself stop a sybil fanning requests across addresses — the full-queue commit
        // trigger in commitRedeemCycle is what removes that DoS.
        bytes32 key = _redeemKey(owner, receiver);
        uint256 existingPlusOne = pendingRedeemKeyPlusOne[key];
        if (existingPlusOne != 0) {
            requestId = existingPlusOne - 1;
            RedeemRequest storage existing = redeemRequests[requestId];
            uint256 summed = uint256(existing.shares) + shares;
            if (summed > type(uint128).max) revert TooManyShares();
            _transfer(owner, address(this), shares);
            // Bounded by the summed <= uint128.max check above.
            // forge-lint: disable-next-line(unsafe-typecast)
            existing.shares = uint128(summed);
            outstandingRedeemShares += shares;
            emit RedeemRequested(requestId, existing.strategyRequestId, owner, receiver, shares);
            return requestId;
        }

        if (outstandingRedeemCount >= maxPendingRedeems) revert RedeemQueueFull();

        if (outstandingRedeemCount == 0) {
            // Fix the commit-threshold base at queue-open (B10-T1 finding 8).
            redeemCycleThresholdBase = totalSupply();
            // F3 (Audit 2 delta): freeze the full-queue commit ceiling at open too.
            redeemCycleMaxPendingAtOpen = maxPendingRedeems;
            emit RedeemCycleOpened(redeemCycleThresholdBase);
        }

        _transfer(owner, address(this), shares);
        requestId = nextRequestId++;
        bytes32 strategyId = strategyRequestId(requestId);
        redeemRequests[requestId] = RedeemRequest({
            owner: owner,
            receiver: receiver,
            // Bounded by the explicit type(uint128).max check above.
            // forge-lint: disable-next-line(unsafe-typecast)
            shares: uint128(shares),
            requestedAt: uint64(block.timestamp),
            status: RedeemStatus.PENDING,
            strategyRequestId: strategyId
        });
        outstandingRedeemShares += shares;
        outstandingRedeemCount += 1;
        pendingRedeemKeyPlusOne[key] = requestId + 1;
        activeStrategy.requestWithdrawal(strategyId, 0);
        emit RedeemRequested(requestId, strategyId, owner, receiver, shares);

        // Reaching the configured queue ceiling is an atomic liveness trigger in
        // this same transaction. A sub-economic queue is settled from known idle;
        // an economic queue commits Main. Either way the final request cannot
        // leave a full, unserviceable queue behind.
        if (outstandingRedeemCount == redeemCycleMaxPendingAtOpen) {
            // F6 (Audit 2 delta): best-effort auto-commit. The economic branch makes a
            // one-way-door strategy.commitWithdrawalCycle() call; a revert there must not
            // unwind the marginal request's escrow and slot. Attempt it through a self-call
            // so a failure rolls back only the commit (snapshot included) and leaves the
            // queue full-but-uncommitted, committable later via the permissionless
            // commitRedeemCycle() once the strategy recovers. The sub-economic branch makes
            // no strategy call and so always commits synchronously here.
            try this.autoCommitOnFullQueue(activeStrategy) {}
            catch {
                emit RedeemCycleAutoCommitDeferred(outstandingRedeemCount);
            }
        }
    }

    /// @notice Commit a batch only after it reaches 5% of current supply. There
    /// is deliberately no time-only path: small exits use the contract-enforced
    /// idle reserve and cannot trigger a vault-wide inventory cycle.
    function commitRedeemCycle() external nonReentrant {
        if (outstandingRedeemCount == 0) revert RedeemRequestUnknown();
        if (_redeemCycleCommitted) revert RedeemCycleLocked();
        IVaultBAsyncStrategy activeStrategy = strategy;

        // If Main already auto-committed the cycle (a keeper began an LP close
        // with requests outstanding), the batch is already locked vault-wide, so
        // the 5% threshold no longer gates anything and re-committing the
        // strategy would revert on its one-way door. Take our snapshot now so
        // settlement runs the batch math (2% cap + pro-rata) rather than live
        // per-claim NAV, without touching the strategy again.
        if (activeStrategy.withdrawalCycleCommitted()) {
            _takeRedeemCycleSnapshot(0);
            return;
        }

        uint256 threshold = commitThresholdShares();
        // A full queue is a second, independent liveness trigger. Sub-economic
        // dust is paid only from known idle; otherwise the normal strategy commit
        // path is used. This keeps final-slot atomicity without a cheap unwind.
        bool queueFull = outstandingRedeemCount >= redeemCycleMaxPendingAtOpen;
        if (outstandingRedeemShares < threshold && !queueFull) {
            revert RedeemCycleNotReady(outstandingRedeemShares, threshold);
        }
        _commitRedeemCycle(activeStrategy, threshold);
    }

    /// @notice Canonical adapter callback made by Main before an automatic
    /// close-side commitment. The snapshot and recovery clock are therefore
    /// persisted before Main crosses its one-way boundary; a later close failure
    /// reverts both states atomically.
    function prepareRedeemCycleCommit() external nonReentrant {
        if (msg.sender != address(strategy)) revert StrategyWiringMismatch();
        if (outstandingRedeemCount == 0) revert RedeemRequestUnknown();
        if (_redeemCycleCommitted) return;
        _takeRedeemCycleSnapshot(0);
    }

    function _commitRedeemCycle(IVaultBAsyncStrategy activeStrategy, uint256 threshold) internal {
        _takeRedeemCycleSnapshot(threshold);
        // F2 (Audit 2 delta): route economic-vs-sub-economic on the QUEUE-OPEN frozen
        // base, not the growth-tracked live threshold. `commitThresholdShares()` mixes in
        // live `totalSupply()` (deliberately, for B10-F8's readiness gate), which a same-
        // transaction deposit can inflate — pumping the live threshold above an honest,
        // genuinely-large batch to misroute it into the idle-only settlement and skip the
        // strategy unwind it needs (an underpayment on idle-poor vaults that F1's idle cap
        // cannot recover). The frozen base is fixed at queue-open and cannot be moved by
        // the filling transaction, so routing is manipulation-proof while the public view
        // keeps tracking growth. Anti-DoS (C-1/H-2) is preserved: a genuinely dust batch is
        // still below the frozen base and still settles from idle without an unwind.
        uint256 routingThreshold = Math.mulDiv(redeemCycleThresholdBase, MIN_BATCH_COMMIT_BPS, BPS, Math.Rounding.Ceil);
        if (routingThreshold < MIN_REDEEM_SHARES) routingThreshold = MIN_REDEEM_SHARES;
        if (outstandingRedeemShares < routingThreshold) {
            // Full-queue trigger: the strategy is healthy, so pay the batch's full fair
            // NAV share capped by idle (F1) — never the pari-passu slice, which would
            // apply a loss haircut that does not exist for a responsive strategy.
            _settleFromKnownIdle(true);
            return;
        }
        activeStrategy.commitWithdrawalCycle();
    }

    /// @notice F6 (Audit 2 delta): self-call trampoline enabling the full-queue trigger to
    /// attempt the auto-commit under try/catch. Callable only by the contract itself, from
    /// within the already-`nonReentrant` `requestRedeem`, so it needs no separate guard.
    function autoCommitOnFullQueue(IVaultBAsyncStrategy activeStrategy) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _commitRedeemCycle(activeStrategy, commitThresholdShares());
    }

    /// @param strategyHealthy true when the strategy is responsive (the full-queue
    /// commit trigger), false when it is unavailable (`forceSettleStuckCycle` recovery).
    /// The two cases price the batch differently and MUST NOT share one formula
    /// (Audit 2 delta F1):
    ///  - Healthy strategy: there is no unrealizable loss to share, so the batch is
    ///    paid its full fair NAV share, capped only by physically-available idle —
    ///    `min(batchShare, available)`. Scaling by the batch's supply fraction here
    ///    underpays a normal, deployed vault by ~99%.
    ///  - Unavailable strategy: the deployed value is unrealizable, so the batch shares
    ///    that loss pari-passu with remaining holders and receives only its
    ///    supply-proportional slice of realizable idle — `available · committedShares /
    ///    supply` — matching the conservative B11-T3 recovery intent.
    function _settleFromKnownIdle(bool strategyHealthy) internal {
        uint256 batchShare =
            Math.mulDiv(redeemCycleAssetsSnapshot, redeemCycleCommittedShares, redeemCycleSupplySnapshot);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 available = idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;
        uint256 cap = strategyHealthy
            ? available
            : Math.mulDiv(available, redeemCycleCommittedShares, redeemCycleSupplySnapshot);
        uint256 payout = batchShare < cap ? batchShare : cap;
        redeemCyclePayoutAssets = payout;
        redeemCycleSettlementInitialized = true;
        redeemCycleForceSettled = true;
        emit RedeemCycleForceSettled(payout, batchShare, available);
    }

    /// @notice B11-T3: recover a committed cycle whose readiness source is broken.
    /// After REDEEM_CYCLE_TIMEOUT, ANYONE may settle a batch only when the
    /// strategy's commitment view is unavailable. A responsive strategy — even
    /// if merely slow — remains on the normal path. The force payout uses only
    /// known spendable idle, pro-rata to the batch's frozen share of supply, and
    /// never spends a stale claim on capital whose current value cannot be read.
    function forceSettleStuckCycle() external nonReentrant {
        if (!_redeemCycleCommitted) revert RedeemCycleNotCommitted();
        if (redeemCycleSettlementInitialized) revert RedeemCycleAlreadySettled();
        uint256 readyAt = uint256(redeemCycleCommittedAt) + REDEEM_CYCLE_TIMEOUT;
        if (block.timestamp < readyAt) revert RedeemCycleTimeoutNotElapsed(block.timestamp, readyAt);

        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        // The force path is a recovery for an unavailable readiness source, not
        // a caller-selected alternate price for a healthy-but-slow strategy.
        bool strategyUnavailable;
        try activeStrategy.withdrawalCycleCommitted() returns (bool) {}
        catch {
            strategyUnavailable = true;
        }
        if (!strategyUnavailable) revert RedeemCycleStrategyResponsive();

        // Unavailable strategy: pari-passu recovery — the batch shares the
        // unrealizable deployed loss with remaining holders (F1).
        _settleFromKnownIdle(false);
    }

    /// @notice Freeze the batch basis (supply, NAV, committed shares) used by
    /// settlement. Supply and committed shares are invariant across the whole
    /// settlement window — every deposit/mint/request/cancel gate reads the
    /// combined committed view and is frozen while committed — so the moment the
    /// snapshot is taken (timely local commit, or lazily after Main's
    /// auto-commit) cannot change the batch price a redeemer receives. Only the
    /// NAV snapshot bounds the 2% execution-loss cap; a later (post-close)
    /// snapshot yields a strictly conservative cap and never a worse price.
    function _takeRedeemCycleSnapshot(uint256 threshold) internal {
        redeemCycleSupplySnapshot = totalSupply();
        redeemCycleAssetsSnapshot = totalAssets();
        redeemCycleCommittedShares = outstandingRedeemShares;
        _redeemCycleCommitted = true;
        // B11-T3: freeze the recovery clock at commit, while the strategy is healthy.
        redeemCycleCommittedAt = uint64(block.timestamp);
        emit RedeemCycleCommittedEvent(
            redeemCycleCommittedShares, threshold, redeemCycleSupplySnapshot, redeemCycleAssetsSnapshot
        );
    }

    /// @notice Effective commitment includes a Main-side automatic commit made
    /// atomically when a keeper begins an LP close with requests outstanding.
    function redeemCycleCommitted() public view returns (bool) {
        IVaultBAsyncStrategy activeStrategy = strategy;
        return
            _redeemCycleCommitted
                || (address(activeStrategy) != address(0) && activeStrategy.withdrawalCycleCommitted());
    }

    /// @notice F5 (Audit 2 delta): committed view for owner-exit gates (cancel /
    /// updateReceiver). Same "combined" semantics as {redeemCycleCommitted}, but a
    /// strategy that reverts (outage) is treated as NOT committed instead of bubbling
    /// the revert up — so an owner can still exit an UNCOMMITTED request during an
    /// adapter/Main outage, while a Main-side auto-commit on a RESPONSIVE strategy still
    /// locks the batch. Fail-open only for cancel-ability, never for payout.
    function _redeemCycleCommittedForExit() internal view returns (bool) {
        if (_redeemCycleCommitted) return true;
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) return false;
        try activeStrategy.withdrawalCycleCommitted() returns (bool committed) {
            return committed;
        } catch {
            return false;
        }
    }

    /// @notice Slot key for the pending-redeem guard (B11-T4). Aggregation is per
    /// (owner, receiver): the receiver is preserved and the pair owns the slot.
    function _redeemKey(address owner, address receiver) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, receiver));
    }

    function commitThresholdShares() public view returns (uint256 threshold) {
        if (outstandingRedeemCount == 0) return 0;
        // Keep the queue-open snapshot as a floor against same-block dilution,
        // while tracking later supply growth so old dust cannot lower the bar.
        uint256 base = redeemCycleThresholdBase;
        uint256 live = totalSupply();
        if (live > base) base = live;
        threshold = Math.mulDiv(base, MIN_BATCH_COMMIT_BPS, BPS, Math.Rounding.Ceil);
        if (threshold < MIN_REDEEM_SHARES) threshold = MIN_REDEEM_SHARES;
    }

    /// @notice Permissionless settlement to the receiver fixed at request.
    /// Claims are order-independent after Main is fully USDT: every request
    /// burns escrowed shares at the same live PPS, so a bad receiver cannot
    /// block unrelated users.
    function claimRedeem(uint256 requestId) external nonReentrant returns (uint256 assets) {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING) revert RedeemRequestUnknown();
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        // B11-T3: a force-settled cycle pays from the frozen payout + idle, so it
        // bypasses the broken readiness gate. It releases the canonical zero-
        // asset request below before clearing its local request state.
        if (!redeemCycleForceSettled && !activeStrategy.withdrawalReady(request.strategyRequestId)) {
            revert RedeemNotReady();
        }

        uint256 shares = request.shares;
        // Route on the combined committed view, not the raw local flag: if Main
        // auto-committed the cycle first, the local flag is unreachable, and the
        // old raw-flag check silently settled at live NAV (no cap, no pro-rata).
        // Materialize the snapshot lazily on the first claim of such a cycle.
        if (redeemCycleCommitted()) {
            if (!_redeemCycleCommitted) _takeRedeemCycleSnapshot(0);
            if (!redeemCycleSettlementInitialized) _initializeRedeemCycleSettlement(activeStrategy);
            assets = shares == outstandingRedeemShares
                ? redeemCyclePayoutAssets - redeemCyclePayoutClaimed
                : Math.mulDiv(redeemCyclePayoutAssets, shares, redeemCycleCommittedShares);
            redeemCyclePayoutClaimed += assets;
        } else {
            assets = previewRedeem(shares);
        }
        uint256 idle = _spendableIdle();
        uint256 missing = assets > idle ? assets - idle : 0;

        request.status = RedeemStatus.CLAIMED;
        outstandingRedeemShares -= shares;
        outstandingRedeemCount -= 1;
        pendingRedeemKeyPlusOne[_redeemKey(request.owner, request.receiver)] = 0;

        // `<`, matching _ensureLiquidity: a strategy that returns 1 wei more than
        // requested (lot rounding) must not permanently jam this one claim and,
        // through it, the whole vault. Any surplus stays idle as shareholder value.
        // A force payout is fully covered by known idle, so no user assets are
        // pulled. Release Main's canonical zero-asset handle directly through
        // its immutable root-Vault endpoint; this does not rely on the adapter
        // being callable and keeps the two commitment journals aligned.
        if (!redeemCycleForceSettled) {
            uint256 withdrawn = activeStrategy.claimWithdrawal(request.strategyRequestId, missing);
            if (withdrawn < missing) revert StrategyShortfall(missing, withdrawn);
        } else {
            // A sub-economic full queue never commits Main, so release its
            // zero-asset handle through the normal cancel path.  The timeout
            // recovery path falls back to Main's force-clear endpoint when the
            // strategy cancel is unavailable.
            // F4 (Audit 2 delta): release TOLERANTLY. The payout is fully idle-backed, so
            // a handle that no tier can release must not brick this claim (and, through
            // the count-zero gate, freeze the whole vault). An un-releasable handle is
            // logged for the admin escape hatch to retry once the endpoint recovers; a
            // handle later honored by Main returns assets to idle as shareholder value,
            // never a double payout to this already-paid receiver.
            bool released =
                VaultBDepositLib.cancelWithdrawalTolerant(strategy, strategyAssetSource, request.strategyRequestId);
            if (!released) emit RedeemHandleReleaseDeferred(requestId, request.strategyRequestId);
        }
        uint256 spendableIdle = _spendableIdle();
        if (spendableIdle < assets) {
            revert StrategyShortfall(assets, spendableIdle);
        }

        _burn(address(this), shares);
        // Never let a blacklisted receiver push-revert jam the cycle: on transfer
        // failure the amount is escrowed as claimable and the request still settles.
        if (assets != 0) _payOrEscrow(request.receiver, assets);
        if (outstandingRedeemCount == 0) _clearRedeemCycle();
        emit Withdraw(msg.sender, request.receiver, request.owner, assets, shares);
        emit RedeemClaimed(requestId, request.receiver, shares, assets);
    }

    /// @dev Push the payout; if the transfer reverts OR returns false (a
    /// blacklisted BSC-USD receiver does the former), escrow it as claimable so
    /// the claim still settles and the cycle keeps moving.
    function _payOrEscrow(address to, uint256 amount) internal {
        (bool success, bytes memory data) = asset().call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (success && (data.length == 0 || abi.decode(data, (bool)))) return;
        claimableAssets[to] += amount;
        totalClaimableAssets += amount;
        emit RedeemEscrowed(to, amount);
    }

    /// @notice Withdraw assets escrowed for msg.sender (a failed push payout) to
    /// any address — so a blacklisted original receiver can recover to a clean one.
    function withdrawClaimable(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = claimableAssets[msg.sender];
        if (amount == 0) revert NothingClaimable();
        claimableAssets[msg.sender] = 0;
        totalClaimableAssets -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit ClaimableWithdrawn(msg.sender, to, amount);
    }

    function updateRedeemReceiver(uint256 requestId, address newReceiver) external nonReentrant {
        if (newReceiver == address(0)) revert ZeroAddress();
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING || msg.sender != request.owner) {
            revert RedeemRequestUnknown();
        }
        // Mutable while freely cancellable; fixed before the committed payout is
        // observable so the owner cannot redirect a batch claim mid-settlement.
        // F5 (Audit 2 delta): gate on the combined committed view — a Main-side
        // auto-commit (strategy.withdrawalCycleCommitted) locks the batch before the
        // local snapshot is lazily taken, so the raw flag alone would let an owner
        // move a receiver out of an already-committed batch. Tolerant variant: a
        // strategy outage does not block the owner from an uncommitted receiver edit.
        if (_redeemCycleCommittedForExit() || redeemCycleSettlementInitialized) revert RedeemCycleLocked();
        address oldReceiver = request.receiver;
        if (newReceiver == oldReceiver) return;
        // B11-T4: the pending-slot guard is keyed by (owner, receiver), so moving the
        // receiver moves the key. Refuse if the owner already holds a slot for the new
        // receiver — merging two live slots here would strand one strategy handle.
        bytes32 newKey = _redeemKey(request.owner, newReceiver);
        uint256 collision = pendingRedeemKeyPlusOne[newKey];
        if (collision != 0) revert PendingRequestExists(collision - 1);
        pendingRedeemKeyPlusOne[_redeemKey(request.owner, oldReceiver)] = 0;
        pendingRedeemKeyPlusOne[newKey] = requestId + 1;
        request.receiver = newReceiver;
        emit RedeemReceiverUpdated(requestId, oldReceiver, newReceiver);
    }

    /// @notice The owner may cancel only before the batch is committed. A
    /// committed request must settle so the requester cannot retain all shares
    /// after imposing an irreversible vault-wide unwind.
    function cancelRedeem(uint256 requestId) external nonReentrant {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING) revert RedeemRequestUnknown();
        if (msg.sender != request.owner) revert NotRedeemOwner();
        // F5 (Audit 2 delta): combined committed view (tolerant of a strategy outage,
        // so an uncommitted owner can still cancel to recover funds during an outage),
        // so a Main-side auto-commit cannot be escaped loss-exposure-free before the
        // local snapshot materializes.
        if (_redeemCycleCommittedForExit()) revert RedeemCycleLocked();

        uint256 shares = request.shares;
        request.status = RedeemStatus.CANCELED;
        outstandingRedeemShares -= shares;
        outstandingRedeemCount -= 1;
        // B11-T4: clearing the (owner, receiver) slot releases the whole accumulated
        // position — `request.shares` already holds every aggregated top-up.
        pendingRedeemKeyPlusOne[_redeemKey(request.owner, request.receiver)] = 0;
        VaultBDepositLib.cancelWithdrawal(strategy, strategyAssetSource, request.strategyRequestId);
        _transfer(address(this), request.owner, shares);
        if (outstandingRedeemCount == 0) _clearRedeemCycle();
        emit RedeemCanceled(requestId, request.owner, shares);
    }

    function pendingRedeemRequest(uint256 requestId) external view returns (uint256 shares) {
        RedeemRequest storage request = redeemRequests[requestId];
        return request.status == RedeemStatus.PENDING ? request.shares : 0;
    }

    function claimableRedeemRequest(uint256 requestId) external view returns (uint256 assets) {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemStatus.PENDING) return 0;
        // A force-settled payout is fully local and must remain readable even when
        // every strategy view is unavailable.
        if (redeemCycleForceSettled) {
            uint256 payout = redeemCyclePayoutAssets;
            if (request.shares == outstandingRedeemShares) return payout - redeemCyclePayoutClaimed;
            return Math.mulDiv(payout, request.shares, redeemCycleCommittedShares);
        }
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0) || !activeStrategy.withdrawalReady(request.strategyRequestId)) {
            return 0;
        }
        if (redeemCycleCommitted()) {
            // When Main auto-committed but no claim/commit has snapshotted yet,
            // preview against the frozen live basis (supply, outstanding shares,
            // current NAV) — the same values the first claim will snapshot — so
            // the preview equals the amount that claim will actually pay.
            uint256 supply = _redeemCycleCommitted ? redeemCycleSupplySnapshot : totalSupply();
            uint256 batchShares = _redeemCycleCommitted ? redeemCycleCommittedShares : outstandingRedeemShares;
            uint256 assetsSnapshot = _redeemCycleCommitted ? redeemCycleAssetsSnapshot : totalAssets();
            uint256 payout = redeemCyclePayoutAssets;
            if (!redeemCycleSettlementInitialized) {
                (bool valid, uint256 previewPayout) =
                    _previewRedeemCycleSettlement(activeStrategy, supply, batchShares, assetsSnapshot);
                if (!valid) return 0;
                payout = previewPayout;
            }
            if (request.shares == outstandingRedeemShares && redeemCycleSettlementInitialized) {
                return payout - redeemCyclePayoutClaimed;
            }
            return Math.mulDiv(payout, request.shares, batchShares);
        }
        return previewRedeem(request.shares);
    }

    /// @notice Protocol treasury funding for an over-budget committed cycle.
    /// The credit both enters NAV and offsets measured execution loss; it does
    /// not authorize a wider loss budget.
    function fundRedeemCycleDeficit(uint256 assets) external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        if (!redeemCycleCommitted() || redeemCycleSettlementInitialized) revert RedeemCycleLocked();
        if (assets == 0) revert ZeroAmount();
        // Treasury may fund before the first claim even when Main auto-committed;
        // materialize the snapshot first so the credit sits on a coherent batch
        // and the cap base excludes the funding just added.
        if (!_redeemCycleCommitted) _takeRedeemCycleSnapshot(0);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        redeemCycleProtocolCredit += assets;
        emit RedeemCycleDeficitFunded(msg.sender, assets, redeemCycleProtocolCredit);
    }

    function strategyRequestId(uint256 requestId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), requestId));
    }

    function _ensureLiquidity(uint256 assetsNeeded) internal {
        uint256 idle = _spendableIdle();
        if (idle >= assetsNeeded) return;
        IVaultBAsyncStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyUnset();
        uint256 missing = assetsNeeded - idle;
        uint256 withdrawn = activeStrategy.withdrawToVault(missing);
        if (withdrawn < missing) revert StrategyShortfall(missing, withdrawn);
    }

    function _spendableIdle() internal view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = totalClaimableAssets;
        return idle > reserved ? idle - reserved : 0;
    }

    function _initializeRedeemCycleSettlement(IVaultBAsyncStrategy activeStrategy) internal {
        if (!activeStrategy.withdrawalCycleBatchCommitted()) revert StrategyWiringMismatch();
        uint256 measured = activeStrategy.withdrawalCycleExecutionLoss();
        uint256 chargeable = activeStrategy.withdrawalCycleChargeableExecutionLoss();
        if (chargeable > measured) revert StrategyWiringMismatch();
        uint256 effective = measured > redeemCycleProtocolCredit ? measured - redeemCycleProtocolCredit : 0;
        uint256 charged = chargeable > redeemCycleProtocolCredit ? chargeable - redeemCycleProtocolCredit : 0;
        // Finding 5 (B10-T1): when the ENTIRE snapshot supply is in this batch there
        // are no remaining holders for the loss cap to protect, so the cap is moot —
        // exactly as _previewRedeemCycleSettlement short-circuits. Applying it here
        // BEFORE the cap check keeps the two paths consistent; without it a 100%-supply
        // exit with >2% execution loss reverts every claim forever and freezes the
        // whole vault (and claimableRedeemRequest, which reads the preview, would show
        // a ready amount for a claim that reverts).
        // M-01 (Audit 2 integration): use a near-100% BAND, not exact equality. A holder
        // of sub-redeemable dust (< MIN_REDEEM_SHARES — too small to ever join the queue)
        // left outside the batch would otherwise, by simply not exiting, keep committed <
        // supply and force the loss cap on a de-facto full exit, freezing every claim on a
        // >2% loss. The residual dust is diluted to a negligible amount, exactly as the
        // exact-100% path treats a zero remainder. Underflow-safe: committed <= supply.
        if (redeemCycleSupplySnapshot - redeemCycleCommittedShares <= MIN_REDEEM_SHARES) {
            redeemCyclePayoutAssets = totalAssets();
            redeemCycleSettlementInitialized = true;
            emit RedeemCycleSettlementInitialized(redeemCyclePayoutAssets, measured, redeemCycleProtocolCredit, charged);
            return;
        }
        uint256 maximum = Math.mulDiv(redeemCycleAssetsSnapshot, MAX_BATCH_EXECUTION_LOSS_BPS, BPS);
        if (effective > maximum) {
            revert RedeemCycleExecutionLossExceeded(effective, maximum, effective - maximum);
        }

        (bool valid, uint256 payout) = _previewRedeemCycleSettlement(
            activeStrategy, redeemCycleSupplySnapshot, redeemCycleCommittedShares, redeemCycleAssetsSnapshot
        );
        if (!valid) {
            uint256 currentAssets = totalAssets();
            uint256 basePayout = Math.mulDiv(currentAssets, redeemCycleCommittedShares, redeemCycleSupplySnapshot);
            uint256 charge = Math.mulDiv(
                charged,
                redeemCycleSupplySnapshot - redeemCycleCommittedShares,
                redeemCycleSupplySnapshot,
                Math.Rounding.Ceil
            );
            revert RedeemCyclePayoutUnderfunded(basePayout, charge);
        }

        redeemCyclePayoutAssets = payout;
        redeemCycleSettlementInitialized = true;
        emit RedeemCycleSettlementInitialized(payout, measured, redeemCycleProtocolCredit, charged);
    }

    function _previewRedeemCycleSettlement(
        IVaultBAsyncStrategy activeStrategy,
        uint256 supply,
        uint256 batchShares,
        uint256 assetsSnapshot
    ) internal view returns (bool valid, uint256 payout) {
        if (supply == 0 || batchShares == 0 || batchShares > supply) return (false, 0);

        uint256 currentAssets = totalAssets();
        // M-01 (Audit 2 integration): near-100% band, not exact equality — see the
        // matching guard in _initializeRedeemCycleSettlement. A sub-redeemable dust
        // remainder cannot be used to withhold the 100% bypass and force the loss cap.
        if (supply - batchShares <= MIN_REDEEM_SHARES) return (true, currentAssets);

        uint256 measured = activeStrategy.withdrawalCycleExecutionLoss();
        uint256 chargeable = activeStrategy.withdrawalCycleChargeableExecutionLoss();
        if (chargeable > measured) return (false, 0);
        uint256 effective = measured > redeemCycleProtocolCredit ? measured - redeemCycleProtocolCredit : 0;
        uint256 charged = chargeable > redeemCycleProtocolCredit ? chargeable - redeemCycleProtocolCredit : 0;
        uint256 maximum = Math.mulDiv(assetsSnapshot, MAX_BATCH_EXECUTION_LOSS_BPS, BPS);
        if (effective > maximum) return (false, 0);

        uint256 basePayout = Math.mulDiv(currentAssets, batchShares, supply);
        uint256 charge = Math.mulDiv(charged, supply - batchShares, supply, Math.Rounding.Ceil);
        // A full queue is deliberately an independent liveness trigger. A small
        // committed batch can bear at most its pro-rata current-asset claim, so
        // saturate an excessive additional loss charge at zero payout instead
        // of making every request unclaimable forever.
        if (charge >= basePayout) return (true, 0);
        return (true, basePayout - charge);
    }

    function _clearRedeemCycle() internal {
        _redeemCycleCommitted = false;
        // Release the threshold base so the next queue re-snapshots (B10-T1 #8);
        // it must not stick after the cycle closes.
        redeemCycleThresholdBase = 0;
        redeemCycleMaxPendingAtOpen = 0;
        redeemCycleSupplySnapshot = 0;
        redeemCycleAssetsSnapshot = 0;
        redeemCycleCommittedShares = 0;
        redeemCyclePayoutAssets = 0;
        redeemCyclePayoutClaimed = 0;
        redeemCycleProtocolCredit = 0;
        redeemCycleSettlementInitialized = false;
        redeemCycleCommittedAt = 0; // B11-T3: a new cycle restarts the recovery clock
        redeemCycleForceSettled = false;
        emit RedeemCycleCleared();
    }
}
