// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16 >=0.6.2 >=0.8.4 ^0.8.20;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// lib/openzeppelin-contracts/contracts/access/IAccessControl.sol

// OpenZeppelin Contracts (last updated v5.4.0) (access/IAccessControl.sol)

/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted to signal this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// src/interfaces/IFeeSink.sol

/// @title IFeeSink
/// @notice Interface for any contract that wants to receive protocol-fee
///         transfers from `BeefyCLMAdapter` AND lock the recipient
///         entitlement at the time the fee is realized (NOT at the time it is
///         later distributed).
/// @dev    The intended implementer is `FeeSplitter`. A non-sink (plain EOA
///         or generic Safe) treasury is also supported via the strategy's
///         `treasuryIsFeeSink` flag, in which case `recordFee` is NOT called.
interface IFeeSink {
    /// @notice Pulls `amount` of the fee asset from `msg.sender` (the strategy)
    ///         and locks its split per the sink's current configuration.
    ///         Caller MUST have set ERC-20 allowance for this contract to at
    ///         least `amount` before calling.
    /// @dev    Implementations MUST do the actual `transferFrom` so the
    ///         strategy can verify the pull happened via a balance delta.
    function recordFee(uint256 amount) external;
}

// src/interfaces/IPartnerRegistry.sol

/// @title IPartnerRegistry (Task 1.37e / 1.38 — active vs historical sets, sized cap)
/// @notice Production surface implemented by `src/partners/PartnerRegistry.sol`
///         per `docs/partners/multi-partner-attribution-design.md`
///         (revision 6, Option F v5). The contract is in-repo and unit-
///         tested; it is NOT yet live-wired (no live tx). Cut-over is
///         deferred to the deploy task per the design doc's rollout plan.
///
///         ----------------- REJECTED SURFACES -----------------
///         Task 1.37 v1 (Option D):
///             `partnerOf(address user)`, `attributeUser(...)`.
///             Rejected: retroactive user capture.
///         Task 1.37a v1 (mirror + notify):
///             Pause flag conflated deposit gate + accrual gate.
///             Rejected: paused-wrapper accounting contradiction.
///         Task 1.37b v1:
///             Splitter held its OWN `wrapperList`. Two sources of truth.
///             Rejected: non-atomic onboarding.
///         Task 1.37c v1:
///             One-to-one `wrapperOfPartner[partnerId]` with no
///             replacement path.
///             Rejected: no migration story.
///         Task 1.37d v1:
///             `wrapperList()` + `MAX_WRAPPERS = 50` conflated the
///             bounded accrual set with the append-only historical
///             history of `wrappersOfPartner[]`; 50 was insufficient
///             fleet-wide replacement headroom for ~30 partners.
///             Rejected: capacity guarantee depended on ops policy
///             (retire-before-replace), not on the cap.
///         All rejected surfaces are deliberately absent from this revision.
///
/// @dev Two structurally distinct sets:
///
///        1. ACTIVE SET (`activeWrapperList()`):
///             - Bounded: `len <= MAX_ACTIVE_WRAPPERS = 128`.
///             - Contents: Active + PausedDeposits wrappers only. Retired
///               wrappers are removed (swap-and-pop) on `retireWrapper(...)`.
///             - The only set iterated on-chain by accrual. The splitter's
///               `recordFee(...)` iterates this list.
///             - Append happens via factory (`deployFirstWrapper` or
///               `deployReplacementWrapper`); both revert
///               `ActiveWrapperListFull` at the cap.
///             - Remove happens via admin `retireWrapper(W)` once W is
///               drained (`vault.balanceOf(W) == 0`).
///
///        2. HISTORICAL SET (`wrappersOfPartner(partnerId)`):
///             - Unbounded across a partner's lifetime: append-only on
///               every registration.
///             - Never iterated on-chain by accrual or settlement.
///             - Used for off-chain reporting (e.g. dashboard listing
///               every wrapper ever issued for a partnerId).
///             - Retired wrappers stay in this set forever.
///
///      Cap sizing: 30 partners ⇒ steady-state active count ~30.
///      Single fleet-wide replacement (every partner replaced) ⇒ 60.
///      Triple-generation pile-up + new-partner onboarding +
///      emergency parallel wrappers ⇒ ~120. Rounded to 128 (2^7),
///      giving ~4× steady-state structural buffer. See §4.B of the
///      design doc.
///
/// @dev Generational wrapper model:
///        - Each partnerId has ONE current deposit-target wrapper
///          (`currentWrapperOf[partnerId]`).
///        - Each partnerId has ZERO OR MORE legacy wrappers in
///          `wrappersOfPartner[partnerId]`. Legacy wrappers can be
///          Active (current) → PausedDeposits (on replacement) →
///          Retired (after drain).
///        - `partnerOfWrapper[wrapper]` is set ONCE at registration and
///          immutable thereafter.
///        - Wrapper deploy + register is ATOMIC via the factory:
///          `factory.deployFirstWrapper(partnerId, payoutTreasury)` OR
///          `factory.deployReplacementWrapper(partnerId)`.
///        - `registerPartner` and `addReplacementWrapper` are factory-only.
///        - `retireWrapper(W)` is admin-only and requires
///          `vault.balanceOf(W) == 0 && W != currentWrapperOf[partnerOf(W)]`.
interface IPartnerRegistry {
    // ── events ──

    event PartnerRegistered(
        bytes32 indexed partnerId,
        address indexed wrapper,
        address indexed payoutTreasury
    );

    event WrapperReplaced(
        bytes32 indexed partnerId,
        address indexed oldCurrent,
        address indexed newCurrent
    );

    event WrapperRetired(bytes32 indexed partnerId, address indexed wrapper);

    event PartnerTreasuryUpdated(
        bytes32 indexed partnerId,
        address indexed oldTreasury,
        address indexed newTreasury
    );

    event WrapperDepositsPaused(bytes32 indexed partnerId, address indexed wrapper);
    event WrapperDepositsUnpaused(bytes32 indexed partnerId, address indexed wrapper);

    // ── errors ──

    error PartnerAlreadyRegistered();
    error PartnerNotRegistered();
    error WrapperAlreadyRegistered();
    error WrapperNotRegistered();
    error ActiveWrapperListFull();
    error WrapperRetiredAlready();
    error WrapperHasShares();
    error CannotRetireCurrent();
    error CannotUnpauseLegacy();
    error CallerNotFactory();
    error ZeroAddress();
    error ZeroPartnerId();
    /// @notice Reverted by `setFactory(...)` on the second invocation.
    /// The factory binding is one-shot — after the first successful
    /// `setFactory`, the value is effectively immutable.
    error FactoryAlreadySet();
    /// @notice Reverted by `setFactory(...)` when the candidate fails
    /// end-to-end wiring validation (not a contract; its `registry()`
    /// does not point back at this registry; its `vault()` does not
    /// match this registry's `vault`; or any of those views revert /
    /// return non-conforming data). See `setFactory(...)` NatSpec.
    error InvalidFactory();

    // ── views: per-wrapper / per-partner state ──

    function partnerOfWrapper(address wrapper) external view returns (bytes32);

    /// @notice The currently active deposit-target wrapper for `partnerId`.
    /// Front-ends resolve referral links to this address. Returns
    /// `address(0)` if the partner has never been registered.
    function currentWrapperOf(bytes32 partnerId) external view returns (address);

    /// @notice All wrappers ever associated with `partnerId`, in
    /// registration order. APPEND-ONLY (retired wrappers stay in this
    /// list for historical reporting). UNBOUNDED across generations.
    /// THIS LIST IS NEVER ITERATED ON-CHAIN BY ACCRUAL OR SETTLEMENT.
    /// Off-chain consumers may read it; on-chain consumers must read
    /// `activeWrapperList()` instead.
    function wrappersOfPartner(bytes32 partnerId) external view returns (address[] memory);

    function payoutTreasury(bytes32 partnerId) external view returns (address);

    function isRegisteredWrapper(address wrapper) external view returns (bool);
    function isWrapperDepositsPaused(address wrapper) external view returns (bool);
    function isRetiredWrapper(address wrapper) external view returns (bool);

    /// @notice True iff `wrapper.deposit(...)` should be accepted RIGHT NOW.
    /// Equivalent to: `isRegisteredWrapper(W) && !isWrapperDepositsPaused(W) && !isRetiredWrapper(W)`.
    /// Wrappers call this directly from `deposit()` as the single gate.
    function canAcceptDeposits(address wrapper) external view returns (bool);

    // ── views: active accrual-iterable set ──
    //
    // This is the BOUNDED set iterated on-chain by
    // `PartnerAttributedSplitter.recordFee(...)`. Contents are Active +
    // PausedDeposits wrappers; Retired wrappers are excluded
    // (swap-and-pop on `retireWrapper`). Length is hard-capped at
    // `MAX_ACTIVE_WRAPPERS`.

    /// @notice Returns the active accrual-iterable wrapper list. Used
    /// by `splitter.recordFee(...)` to enumerate per-fee event. Excludes
    /// Retired wrappers.
    function activeWrapperList() external view returns (address[] memory);

    function activeWrapperCount() external view returns (uint256);
    function activeWrapperAt(uint256 index) external view returns (address);

    /// @notice Hard cap on `activeWrapperCount()`. Sized for ~4× the
    /// steady-state footprint of 30 partners, providing structural
    /// headroom for multi-cycle fleet-wide replacement events without
    /// depending on retire-before-replace ops discipline. See §4.B of
    /// the design doc.
    function MAX_ACTIVE_WRAPPERS() external view returns (uint256);

    function factory() external view returns (address);

    /// @notice The ERC-4626 vault that this registry's wrappers wrap.
    /// Set once at construction and immutable. Used by `retireWrapper`
    /// to enforce the drained precondition, and by the
    /// `PartnerAttributedSplitter` to look up `vault.balanceOf(W)` per
    /// fee event.
    function vault() external view returns (address);

    // ── one-shot wiring (admin) ──

    /// @notice Bind this registry to its `WrapperFactory`.
    ///
    /// One-shot: callable exactly once by `ADMIN_ROLE`. After the first
    /// successful call, further invocations revert `FactoryAlreadySet`.
    /// Once bound, the value returned by `factory()` is effectively
    /// immutable for the lifetime of the registry.
    ///
    /// The candidate is cross-validated end-to-end (Task 1.38a) so a
    /// typo or wrong contract address cannot silently brick onboarding:
    ///
    ///   - `factory_` must be a deployed contract (`code.length > 0`)
    ///   - `IWrapperFactory(factory_).registry() == address(this)`
    ///   - `IWrapperFactory(factory_).vault() == vault`
    ///
    /// On any validation failure (including a non-conforming candidate
    /// whose `registry()` / `vault()` views revert), reverts
    /// `InvalidFactory()`. Reverts `ZeroAddress()` on the zero address.
    function setFactory(address factory_) external;

    // ── factory-only entry points (atomic onboarding) ──

    /// @notice Registers the first wrapper for a partner. Caller MUST
    /// be `factory()`. Sets currentWrapperOf, appends to wrappersOfPartner,
    /// appends to activeWrapperList, sets payoutTreasury. Reverts:
    ///   - CallerNotFactory if msg.sender != factory()
    ///   - ZeroPartnerId / ZeroAddress
    ///   - PartnerAlreadyRegistered if `currentWrapperOf[partnerId] != 0`
    ///   - WrapperAlreadyRegistered if `partnerOfWrapper[wrapper] != 0`
    ///   - ActiveWrapperListFull if `activeWrapperCount() == MAX_ACTIVE_WRAPPERS`
    function registerPartner(
        bytes32 partnerId,
        address wrapper,
        address payoutTreasury_
    ) external;

    /// @notice Registers a replacement wrapper for an existing partner.
    /// Caller MUST be `factory()`. Atomically:
    ///   - pauses the old current (sets isWrapperDepositsPaused = true)
    ///   - records the new wrapper under partnerOfWrapper / wrappersOfPartner
    ///   - sets currentWrapperOf = newWrapper
    ///   - appends newWrapper to activeWrapperList
    /// Reverts:
    ///   - CallerNotFactory
    ///   - PartnerNotRegistered if `currentWrapperOf[partnerId] == 0`
    ///   - WrapperAlreadyRegistered
    ///   - ActiveWrapperListFull
    function addReplacementWrapper(bytes32 partnerId, address newWrapper) external;

    // ── admin-only (Safe) ──

    function updatePartnerTreasury(bytes32 partnerId, address newTreasury) external;

    /// @notice Stop new deposits via `wrapper.deposit(...)`. Redeems
    /// remain available. Wrapper stays in `activeWrapperList()` and
    /// continues to accrue protocol-fee share on whatever vault shares
    /// it still holds.
    function pauseDepositsForWrapper(address wrapper) external;

    /// @notice Unpause deposits on a wrapper. Reverts
    /// `CannotUnpauseLegacy` if `wrapper != currentWrapperOf(partnerOfWrapper(wrapper))`
    /// - only the CURRENT wrapper can be unpaused. This prevents two
    /// simultaneous deposit-active wrappers from existing for the same
    /// partner.
    function unpauseDepositsForWrapper(address wrapper) external;

    /// @notice Retire a fully-drained wrapper. Reverts:
    ///   - WrapperNotRegistered if W is not registered
    ///   - WrapperRetiredAlready if W is already retired
    ///   - CannotRetireCurrent if W is the current wrapper of its partner
    ///     (must replace first via factory.deployReplacementWrapper)
    ///   - WrapperHasShares if `vault.balanceOf(W) != 0`
    /// On success: sets isRetiredWrapper[W] = true; removes W from
    /// `activeWrapperList` (swap-and-pop) — freeing one slot toward
    /// `MAX_ACTIVE_WRAPPERS`. W stays in `wrappersOfPartner[]` for
    /// historical reporting. `splitter.pendingForWrapper[W]` survives
    /// and remains claimable.
    function retireWrapper(address wrapper) external;
}

// src/interfaces/IPartnerWrapper.sol

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

// lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/ERC165.sol)

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC165.sol)

// lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC20.sol)

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// src/interfaces/IPartnerAttribution.sol

/// @title IPartnerAttribution (Task 1.37e / 1.38 — bounded settlement & reporting)
/// @notice Production surface implemented by
///         `src/partners/PartnerAttributedSplitter.sol` per
///         `docs/partners/multi-partner-attribution-design.md`
///         (revision 6, Option F v5). The contract is in-repo and unit-
///         tested; it is NOT yet wired to strategy v2 as `treasury` (no
///         live tx). Cut-over is deferred to the deploy task per the
///         design doc's rollout plan.
///
///         ----------------- REJECTED SURFACES -----------------
///         Task 1.37 v1: `recordAttributedFee(uint256, address)`, per-partnerId
///             pools keyed by signature-attributed users.  Rejected:
///             retroactive user capture.
///         Task 1.37a v1: `notifyWrapperBalanceChange`, `accFeePerAttributedShare`,
///             `totalAttributed`, `resyncWrapper`.  Rejected:
///             mirror+notify drift.
///         Task 1.37b v1: splitter-side `addWrapper`/`removeWrapper`/`wrapperList`/
///             `wrapperAt`/`wrapperCount`/`isRegisteredWrapper`/`MAX_WRAPPERS`.
///             Rejected: two sources of truth.
///         Task 1.37c v1: no `claimPartner(...)` aggregate.  Superseded.
///         Task 1.37d v1: `claimPartner(bytes32 partnerId)` aggregate +
///             `previewPendingForPartner(bytes32 partnerId)` view +
///             `PartnerClaimed(...)` event.  All three iterated
///             `registry.wrappersOfPartner(partnerId)`, which is
///             append-only across the partner's lifetime - unbounded
///             gas growth across generations even after retirement.
///             Rejected: unbounded partner-level helpers over historical
///             wrapper sets.  All three are deliberately ABSENT from
///             this revision.
///
/// @dev Final design (1.37e / v5):
///        - Splitter has NO wrapper list of its own. It reads
///          `registry.activeWrapperList()` on every `recordFee(...)`.
///        - Per-wrapper accrual is capped at
///          `min(vault.balanceOf(W), W.totalReceipts())`.
///        - The redeeming user's wrapper accrues fully on the fee event
///          they themselves triggered - wrapper.redeem burns receipts
///          AFTER `vault.redeem(...)` completes, so at fee-event time
///          both `vault.balanceOf(W)` and `W.totalReceipts()` are
///          pre-burn.  `min(pre, pre) = pre`.  See §6 of the design doc.
///        - `claimWrapper(W)` is the SOLE on-chain settlement primitive.
///          A partner with multiple pending generations drains them by
///          off-chain enumeration of `registry.wrappersOfPartner(pid)`
///          followed by a multicall of `claimWrapper(W_i)` for each W
///          with `pendingForWrapper(W) > 0`.
///        - `pendingPerPartner(partnerId)` is an O(1) BOUNDED counter:
///          maintained `+= wSlice` on every per-wrapper accrual inside
///          `recordFee`, and `-= paid` on every `claimWrapper`. The
///          invariant `Σ pendingForWrapper(W) for W : partnerOfWrapper(W)
///          == pid == pendingPerPartner(pid)` is maintained by
///          construction. Partner dashboards read this view directly.
///        - Cumulative counters `cumulativeAccruedPerPartner(pid)` and
///          `cumulativeClaimedPerPartner(pid)` are append-only O(1)
///          maintenance fields.
///        - Double-claim risk is structurally impossible: only
///          `claimWrapper(W)` drains; it zeroes `pendingForWrapper[W]`
///          before transfer; symmetric `pendingPerPartner[pid]` write.
interface IPartnerAttribution is IFeeSink {
    // ── events ──

    /// @dev Emitted once per `recordFee`.
    event FeeRouted(
        uint256 amount,
        uint256 projectBaseSlice,
        uint256 projectHouseSlice,
        uint256 distributedToWrappers,
        uint256 totalSupplyAtEvent,
        uint256 partnerShareBpsAtEvent
    );

    event WrapperPendingAccrued(address indexed wrapper, uint256 slice);

    event WrapperClaimed(
        bytes32 indexed partnerId,
        address indexed wrapper,
        address indexed payoutTreasury,
        uint256 amount
    );

    event ProjectClaimed(address indexed projectTreasury, uint256 amount);

    event PartnerShareBpsUpdated(uint256 oldBps, uint256 newBps);
    event ProjectTreasuryUpdated(address indexed oldT, address indexed newT);
    event UnrecordedRecovered(uint256 amount);

    // ── errors ──

    error InvalidBps();
    error ZeroAddress();
    error PartnerNotRegistered();
    error WrapperNotRegistered();

    // ── splitter-side state ──

    function registry() external view returns (address);
    function vault()    external view returns (address);

    function partnerShareBps() external view returns (uint256);
    function projectTreasury() external view returns (address);

    /// @notice Pending USDT that would settle to wrapper W's partner
    /// treasury on `claimWrapper(W)`. Locked at receipt-time bps; a
    /// later `setPartnerShareBps(...)` does NOT retroactively reprice
    /// already-pending pools. Persists across wrapper state changes
    /// (PausedDeposits, Retired) and is always claimable. This is the
    /// canonical per-wrapper pending pool that backs settlement.
    function pendingForWrapper(address wrapper) external view returns (uint256);

    /// @notice O(1) bounded partner-level pending counter. Maintained
    /// by symmetric `+=` (recordFee per-wrapper) and `-=` (claimWrapper).
    /// Invariant: `pendingPerPartner(pid) == Σ pendingForWrapper(W)`
    /// over every W where `registry.partnerOfWrapper(W) == pid`. This
    /// is the bounded reporting primitive that replaces 1.37d's
    /// iteration-based `previewPendingForPartner`.
    function pendingPerPartner(bytes32 partnerId) external view returns (uint256);

    function pendingProjectBaseSlice() external view returns (uint256);
    function pendingProjectHouseSlice() external view returns (uint256);

    function cumulativeReceived() external view returns (uint256);
    function cumulativeProject() external view returns (uint256);

    function cumulativeClaimedPerWrapper(address wrapper) external view returns (uint256);

    /// @notice Lifetime sum of accrued partner slices for `partnerId`
    /// across ALL the partner's wrappers (current + paused + retired).
    /// O(1) read; maintained `+= wSlice` in `recordFee` body per
    /// wrapper iteration. Append-only.
    function cumulativeAccruedPerPartner(bytes32 partnerId) external view returns (uint256);

    /// @notice Lifetime sum of claimed amounts for `partnerId` across
    /// all wrappers ever registered under it. O(1) read; maintained
    /// `+= paid` in `claimWrapper`. Append-only.
    function cumulativeClaimedPerPartner(bytes32 partnerId) external view returns (uint256);

    function unrecordedBalance() external view returns (uint256);

    /// @notice Compute what `wrapper` WOULD accrue if a fee of `amount`
    /// were recorded right now, given live `vault.balanceOf(wrapper)`,
    /// live `wrapper.totalReceipts()`, and `vault.totalSupply()`.
    /// O(1).
    function previewWrapperSlice(uint256 amount, address wrapper)
        external
        view
        returns (uint256 wrapperSlice);

    // ── permissionless settlement ──

    /// @notice The SOLE on-chain settlement primitive for the partner
    /// side. Drains `pendingForWrapper[wrapper]` to the partner's
    /// payout treasury (`registry.payoutTreasury(partnerOfWrapper(W))`).
    /// Decrements `pendingPerPartner[pid]` by the same amount to
    /// maintain the per-partner counter invariant. Increments
    /// `cumulativeClaimedPerWrapper[wrapper]` and
    /// `cumulativeClaimedPerPartner[pid]`. Anyone can call. Works for
    /// Active, PausedDeposits, and Retired wrappers (any wrapper with
    /// residual pending).
    function claimWrapper(address wrapper) external returns (uint256 paid);

    /// @notice Drains `pendingProjectBaseSlice + pendingProjectHouseSlice`
    /// to `projectTreasury`. Anyone can call.
    function claimProject() external returns (uint256 paid);

    // ── admin-only (Safe) ──

    /// @notice Future fee events use the new bps. Already-pending
    /// balances are locked at the bps they were recorded with
    /// (receipt-time locking - preserved from Task 1.32).
    function setPartnerShareBps(uint256 newBps) external;

    function setProjectTreasury(address newTreasury) external;

    /// @notice Sweeps `unrecordedBalance()` to the project treasury.
    function recoverUnrecorded() external returns (uint256 recovered);
}

// lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.5.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 *
 * IMPORTANT: Deprecated. This storage-based reentrancy guard will be removed and replaced
 * by the {ReentrancyGuardTransient} variant in v6.0.
 *
 * @custom:stateless
 */
abstract contract ReentrancyGuard {
    using StorageSlot for bytes32;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    /**
     * @dev A `view` only version of {nonReentrant}. Use to block view functions
     * from being called, preventing reading from inconsistent contract state.
     *
     * CAUTION: This is a "view" modifier and does not change the reentrancy
     * status. Use it only on view functions. For payable or non-payable functions,
     * use the standard {nonReentrant} modifier instead.
     */
    modifier nonReentrantView() {
        _nonReentrantBeforeView();
        _;
    }

    function _nonReentrantBeforeView() private view {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        _nonReentrantBeforeView();

        // Any calls to nonReentrant after this point will fail
        _reentrancyGuardStorageSlot().getUint256Slot().value = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _reentrancyGuardStorageSlot().getUint256Slot().value == ENTERED;
    }

    function _reentrancyGuardStorageSlot() internal pure virtual returns (bytes32) {
        return REENTRANCY_GUARD_STORAGE;
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol

// OpenZeppelin Contracts (last updated v5.5.0) (interfaces/IERC4626.sol)

/**
 * @dev Interface of the ERC-4626 "Tokenized Vault Standard", as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[ERC-4626].
 */
interface IERC4626 is IERC20, IERC20Metadata {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /**
     * @dev Returns the address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
     *
     * - MUST be an ERC-20 token contract.
     * - MUST NOT revert.
     */
    function asset() external view returns (address assetTokenAddress);

    /**
     * @dev Returns the total amount of the underlying asset that is “managed” by Vault.
     *
     * - SHOULD include any compounding that occurs from yield.
     * - MUST be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT revert.
     */
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /**
     * @dev Returns the amount of shares that the Vault would exchange for the amount of assets provided, in an ideal
     * scenario where all the conditions are met.
     *
     * - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT show any variations depending on the caller.
     * - MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
     * - MUST NOT revert.
     *
     * NOTE: This calculation MAY NOT reflect the “per-user” price-per-share, and instead should reflect the
     * “average-user’s” price-per-share, meaning what the average user should expect to see when exchanging to and
     * from.
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of assets that the Vault would exchange for the amount of shares provided, in an ideal
     * scenario where all the conditions are met.
     *
     * - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT show any variations depending on the caller.
     * - MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
     * - MUST NOT revert.
     *
     * NOTE: This calculation MAY NOT reflect the “per-user” price-per-share, and instead should reflect the
     * “average-user’s” price-per-share, meaning what the average user should expect to see when exchanging to and
     * from.
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of the underlying asset that can be deposited into the Vault for the receiver,
     * through a deposit call.
     *
     * - MUST return a limited value if receiver is subject to some deposit limit.
     * - MUST return 2 ** 256 - 1 if there is no limit on the maximum amount of assets that may be deposited.
     * - MUST NOT revert.
     */
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given
     * current on-chain conditions.
     *
     * - MUST return as close to and no more than the exact amount of Vault shares that would be minted in a deposit
     *   call in the same transaction. I.e. deposit should return the same or more shares as previewDeposit if called
     *   in the same transaction.
     * - MUST NOT account for deposit limits like those returned from maxDeposit and should always act as though the
     *   deposit would be accepted, regardless if the user has enough tokens approved, etc.
     * - MUST be inclusive of deposit fees. Integrators should be aware of the existence of deposit fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToShares and previewDeposit SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by depositing.
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Deposit `assets` underlying tokens and send the corresponding number of vault shares (`shares`) to `receiver`.
     *
     * - MUST emit the Deposit event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   deposit execution, and are accounted for during deposit.
     * - MUST revert if all of assets cannot be deposited (due to deposit limit being reached, slippage, the user not
     *   approving enough underlying tokens to the Vault contract, etc).
     *
     * NOTE: most implementations will require pre-approval of the Vault with the Vault’s underlying asset token.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of the Vault shares that can be minted for the receiver, through a mint call.
     * - MUST return a limited value if receiver is subject to some mint limit.
     * - MUST return 2 ** 256 - 1 if there is no limit on the maximum amount of shares that may be minted.
     * - MUST NOT revert.
     */
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, given
     * current on-chain conditions.
     *
     * - MUST return as close to and no fewer than the exact amount of assets that would be deposited in a mint call
     *   in the same transaction. I.e. mint should return the same or fewer assets as previewMint if called in the
     *   same transaction.
     * - MUST NOT account for mint limits like those returned from maxMint and should always act as though the mint
     *   would be accepted, regardless if the user has enough tokens approved, etc.
     * - MUST be inclusive of deposit fees. Integrators should be aware of the existence of deposit fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToAssets and previewMint SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by minting.
     */
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Mints exactly `shares` vault shares to `receiver` in exchange for `assets` underlying tokens.
     *
     * - MUST emit the Deposit event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the mint
     *   execution, and are accounted for during mint.
     * - MUST revert if all of shares cannot be minted (due to deposit limit being reached, slippage, the user not
     *   approving enough underlying tokens to the Vault contract, etc).
     *
     * NOTE: most implementations will require pre-approval of the Vault with the Vault’s underlying asset token.
     */
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, through a withdraw call.
     *
     * - MUST return a limited value if owner is subject to some withdrawal limit or timelock.
     * - MUST NOT revert.
     */
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     *
     * - MUST return as close to and no fewer than the exact amount of Vault shares that would be burned in a withdraw
     *   call in the same transaction. I.e. withdraw should return the same or fewer shares as previewWithdraw if
     *   called
     *   in the same transaction.
     * - MUST NOT account for withdrawal limits like those returned from maxWithdraw and should always act as though
     *   the withdrawal would be accepted, regardless if the user has enough shares, etc.
     * - MUST be inclusive of withdrawal fees. Integrators should be aware of the existence of withdrawal fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToShares and previewWithdraw SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by depositing.
     */
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Burns shares from owner and sends exactly assets of underlying tokens to receiver.
     *
     * - MUST emit the Withdraw event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   withdraw execution, and are accounted for during withdraw.
     * - MUST revert if all of assets cannot be withdrawn (due to withdrawal limit being reached, slippage, the owner
     *   not having enough shares, etc).
     *
     * Note that some implementations will require pre-requesting to the Vault before a withdrawal may be performed.
     * Those methods should be performed separately.
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of Vault shares that can be redeemed from the owner balance in the Vault,
     * through a redeem call.
     *
     * - MUST return a limited value if owner is subject to some withdrawal limit or timelock.
     * - MUST return balanceOf(owner) if owner is not subject to any withdrawal limit or timelock.
     * - MUST NOT revert.
     */
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their redemption at the current block,
     * given current on-chain conditions.
     *
     * - MUST return as close to and no more than the exact amount of assets that would be withdrawn in a redeem call
     *   in the same transaction. I.e. redeem should return the same or more assets as previewRedeem if called in the
     *   same transaction.
     * - MUST NOT account for redemption limits like those returned from maxRedeem and should always act as though the
     *   redemption would be accepted, regardless if the user has enough shares, etc.
     * - MUST be inclusive of withdrawal fees. Integrators should be aware of the existence of withdrawal fees.
     * - MUST NOT revert.
     *
     * NOTE: any unfavorable discrepancy between convertToAssets and previewRedeem SHOULD be considered slippage in
     * share price or some other type of condition, meaning the depositor will lose assets by redeeming.
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     *
     * - MUST emit the Withdraw event.
     * - MAY support an additional flow in which the underlying tokens are owned by the Vault contract before the
     *   redeem execution, and are accounted for during redeem.
     * - MUST revert if all of shares cannot be redeemed (due to withdrawal limit being reached, slippage, the owner
     *   not having enough shares, etc).
     *
     * NOTE: some implementations will require pre-requesting to the Vault before a withdrawal may be performed.
     * Those methods should be performed separately.
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

// lib/openzeppelin-contracts/contracts/access/AccessControl.sol

// OpenZeppelin Contracts (last updated v5.6.0) (access/AccessControl.sol)

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` from `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol

// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC1363.sol)

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_safeTransfer(token, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        if (!_safeTransferFrom(token, from, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _safeTransfer(token, to, value, false);
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _safeTransferFrom(token, from, to, value, false);
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (!_safeApprove(token, spender, value, false)) {
            if (!_safeApprove(token, spender, 0, true)) revert SafeERC20FailedOperation(address(token));
            if (!_safeApprove(token, spender, value, true)) revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Oppositely, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity `token.transfer(to, value)` call, relaxing the requirement on the return value: the
     * return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransfer(IERC20 token, address to, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.transfer.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(to, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }

    /**
     * @dev Imitates a Solidity `token.transferFrom(from, to, value)` call, relaxing the requirement on the return
     * value: the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param from The sender of the tokens
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value,
        bool bubble
    ) private returns (bool success) {
        bytes4 selector = IERC20.transferFrom.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(from, shr(96, not(0))))
            mstore(0x24, and(to, shr(96, not(0))))
            mstore(0x44, value)
            success := call(gas(), token, 0, 0x00, 0x64, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
            mstore(0x60, 0)
        }
    }

    /**
     * @dev Imitates a Solidity `token.approve(spender, value)` call, relaxing the requirement on the return value:
     * the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param spender The spender of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeApprove(IERC20 token, address spender, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.approve.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(spender, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }
}

// src/partners/PartnerAttributedSplitter.sol

/// @title PartnerAttributedSplitter - direct-read, min-capped, registry-driven
///        fee router with per-wrapper canonical settlement and bounded
///        partner-level counters.
/// @notice Per Task 1.37e (Option F v5):
///         - reads `registry.activeWrapperList()` (bounded ≤ MAX_ACTIVE_WRAPPERS)
///           on every `recordFee`,
///         - caps per-wrapper effective shares at
///           `min(vault.balanceOf(W), IPartnerWrapper(W).totalReceipts())` —
///           donations cannot inflate partner accrual,
///         - `claimWrapper(W)` is the SOLE on-chain partner-side settlement
///           primitive (no `claimPartner(...)`),
///         - exposes O(1) bounded counters `pendingPerPartner`,
///           `cumulativeAccruedPerPartner`, `cumulativeClaimedPerPartner`
///           maintained incrementally inside `recordFee` / `claimWrapper` —
///           no on-chain iteration over `registry.wrappersOfPartner`.
contract PartnerAttributedSplitter is AccessControl, ReentrancyGuard, IPartnerAttribution {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Hard cap on partner share. Matches the live FeeSplitter's
    /// `MAX_PARTNER_SHARE_BPS`; sanity ceiling, not a policy choice.
    uint256 public constant MAX_PARTNER_SHARE_BPS = 5_000;

    IERC20  public immutable asset;
    address public immutable override registry;
    address public immutable override vault;

    address public override projectTreasury;
    uint256 public override partnerShareBps;

    // ── per-wrapper pending pool (canonical settlement unit) ──
    mapping(address => uint256) public override pendingForWrapper;

    // ── O(1) bounded partner-level counters ──
    mapping(bytes32 => uint256) public override pendingPerPartner;
    mapping(bytes32 => uint256) public override cumulativeAccruedPerPartner;
    mapping(bytes32 => uint256) public override cumulativeClaimedPerPartner;

    // ── per-wrapper cumulative claimed ──
    mapping(address => uint256) public override cumulativeClaimedPerWrapper;

    // ── project-side pending ──
    uint256 public override pendingProjectBaseSlice;
    uint256 public override pendingProjectHouseSlice;

    // ── lifetime totals ──
    uint256 public override cumulativeReceived;
    uint256 public override cumulativeProject;

    /// @dev O(1) counter: sum of all pending pools (per-wrapper + project).
    /// Maintained `+= amount` in recordFee, `-= paid` in claim*. Used by
    /// `unrecordedBalance()` to detect raw transfers / misroutes.
    uint256 private _totalPending;

    constructor(
        address registry_,
        address projectTreasury_,
        uint256 partnerShareBps_,
        address admin_
    ) {
        if (registry_ == address(0) || projectTreasury_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        if (partnerShareBps_ > MAX_PARTNER_SHARE_BPS) revert InvalidBps();

        registry = registry_;
        vault    = IPartnerRegistry(registry_).vault();
        asset    = IERC20(IERC4626(vault).asset());

        projectTreasury = projectTreasury_;
        partnerShareBps = partnerShareBps_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ──────────────────────────────────────────────────────────────────
    // IFeeSink.recordFee
    // ──────────────────────────────────────────────────────────────────

    function recordFee(uint256 amount) external override nonReentrant {
        if (amount == 0) return;

        // CEI: pull asset first.
        asset.safeTransferFrom(msg.sender, address(this), amount);
        _totalPending += amount;
        cumulativeReceived += amount;

        // Lock bps + supply at receipt time. Task 1.32 carry-forward:
        // a later `setPartnerShareBps` does NOT retroactively reprice.
        uint256 bpsLocked = partnerShareBps;
        uint256 totalSupply_ = IERC20(vault).totalSupply();
        uint256 partnerCut = (amount * bpsLocked) / 10_000;
        uint256 baseSlice  = amount - partnerCut;

        if (totalSupply_ == 0 || partnerCut == 0) {
            pendingProjectBaseSlice  += baseSlice;
            pendingProjectHouseSlice += partnerCut;
            emit FeeRouted(amount, baseSlice, partnerCut, 0, totalSupply_, bpsLocked);
            return;
        }

        address[] memory wrappers = IPartnerRegistry(registry).activeWrapperList();
        uint256 distributedToWrappers = 0;
        uint256 n = wrappers.length;
        for (uint256 i = 0; i < n; ++i) {
            address W = wrappers[i];
            uint256 vBal     = IERC20(vault).balanceOf(W);
            uint256 receipts = IPartnerWrapper(W).totalReceipts();
            uint256 effective = vBal < receipts ? vBal : receipts;
            if (effective == 0) continue;

            uint256 wSlice = (partnerCut * effective) / totalSupply_;
            if (wSlice == 0) continue;

            bytes32 pid = IPartnerRegistry(registry).partnerOfWrapper(W);
            pendingForWrapper[W]             += wSlice;
            pendingPerPartner[pid]           += wSlice;
            cumulativeAccruedPerPartner[pid] += wSlice;
            distributedToWrappers            += wSlice;

            emit WrapperPendingAccrued(W, wSlice);
        }

        uint256 houseSlice = partnerCut - distributedToWrappers;
        pendingProjectHouseSlice += houseSlice;
        pendingProjectBaseSlice  += baseSlice;

        emit FeeRouted(amount, baseSlice, houseSlice, distributedToWrappers, totalSupply_, bpsLocked);
    }

    // ──────────────────────────────────────────────────────────────────
    // settlement (permissionless)
    // ──────────────────────────────────────────────────────────────────

    function claimWrapper(address wrapper)
        external
        override
        nonReentrant
        returns (uint256 paid)
    {
        paid = pendingForWrapper[wrapper];
        if (paid == 0) return 0;

        bytes32 pid = IPartnerRegistry(registry).partnerOfWrapper(wrapper);
        if (pid == bytes32(0)) revert WrapperNotRegistered();
        address payout = IPartnerRegistry(registry).payoutTreasury(pid);
        if (payout == address(0)) revert PartnerNotRegistered();

        pendingForWrapper[wrapper]       = 0;
        pendingPerPartner[pid]          -= paid;
        cumulativeClaimedPerWrapper[wrapper] += paid;
        cumulativeClaimedPerPartner[pid]     += paid;
        _totalPending -= paid;

        asset.safeTransfer(payout, paid);
        emit WrapperClaimed(pid, wrapper, payout, paid);
    }

    function claimProject() external override nonReentrant returns (uint256 paid) {
        uint256 base  = pendingProjectBaseSlice;
        uint256 house = pendingProjectHouseSlice;
        paid = base + house;
        if (paid == 0) return 0;

        pendingProjectBaseSlice  = 0;
        pendingProjectHouseSlice = 0;
        _totalPending -= paid;
        cumulativeProject += paid;

        asset.safeTransfer(projectTreasury, paid);
        emit ProjectClaimed(projectTreasury, paid);
    }

    // ──────────────────────────────────────────────────────────────────
    // views
    // ──────────────────────────────────────────────────────────────────

    function previewWrapperSlice(uint256 amount, address wrapper)
        external
        view
        override
        returns (uint256 wrapperSlice)
    {
        uint256 totalSupply_ = IERC20(vault).totalSupply();
        if (totalSupply_ == 0) return 0;
        uint256 partnerCut = (amount * partnerShareBps) / 10_000;
        if (partnerCut == 0) return 0;
        uint256 vBal     = IERC20(vault).balanceOf(wrapper);
        uint256 receipts = IPartnerWrapper(wrapper).totalReceipts();
        uint256 effective = vBal < receipts ? vBal : receipts;
        wrapperSlice = (partnerCut * effective) / totalSupply_;
    }

    function unrecordedBalance() public view override returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > _totalPending ? bal - _totalPending : 0;
    }

    // ──────────────────────────────────────────────────────────────────
    // admin-only (Safe)
    // ──────────────────────────────────────────────────────────────────

    function setPartnerShareBps(uint256 newBps) external override onlyRole(ADMIN_ROLE) {
        if (newBps > MAX_PARTNER_SHARE_BPS) revert InvalidBps();
        emit PartnerShareBpsUpdated(partnerShareBps, newBps);
        partnerShareBps = newBps;
    }

    function setProjectTreasury(address newTreasury) external override onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = projectTreasury;
        projectTreasury = newTreasury;
        emit ProjectTreasuryUpdated(old, newTreasury);
    }

    function recoverUnrecorded()
        external
        override
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 recovered)
    {
        recovered = unrecordedBalance();
        if (recovered == 0) return 0;
        asset.safeTransfer(projectTreasury, recovered);
        emit UnrecordedRecovered(recovered);
    }
}
