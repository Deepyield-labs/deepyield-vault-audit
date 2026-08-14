// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DedicatedVaultMainV2} from "./DedicatedVaultMainV2.sol";
import {IVaultBAsyncStrategy} from "./interfaces/IVaultBAsyncStrategy.sol";
import {IFeeSink} from "./interfaces/IFeeSink.sol";

interface IVaultBReserveView {
    function totalAssets() external view returns (uint256);
    function totalClaimableAssets() external view returns (uint256);
}

interface IVaultBRedeemCycleCommit {
    function prepareRedeemCycleCommit() external;
}

/// @notice Vault B ERC-4626 bridge for MainV2. Egress is restricted to the
/// immutable ERC-4626 vault and fee recipient. Async claims settle at the
/// vault's claim-time NAV; request-time assets are only an observability hint.
contract DedicatedVaultStrategyAdapterV2 is IVaultBAsyncStrategy, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3000;
    uint16 public constant MIN_VAULT_IDLE_BPS = 200;
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable override asset;
    address public immutable override vault;
    DedicatedVaultMainV2 public immutable main;
    uint16 public immutable performanceFeeBps;
    address public immutable feeRecipient;
    IFeeSink public immutable feeSink;

    uint256 public accountedAssets;
    uint256 public panicNonce;
    /// @notice Fee assets pulled from Main but not yet accepted by the fee sink
    /// (the sink reverted). Held in this adapter as an obligation owed to
    /// `feeRecipient` and remitted later via `remitFee()`. Excluded from vault
    /// NAV: it lives in this adapter's own balance, which `estimatedTotalAssets`
    /// (Main assets only) does not count.
    uint256 public unremittedFee;

    error NotVault();
    error NotMain();
    error ZeroAddress();
    error FeeTooHigh();
    error TransferMismatch(uint256 expected, uint256 actual);
    error InvalidFeeSink();
    error FeeSinkPullMismatch(uint256 expected, uint256 actual);
    error VaultIdleReserveViolation(uint256 requested, uint256 deployable, uint256 requiredIdle);

    event Deployed(uint256 assets);
    event WithdrawnToVault(uint256 assets);
    event WithdrawalForwarded(bytes32 indexed requestId, uint256 assets, uint256 feeAssets);
    event PerformanceFeeCharged(uint256 realizedProfit, uint256 feeAssets);
    event FeeRemittanceDeferred(uint256 amount, uint256 totalUnremitted);
    event FeeRemitted(uint256 amount);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(
        IERC20 asset_,
        address vault_,
        DedicatedVaultMainV2 main_,
        address admin_,
        address manager_,
        address guardian_,
        address feeRecipient_,
        uint16 performanceFeeBps_
    ) {
        if (
            address(asset_) == address(0) || vault_ == address(0) || address(main_) == address(0)
                || admin_ == address(0) || manager_ == address(0) || guardian_ == address(0)
                || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        if (performanceFeeBps_ > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_.code.length == 0) revert InvalidFeeSink();
        asset = asset_;
        vault = vault_;
        main = main_;
        performanceFeeBps = performanceFeeBps_;
        feeRecipient = feeRecipient_;
        feeSink = IFeeSink(feeRecipient_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MANAGER_ROLE, manager_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    function deploy(uint256 assets) external onlyRole(MANAGER_ROLE) nonReentrant {
        uint256 deployable = maxDeployableAssets();
        if (assets > deployable) revert VaultIdleReserveViolation(assets, deployable, minimumVaultIdleAssets());
        asset.safeTransferFrom(vault, address(this), assets);
        asset.forceApprove(address(main), assets);
        main.fundFromVault(assets);
        asset.forceApprove(address(main), 0);
        accountedAssets += assets;
        emit Deployed(assets);
    }

    /// @notice Synchronous ERC-4626 path. Main enforces fully-USDT inventory
    /// and rejects this path while an older queued request exists.
    function withdrawToVault(uint256 assetsNeeded) external onlyVault nonReentrant returns (uint256 withdrawn) {
        _crystallizeFeeDirect();
        withdrawn = _pullIdle(assetsNeeded);
        asset.safeTransfer(vault, withdrawn);
        // Resync basis to Main's actual remaining idle (covers the loss path,
        // where the old flat subtraction left a stale, too-high basis).
        accountedAssets = asset.balanceOf(address(main));
        emit WithdrawnToVault(withdrawn);
    }

    function requestWithdrawal(bytes32 requestId, uint256 assetsHint) external onlyVault nonReentrant {
        main.requestWithdrawal(requestId, assetsHint);
    }

    function commitWithdrawalCycle() external onlyVault nonReentrant {
        main.commitWithdrawalCycle();
    }

    /// @notice Canonical Main callback used immediately before an automatic
    /// withdrawal-cycle commit. It makes the Vault snapshot authoritative before
    /// Main starts an irreversible close step.
    function prepareWithdrawalCycleCommit() external {
        if (msg.sender != address(main)) revert NotMain();
        IVaultBRedeemCycleCommit(vault).prepareRedeemCycleCommit();
    }

    /// @notice Pull exactly the claim-time shortfall plus any accrued realized
    /// fee in one Main request. The user amount goes only to the vault; the fee
    /// goes only to the immutable fee recipient.
    function claimWithdrawal(bytes32 requestId, uint256 assetsNeeded)
        external
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        (uint256 profit, uint256 feeAssets) = pendingPerformanceFee();
        uint256 pullAmount = assetsNeeded + feeAssets;
        uint256 beforeBalance = asset.balanceOf(address(this));
        main.claimWithdrawal(requestId, pullAmount);
        uint256 received = asset.balanceOf(address(this)) - beforeBalance;
        if (received != pullAmount) revert TransferMismatch(pullAmount, received);

        if (profit != 0) {
            // Fee is decoupled from the withdrawal: _payFee never reverts the
            // user's exit; on a sink failure it accrues to unremittedFee.
            _payFee(feeAssets);
            emit PerformanceFeeCharged(profit, feeAssets);
        }
        if (assetsNeeded != 0) asset.safeTransfer(vault, assetsNeeded);
        // Resync basis to Main's actual remaining idle after this withdrawal and
        // any realized fee that left Main — for BOTH profit and loss paths. The
        // realized fee left Main whether or not the sink accepted it, so the
        // deferred obligation is never counted into the basis twice.
        accountedAssets = asset.balanceOf(address(main));
        emit WithdrawalForwarded(requestId, assetsNeeded, feeAssets);
        return assetsNeeded;
    }

    function withdrawalReady(bytes32 requestId) external view returns (bool) {
        (, DedicatedVaultMainV2.WithdrawalStatus status) = main.withdrawals(requestId);
        return status == DedicatedVaultMainV2.WithdrawalStatus.REQUESTED && main.isWithdrawalReady();
    }

    function withdrawalCycleCommitted() external view returns (bool) {
        return main.withdrawalCycleCommitted();
    }

    function withdrawalCycleBatchCommitted() external view returns (bool) {
        return main.withdrawalCycleBatchCommitted();
    }

    function withdrawalCycleExecutionLoss() external view returns (uint256) {
        return main.withdrawalCycleExecutionLoss();
    }

    function withdrawalCycleChargeableExecutionLoss() external view returns (uint256) {
        uint256 grossLoss = main.withdrawalCycleExecutionLoss();
        if (grossLoss == 0 || !main.isWithdrawalReady()) return grossLoss;

        uint256 currentGrossAssets = asset.balanceOf(address(main));
        (, uint256 feeAfterExecution) = _performanceFeeAtGrossAssets(currentGrossAssets);
        (, uint256 feeWithoutExecutionLoss) = _performanceFeeAtGrossAssets(currentGrossAssets + grossLoss);
        uint256 feeRelief = feeWithoutExecutionLoss - feeAfterExecution;
        return feeRelief < grossLoss ? grossLoss - feeRelief : 0;
    }

    function cancelWithdrawal(bytes32 requestId) external onlyVault nonReentrant {
        main.cancelWithdrawal(requestId);
    }

    function availableWithdrawLimit() public view returns (uint256) {
        if (!main.isWithdrawalReady() || main.queuedWithdrawalCount() != 0) return 0;
        uint256 idle = asset.balanceOf(address(main));
        (, uint256 feeAssets) = pendingPerformanceFee();
        return idle - feeAssets;
    }

    function depositsAllowed() external view returns (bool) {
        if (
            main.mode() != DedicatedVaultMainV2.Mode.OPERATING || main.withdrawalCycleCommitted()
                || !main.isWithdrawalReady()
        ) return false;
        (, uint256 feeAssets) = pendingPerformanceFee();
        return feeAssets == 0;
    }

    function depositAssetSource() external view returns (address) {
        return address(main);
    }

    function minimumVaultIdleAssets() public view returns (uint256) {
        return Math.mulDiv(IVaultBReserveView(vault).totalAssets(), MIN_VAULT_IDLE_BPS, BPS, Math.Rounding.Ceil);
    }

    function maxDeployableAssets() public view returns (uint256) {
        uint256 idle = asset.balanceOf(vault);
        uint256 claimable = IVaultBReserveView(vault).totalClaimableAssets();
        if (idle <= claimable) return 0;
        uint256 shareholderIdle = idle - claimable;
        uint256 reserve = minimumVaultIdleAssets();
        return shareholderIdle > reserve ? shareholderIdle - reserve : 0;
    }

    function managerWithdrawAll() external onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 withdrawn) {
        if (!main.isWithdrawalReady() || main.queuedWithdrawalCount() != 0) return 0;
        _crystallizeFeeDirect();
        uint256 idle = asset.balanceOf(address(main));
        if (idle != 0) {
            withdrawn = _pullIdle(idle);
            asset.safeTransfer(vault, withdrawn);
        }
        accountedAssets = 0;
    }

    function harvest() external onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 profit, uint256 feeAssets) {
        return _crystallizeFeeDirect();
    }

    function pendingPerformanceFee() public view returns (uint256 profit, uint256 feeAssets) {
        if (!main.isWithdrawalReady()) return (0, 0);
        return _performanceFeeAtGrossAssets(asset.balanceOf(address(main)));
    }

    function panic() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        main.halt();
        uint256 positionId = main.activePositionId();
        if (positionId != 0) {
            bytes32 jobId = keccak256(abi.encode("ADAPTER_PANIC", address(this), ++panicNonce, positionId));
            main.closeToInventory(jobId, block.timestamp + 60, true);
            main.halt();
        }
    }

    function estimatedGrossAssets() public view returns (uint256) {
        return main.totalAssetsUsdt();
    }

    function estimatedTotalAssets() external view returns (uint256) {
        (, uint256 feeAssets) = pendingPerformanceFee();
        return estimatedGrossAssets() - feeAssets;
    }

    /// @notice Deposit-conservative gross assets (B10-T2): the upper (max TWAP/spot)
    /// NAV. `estimatedGrossAssetsUpper() >= estimatedGrossAssets()` always (max >=
    /// min), so subtracting the same pending fee never underflows.
    function estimatedGrossAssetsUpper() public view returns (uint256) {
        return main.totalAssetsUsdtUpper();
    }

    function estimatedTotalAssetsUpper() external view returns (uint256) {
        (, uint256 feeAssets) = pendingPerformanceFee();
        return estimatedGrossAssetsUpper() - feeAssets;
    }

    function _crystallizeFeeDirect() internal returns (uint256 profit, uint256 feeAssets) {
        (profit, feeAssets) = pendingPerformanceFee();
        if (profit == 0) return (0, 0);
        uint256 idleBefore = asset.balanceOf(address(main));
        if (feeAssets != 0) {
            uint256 pulled = _pullIdle(feeAssets);
            _payFee(pulled);
            feeAssets = pulled;
        }
        accountedAssets = idleBefore - feeAssets;
        emit PerformanceFeeCharged(profit, feeAssets);
    }

    function _performanceFeeAtGrossAssets(uint256 grossAssets)
        internal
        view
        returns (uint256 profit, uint256 feeAssets)
    {
        if (grossAssets <= accountedAssets) return (0, 0);
        profit = grossAssets - accountedAssets;
        feeAssets = profit * performanceFeeBps / BPS;
    }

    function _pullIdle(uint256 amount) internal returns (uint256 pulled) {
        uint256 beforeBalance = asset.balanceOf(address(this));
        pulled = main.withdrawIdleToVault(amount);
        uint256 received = asset.balanceOf(address(this)) - beforeBalance;
        if (received != pulled) revert TransferMismatch(pulled, received);
    }

    function _payFee(uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.forceApprove(feeRecipient, amount);
        try feeSink.recordFee(amount) {
            asset.forceApprove(feeRecipient, 0);
            uint256 paid = beforeBalance - asset.balanceOf(address(this));
            if (paid != amount) revert FeeSinkPullMismatch(amount, paid);
        } catch {
            // Sink unavailable (paused, blacklist, treasury-mode, or a bug):
            // do NOT revert the user's withdrawal. Keep the fee assets in this
            // adapter as an obligation and remit them later via remitFee().
            asset.forceApprove(feeRecipient, 0);
            unremittedFee += amount;
            emit FeeRemittanceDeferred(amount, unremittedFee);
        }
    }

    /// @notice Remit previously-deferred fee assets to the immutable fee
    /// recipient. Permissionless: the sink pulls under a scoped approval, so
    /// funds can only ever reach `feeRecipient` — there is no misroute vector.
    /// Reverts if the sink still fails, which restores the obligation, so a fee
    /// is paid exactly once across any number of retries.
    function remitFee() external nonReentrant returns (uint256 remitted) {
        remitted = unremittedFee;
        if (remitted == 0) return 0;
        unremittedFee = 0;
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.forceApprove(feeRecipient, remitted);
        feeSink.recordFee(remitted);
        asset.forceApprove(feeRecipient, 0);
        uint256 paid = beforeBalance - asset.balanceOf(address(this));
        if (paid != remitted) revert FeeSinkPullMismatch(remitted, paid);
        emit FeeRemitted(remitted);
    }
}
