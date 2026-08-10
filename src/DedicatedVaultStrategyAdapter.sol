// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDeepYieldStrategy} from "./interfaces/IDeepYieldStrategy.sol";
import {DedicatedVaultMain} from "./DedicatedVaultMain.sol";

/// @title DedicatedVaultStrategyAdapter (PROTOTYPE — no funds, not wired)
/// @notice IDeepYieldStrategy bridge between the ERC-4626 `DeepYieldVault` and a
/// `DedicatedVaultMain`. The adapter is the Main's immutable `vault` (sole funder/
/// withdrawer); the adapter's own `vault` is the ERC-4626 vault. All egress is
/// vault-only — there is no arbitrary-recipient transfer here either.
///
/// Wiring requirement (prod + tests): the admin grants this adapter
/// `GUARDIAN_ROLE` on the Main so `panic()` can close-to-idle. Closing an active
/// position during a normal `managerWithdrawAll` is intentionally NOT possible
/// (close is keeper/guardian-only) — separation of duties. The full-exit flow is
/// keeper.closePosition() (or panic) THEN managerWithdrawAll().
contract DedicatedVaultStrategyAdapter is IDeepYieldStrategy, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @dev Hard ceiling on the configurable performance fee (guard against misconfig).
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3000; // 30%

    IERC20 public immutable asset;          // USDT
    /// @dev The ERC-4626 vault this adapter serves — the NEW standalone Vault B
    /// (`DeepYieldVault_B`), NOT the existing Beefy Vault A. (Naming: this `vault`
    /// is the ERC-4626 vault; prod rename → `erc4626Vault`. See
    /// docs/specs/vault-b-standalone-architecture.md.)
    address public immutable vault;
    DedicatedVaultMain public immutable main;
    /// @dev Performance fee on REALIZED USDT profit only (20% = 2000 bps). Crystallized
    /// in `harvest()`; sent to `feeRecipient` only (no arbitrary recipient).
    uint16 public immutable performanceFeeBps;
    address public immutable feeRecipient;

    uint256 public accountedAssets;          // principal cost basis (high-water in USDT)

    error NotVault();
    error ZeroAddress();
    error FeeTooHigh();

    event Deployed(uint256 assets);
    event WithdrawnToVault(uint256 assets);
    event PerformanceFeeCharged(uint256 realizedProfit, uint256 feeAssets);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(
        IERC20 asset_,
        address vault_,
        DedicatedVaultMain main_,
        address admin_,
        address manager_,
        address guardian_,
        address feeRecipient_,
        uint16 performanceFeeBps_
    ) {
        if (
            address(asset_) == address(0) || vault_ == address(0) || address(main_) == address(0) ||
            admin_ == address(0) || manager_ == address(0) || guardian_ == address(0) ||
            feeRecipient_ == address(0)
        ) revert ZeroAddress();
        if (performanceFeeBps_ > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        asset = asset_;
        vault = vault_;
        main = main_;
        feeRecipient = feeRecipient_;
        performanceFeeBps = performanceFeeBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MANAGER_ROLE, manager_);
        _grantRole(GUARDIAN_ROLE, guardian_);
    }

    /// @notice Pull `assets` USDT from the ERC-4626 vault and fund the Main (idle
    /// until the keeper opens). Manager-gated.
    function deploy(uint256 assets) external onlyRole(MANAGER_ROLE) nonReentrant {
        asset.safeTransferFrom(vault, address(this), assets);
        asset.forceApprove(address(main), assets);
        main.fundFromVault(assets); // Main pulls from this adapter (adapter == Main.vault)
        asset.forceApprove(address(main), 0);
        accountedAssets += assets;
        emit Deployed(assets);
    }

    /// @notice Vault redeem path. Pulls idle from Main → forwards to the vault.
    /// Fails CLOSED (Main reverts PositionActive) if an active position would be
    /// needed — redeem-while-active is deferred by design (no partial decrease).
    /// @dev Crystallizes the performance fee FIRST so realized profit can never exit
    /// fee-free by withdrawing before `harvest()` (order-independent enforcement).
    function withdrawToVault(uint256 assetsNeeded) external onlyVault nonReentrant returns (uint256 withdrawn) {
        _crystallizeFee();
        withdrawn = main.withdrawToVault(assetsNeeded); // → sent to this adapter
        asset.safeTransfer(vault, withdrawn);
        accountedAssets = withdrawn >= accountedAssets ? 0 : accountedAssets - withdrawn;
        emit WithdrawnToVault(withdrawn);
    }

    /// @notice Withdraw ALL currently-idle Main funds to the vault. Does NOT
    /// close an active position (keeper/guardian responsibility — see panic()).
    /// @dev Crystallizes the performance fee FIRST (same anti-bypass invariant).
    function managerWithdrawAll() external onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 withdrawn) {
        _crystallizeFee();
        uint256 idle = main.idleAsset();
        if (idle > 0) {
            withdrawn = main.withdrawToVault(idle); // → this adapter
            asset.safeTransfer(vault, withdrawn);
        }
        if (!main.hasActivePosition()) {
            accountedAssets = 0;
        } else {
            accountedAssets = withdrawn >= accountedAssets ? 0 : accountedAssets - withdrawn;
        }
    }

    /// @notice Crystallize the performance fee on REALIZED USDT profit. 20% of
    /// (redeem-ready idle USDT − cost basis), charged ONLY when the Main is redeem-ready
    /// in USDT (no active position). Never on: unrealized NAV (position active), idle
    /// WBNB/CAKE before conversion (idleAsset counts USDT only), loss, or principal
    /// recovery. Fee USDT is pulled from the Main (vault-only egress) and sent to
    /// `feeRecipient` only. `accountedAssets` is reset to the post-fee balance so a
    /// duplicate harvest cannot double-charge. Manager-gated.
    function harvest() external onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 profit, uint256 feeAssets) {
        return _crystallizeFee();
    }

    /// @notice View-only accrued performance fee on REALIZED USDT profit (the same
    /// formula `_crystallizeFee()` uses, no state change). Nonzero only when the Main is
    /// redeem-ready (`!hasActivePosition`) and idle USDT exceeds the cost basis — so it is
    /// zero on an active position (unrealized NAV), loss, zero-profit, or principal-only.
    function pendingPerformanceFee() public view returns (uint256 profit, uint256 feeAssets) {
        if (main.hasActivePosition()) return (0, 0);
        uint256 idleUsdt = main.idleAsset(); // realized USDT only (excludes WBNB/CAKE)
        if (idleUsdt <= accountedAssets) return (0, 0); // loss / zero-profit / principal-only
        profit = idleUsdt - accountedAssets;
        feeAssets = (profit * performanceFeeBps) / 10_000;
    }

    /// @dev Crystallize the performance fee on realized USDT profit. Invoked by
    /// `harvest()` AND by every withdraw path (so the fee cannot be bypassed by
    /// withdrawing before harvest). Single mutating fee path; shares the formula with
    /// `pendingPerformanceFee()`.
    function _crystallizeFee() internal returns (uint256 profit, uint256 feeAssets) {
        (profit, feeAssets) = pendingPerformanceFee();
        if (profit == 0) return (0, 0); // active / loss / zero-profit → nothing to do
        uint256 idleUsdt = main.idleAsset();
        if (feeAssets > 0) {
            uint256 pulled = main.withdrawToVault(feeAssets); // USDT → this adapter (vault-only)
            asset.safeTransfer(feeRecipient, pulled);          // fee → recipient ONLY
            feeAssets = pulled;
        }
        // bank realized profit: remaining redeemable in Main is the new cost basis.
        accountedAssets = idleUsdt - feeAssets;
        emit PerformanceFeeCharged(profit, feeAssets);
    }

    /// @notice Emergency: close the Main position to idle and pause it. Requires
    /// this adapter to hold GUARDIAN_ROLE on the Main. Funds stay in the Main
    /// (idle) → pulled to the vault later via withdrawToVault. No arbitrary transfer.
    function panic() external onlyRole(GUARDIAN_ROLE) nonReentrant {
        main.emergencyClose();
    }

    /// @notice Gross on-chain NAV (operator diagnostics) — Main's conservative USDT NAV,
    /// before any performance fee.
    function estimatedGrossAssets() public view returns (uint256) {
        return main.totalAssetsUsdt();
    }

    /// @notice NET user-facing NAV: gross minus the accrued performance fee. This is what
    /// the ERC-4626 vault reads for `totalAssets()`, so share price / previews never
    /// overstate user-redeemable assets by the pending fee. While a position is active the
    /// pending fee is zero (no reserve on unrealized NAV) → net == gross there.
    function estimatedTotalAssets() external view returns (uint256) {
        (, uint256 feeAssets) = pendingPerformanceFee();
        return estimatedGrossAssets() - feeAssets; // no underflow: fee ≤ idle ≤ gross
    }
}
