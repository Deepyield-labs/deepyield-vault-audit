// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPartnerWrapper (Task 1.37d / 1.37e / 1.38 — burn-after-vault.redeem ordering)
/// @notice Production surface implemented by
///         `src/partners/PartnerWrapper.sol` per
///         `docs/partners/multi-partner-attribution-design.md`
///         (revision 6, Option F v5). Carries forward from 1.37d without
///         surface changes: v6 does not modify the wrapper ABI — its
///         fixes (bounded partner accounting + active-wrapper cap) live
///         in the registry + splitter only. The contract is in-repo and
///         unit-tested; partner wrappers are NOT yet deployed live (no
///         live tx). Onboarding is deferred to the deploy task per the
///         design doc's rollout plan.
///
/// @dev One PartnerWrapper instance per generation per partner. The
///      same partnerId may have several wrappers across its lifetime
///      (current + legacy + retired); each instance has its `partnerId`
///      baked into immutable storage at construction.
///
///      Each wrapper:
///        - holds vault shares (`vault.balanceOf(this)` is this wrapper's
///          on-chain stake; `min(this, totalReceipts())` is what the
///          splitter uses for accrual),
///        - issues NON-TRANSFERABLE receipts to users 1:1 with vault
///          shares minted via `deposit(...)`,
///        - gates `deposit(...)` on `registry.canAcceptDeposits(this)`,
///          which is false for paused or retired wrappers,
///        - **burns user receipts AFTER `vault.redeem(...)` returns**
///          (the binding ordering — see step 6 below),
///        - exposes admin-only `recoverDonatedShares(to)` for donated
///          vault-share sweeping.
///
///      The wrapper does NOT notify the splitter. The splitter reads
///      `vault.balanceOf(this)` and `totalReceipts()` directly on each
///      fee event.
///
/// @dev STRICT ORDERING (binding spec, implemented in `PartnerWrapper.sol`):
///
///      deposit(usdtAmount, receiver):
///        1. require(registry.canAcceptDeposits(this), "WrapperDepositsPaused")
///        2. require(usdtAmount > 0, "ZeroAmount")
///        3. require(receiver != address(0), "ZeroAddress")
///        4. asset.transferFrom(msg.sender, this, usdtAmount)
///        5. vaultBalBefore = vault.balanceOf(this)
///        6. asset.forceApprove(vault, usdtAmount)
///        7. vault.deposit(usdtAmount, this)
///        8. sharesMinted = vault.balanceOf(this) - vaultBalBefore
///        9. _mintReceipt(receiver, sharesMinted)
///       10. asset.forceApprove(vault, 0)
///       11. require(vault.balanceOf(this) >= totalReceipts(), "WrapperUnderbalance")
///
///      redeem(receiptShares, receiver):
///        1. (nonReentrant)
///        2. require(receiptBalanceOf(msg.sender) >= receiptShares, "InsufficientReceipts")
///        3. assetBefore = asset.balanceOf(this)
///        4. vault.redeem(receiptShares, this, this)
///           // Inside vault.redeem:
///           //   - previewRedeem → assets (NET, per Task 1.31)
///           //   - _ensureLiquidity(assets) → strategy.withdrawToVault(missing)
///           //     → strategy._payFee → splitter.recordFee(amount).
///           //     AT THIS MOMENT:
///           //       vault.balanceOf(this)   = PRE-burn
///           //       wrapper.totalReceipts() = PRE-burn  (NOT YET burned)
///           //       min(...)                = PRE-burn
///           //     Splitter writes pendingForWrapper[this] += slice.
///           //   - super.redeem: vault._burn(this, receiptShares);
///           //                    asset.safeTransfer(this, assets).
///        5. usdtOut = asset.balanceOf(this) - assetBefore
///        6. _burnReceipt(msg.sender, receiptShares)
///           // Now wrapper.totalReceipts() and vault.balanceOf(this)
///           // are both decreased by receiptShares → invariant restored.
///        7. asset.safeTransfer(receiver, usdtOut)
///        8. require(vault.balanceOf(this) >= totalReceipts(), "WrapperUnderbalance")
///
///      recoverDonatedShares(to):
///        1. onlyRole(ADMIN_ROLE)
///        2. excess = vault.balanceOf(this) - totalReceipts()
///        3. if excess == 0 return
///        4. vault.redeem(excess, to, this)
///        5. emit DonationRecovered(to, excess)
///
///      RATIONALE for burn-after-vault.redeem (B1 fix in Task 1.37d):
///        The fee event happens INSIDE vault.redeem, before the vault
///        burns the wrapper's shares. If the wrapper burns the user's
///        receipt BEFORE vault.redeem (as Task 1.37c specified), then at
///        fee-event time vault.balanceOf=pre-burn but totalReceipts=
///        post-burn. min(pre, post) = post = zero on full exit. Partner
///        accrues zero on the exit fee event of capital they sourced.
///        Wrong economics.
///
///        Burning AFTER vault.redeem keeps both values pre-burn at fee
///        time. min(pre, pre) = pre. Partner accrues fully on capital
///        provided up to this moment. Donation defense (min cap) is
///        unaffected because it triggers only when an external party
///        pumps vault.balanceOf OUTSIDE the receipt-minting path —
///        which happens before/between txs, not inside wrapper.redeem.
interface IPartnerWrapper {
    // ── events ──

    event WrapperDeposit(
        address indexed user,
        uint256 usdtAmount,
        uint256 receiptShares
    );

    event WrapperRedeem(
        address indexed user,
        uint256 receiptShares,
        uint256 usdtOut
    );

    event DonationRecovered(address indexed to, uint256 vaultSharesBurned, uint256 usdtOut);

    // ── errors ──

    error WrapperDepositsPaused();
    error InsufficientReceipts();
    error ReceiptsNonTransferable();
    error WrapperUnderbalance();
    error ZeroAmount();
    error ZeroAddress();
    error ZeroPartnerId();

    // ── views ──

    function partnerId() external view returns (bytes32);
    function vault()    external view returns (address);
    function asset()    external view returns (address);
    function registry() external view returns (address);

    function totalReceipts() external view returns (uint256);
    function receiptBalanceOf(address user) external view returns (uint256);

    /// @notice Vault-side share-count excess sitting at this wrapper
    /// outside the receipt-backed amount. Should be 0 in normal
    /// operation; non-zero indicates an external `vault.transfer(W, X)`
    /// donation. The splitter's `min(...)` cap makes the excess
    /// invisible to fee distribution; admin can sweep via
    /// `recoverDonatedShares`.
    function donatedExcess() external view returns (uint256);

    // ── state-changing ──

    /// @notice Deposit `usdtAmount` of vault asset and mint receipt to
    /// `receiver`. Reverts `WrapperDepositsPaused` if
    /// `registry.canAcceptDeposits(this) == false` (paused, retired,
    /// or unregistered).
    function deposit(uint256 usdtAmount, address receiver)
        external
        returns (uint256 sharesMinted);

    /// @notice Redeem `receiptShares` from `msg.sender`'s receipt
    /// balance. Calls `vault.redeem(receiptShares, this, this)` FIRST,
    /// then burns the user's receipt. The in-vault fee event sees
    /// `min(vault.balanceOf(this) = pre-burn, totalReceipts = pre-burn) = pre-burn`,
    /// so partner accrues fully on the capital they sourced through
    /// this exiting user — including on full-exit redemption.
    function redeem(uint256 receiptShares, address receiver)
        external
        returns (uint256 usdtOut);

    /// @notice Admin-only sweep of donated vault shares.
    /// `donatedExcess()` is converted to USDT via `vault.redeem(...)`
    /// and forwarded to `to`. Recommended `to` is the project
    /// treasury — donations are not partner economics.
    function recoverDonatedShares(address to) external returns (uint256 usdtOut);

    // ── ERC-20-like receipt surface, with transferability disabled ──
    //
    // Implementations SHOULD revert transfer / transferFrom / approve
    // (or return false). Receipt balances change ONLY via deposit
    // (mint) and redeem (burn).
}
