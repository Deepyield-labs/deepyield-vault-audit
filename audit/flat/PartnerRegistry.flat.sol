// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16 >=0.8.4 ^0.8.20;

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

// src/interfaces/IWrapperFactory.sol

/// @title IWrapperFactory (Task 1.37d / 1.37e / 1.38 — generational wrapper deployment)
/// @notice Production surface implemented by
///         `src/partners/WrapperFactory.sol` per
///         `docs/partners/multi-partner-attribution-design.md`
///         (revision 6, Option F v5). Carries forward from 1.37d without
///         surface changes: v6 does not modify the factory ABI — its
///         fixes (bounded partner accounting + active-wrapper cap) live
///         in the registry + splitter only. The factory still routes
///         registration through `registry.registerPartner` /
///         `addReplacementWrapper`, both of which revert
///         `ActiveWrapperListFull` at `MAX_ACTIVE_WRAPPERS = 128`. The
///         contract is in-repo and unit-tested; the factory has NOT yet
///         been deployed live (no live tx). Cut-over is deferred to the
///         deploy task per the design doc's rollout plan.
///
/// @dev The factory is the ONLY supported entry point to deploy and
///      register partner wrappers. The registry restricts
///      `registerPartner(...)` and `addReplacementWrapper(...)` to
///      `msg.sender == registry.factory()`, so the factory has a hard
///      monopoly on wrapper onboarding.
///
///      Two factory entry points reflect the two cases explicitly:
///        - `deployFirstWrapper(partnerId, payoutTreasury)`:
///            For a partnerId that has no wrapper yet. Reverts via the
///            registry if the partner is already registered.
///        - `deployReplacementWrapper(partnerId)`:
///            For a partnerId that already has a current wrapper.
///            Atomically pauses the old current wrapper, deploys a new
///            wrapper, and sets it as the new current. Reverts via the
///            registry if the partner has no existing wrapper.
///
///      Splitting onboarding into two functions (vs Task 1.37c's single
///      `deployAndRegister`) makes the intent explicit at the type
///      level and matches the §4 generational wrapper model.
///
///      `payoutTreasury` is set only at first-wrapper creation. To
///      rotate it later, admin calls `registry.updatePartnerTreasury(...)` —
///      no new wrapper required.
interface IWrapperFactory {
    // ── events ──

    event FirstWrapperDeployed(
        bytes32 indexed partnerId,
        address indexed wrapper,
        address indexed payoutTreasury
    );

    event ReplacementWrapperDeployed(
        bytes32 indexed partnerId,
        address indexed oldCurrent,
        address indexed newCurrent
    );

    // ── errors ──

    error ZeroPartnerId();
    error ZeroAddress();

    // ── views ──

    function registry() external view returns (address);
    function vault()    external view returns (address);
    function asset()    external view returns (address);

    // ── admin-only (Safe) ──

    /// @notice Deploys the FIRST wrapper for `partnerId` and atomically
    /// registers it as the partner's current wrapper. Reverts via the
    /// registry's `PartnerAlreadyRegistered` if the partner already has
    /// a current wrapper — use `deployReplacementWrapper` for that case.
    function deployFirstWrapper(bytes32 partnerId, address payoutTreasury)
        external
        returns (address wrapper);

    /// @notice Deploys a REPLACEMENT wrapper for an existing
    /// `partnerId`. Atomically:
    ///   - deploys a fresh PartnerWrapper with the same partnerId baked in,
    ///   - calls `registry.addReplacementWrapper(partnerId, newWrapper)`,
    ///     which pauses the old current wrapper (sets isWrapperDepositsPaused
    ///     = true) and sets the new wrapper as the current target.
    /// The old current wrapper stays in `activeWrapperList()` and continues
    /// accruing protocol-fee share on whatever vault shares it still
    /// holds. Once drained, admin may call `registry.retireWrapper(...)`
    /// to swap-and-pop the legacy wrapper out of `activeWrapperList()`
    /// (it remains in `wrappersOfPartner()` for historical reporting).
    ///
    /// Reverts via the registry's `PartnerNotRegistered` if `partnerId`
    /// has no existing wrapper — use `deployFirstWrapper` for that case.
    /// Reverts via the registry's `ActiveWrapperListFull` if the active
    /// set has reached `MAX_ACTIVE_WRAPPERS`.
    function deployReplacementWrapper(bytes32 partnerId)
        external
        returns (address newWrapper);
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

// src/partners/PartnerRegistry.sol

/// @title PartnerRegistry - single source of truth for the multi-partner
///        wrapper graph.
/// @notice Per Task 1.37e (Option F v5) design. Two structurally distinct
///         sets:
///           1. `activeWrapperList` (bounded, len <= `MAX_ACTIVE_WRAPPERS`):
///              the iteration target for `PartnerAttributedSplitter.recordFee`.
///              Active + PausedDeposits wrappers only; Retired removed.
///           2. `wrappersOfPartner` (append-only history per partner):
///              never iterated on-chain by accrual or settlement.
///
///         Onboarding is factory-only. The factory address is bound via
///         a one-shot `setFactory(...)` admin call: the registry is
///         deployed first, the factory is deployed pointing at it, and
///         the admin then calls `setFactory(factoryAddr)` exactly once.
///         A second invocation reverts `FactoryAlreadySet`, and the
///         candidate is cross-validated end-to-end (code-present,
///         `IWrapperFactory.registry() == address(this)`,
///         `IWrapperFactory.vault() == vault`) so a typo cannot brick
///         onboarding. After the one-shot binding, `factory()` is
///         effectively immutable.
contract PartnerRegistry is AccessControl, IPartnerRegistry {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Sized per design doc §4.B — ~4x the steady-state footprint of
    ///      ~30 partners, providing structural buffer for triple-generation
    ///      pile-up + new-partner onboarding + emergency parallel wrappers,
    ///      with explicit gas-budget check at the cap.
    uint256 public constant override MAX_ACTIVE_WRAPPERS = 128;

    /// @notice The vault the registry's wrappers wrap. Used only by
    ///         `retireWrapper(...)` to enforce the drained precondition.
    address public immutable override vault;

    /// @notice Atomic-onboarding entry point. Set ONCE via `setFactory`
    ///         immediately after construction (registry + factory have a
    ///         mutual constructor dependency that we resolve with a
    ///         one-shot setter). After the first set, further calls
    ///         revert `FactoryAlreadySet`.
    address public override factory;

    // ── per-partner state ──

    mapping(bytes32 => address) public override currentWrapperOf;
    mapping(bytes32 => address) public override payoutTreasury;
    mapping(bytes32 => address[]) private _wrappersOfPartner;

    // ── per-wrapper state ──

    mapping(address => bytes32) public override partnerOfWrapper;
    mapping(address => bool) public override isRegisteredWrapper;
    mapping(address => bool) public override isWrapperDepositsPaused;
    mapping(address => bool) public override isRetiredWrapper;

    // ── active iterable set ──

    address[] private _activeWrapperList;
    /// @dev `_activeIndexPlusOne[W] = i+1` ⇒ W is at index `i` in
    ///      `_activeWrapperList`. 0 means "not in the list" (used by retire's
    ///      swap-and-pop).
    mapping(address => uint256) private _activeIndexPlusOne;

    constructor(address vault_, address admin_) {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @notice One-shot factory setter. Admin must call this exactly once
    /// after deploying the `WrapperFactory`. After the first call, further
    /// invocations revert `FactoryAlreadySet`. From the perspective of
    /// every callsite that reads `factory()`, the value is immutable once
    /// the system is fully wired.
    ///
    /// Hardening (Task 1.38a): rather than accept any non-zero address,
    /// the candidate is cross-validated end-to-end so a typo or wrong
    /// contract address cannot brick onboarding:
    ///   - candidate must be a deployed contract (`code.length > 0`)
    ///   - `IWrapperFactory(factory_).registry() == address(this)` — the
    ///     candidate must point back at THIS registry
    ///   - `IWrapperFactory(factory_).vault() == vault` — the candidate
    ///     must be wired to the same vault this registry guards
    /// On any failure, reverts `InvalidFactory()`.
    function setFactory(address factory_) external override onlyRole(ADMIN_ROLE) {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_.code.length == 0) revert InvalidFactory();

        // Defensive try/catch so a non-conforming contract reverts with
        // our typed error rather than bubbling up an opaque revert.
        try IWrapperFactory(factory_).registry() returns (address r) {
            if (r != address(this)) revert InvalidFactory();
        } catch {
            revert InvalidFactory();
        }
        try IWrapperFactory(factory_).vault() returns (address v) {
            if (v != vault) revert InvalidFactory();
        } catch {
            revert InvalidFactory();
        }

        factory = factory_;
    }

    // ──────────────────────────────────────────────────────────────────
    // views
    // ──────────────────────────────────────────────────────────────────

    function wrappersOfPartner(bytes32 partnerId)
        external
        view
        override
        returns (address[] memory)
    {
        return _wrappersOfPartner[partnerId];
    }

    function activeWrapperList() external view override returns (address[] memory) {
        return _activeWrapperList;
    }

    function activeWrapperCount() external view override returns (uint256) {
        return _activeWrapperList.length;
    }

    function activeWrapperAt(uint256 index) external view override returns (address) {
        return _activeWrapperList[index];
    }

    function canAcceptDeposits(address wrapper) external view override returns (bool) {
        return
            isRegisteredWrapper[wrapper] &&
            !isWrapperDepositsPaused[wrapper] &&
            !isRetiredWrapper[wrapper];
    }

    // ──────────────────────────────────────────────────────────────────
    // factory-only entry points
    // ──────────────────────────────────────────────────────────────────

    modifier onlyFactory() {
        if (msg.sender != factory) revert CallerNotFactory();
        _;
    }

    function registerPartner(
        bytes32 partnerId,
        address wrapper,
        address payoutTreasury_
    ) external override onlyFactory {
        if (partnerId == bytes32(0)) revert ZeroPartnerId();
        if (wrapper == address(0) || payoutTreasury_ == address(0)) revert ZeroAddress();
        if (currentWrapperOf[partnerId] != address(0)) revert PartnerAlreadyRegistered();
        if (partnerOfWrapper[wrapper] != bytes32(0) || isRegisteredWrapper[wrapper]) {
            revert WrapperAlreadyRegistered();
        }
        if (_activeWrapperList.length == MAX_ACTIVE_WRAPPERS) revert ActiveWrapperListFull();

        partnerOfWrapper[wrapper] = partnerId;
        currentWrapperOf[partnerId] = wrapper;
        _wrappersOfPartner[partnerId].push(wrapper);
        payoutTreasury[partnerId] = payoutTreasury_;
        isRegisteredWrapper[wrapper] = true;
        // isWrapperDepositsPaused[wrapper] = false (default)
        // isRetiredWrapper[wrapper] = false (default)

        _appendActive(wrapper);

        emit PartnerRegistered(partnerId, wrapper, payoutTreasury_);
    }

    function addReplacementWrapper(bytes32 partnerId, address newWrapper)
        external
        override
        onlyFactory
    {
        if (partnerId == bytes32(0)) revert ZeroPartnerId();
        if (newWrapper == address(0)) revert ZeroAddress();
        address oldCurrent = currentWrapperOf[partnerId];
        if (oldCurrent == address(0)) revert PartnerNotRegistered();
        if (partnerOfWrapper[newWrapper] != bytes32(0) || isRegisteredWrapper[newWrapper]) {
            revert WrapperAlreadyRegistered();
        }
        if (_activeWrapperList.length == MAX_ACTIVE_WRAPPERS) revert ActiveWrapperListFull();

        // Pause old current.
        isWrapperDepositsPaused[oldCurrent] = true;
        emit WrapperDepositsPaused(partnerId, oldCurrent);

        // Promote new wrapper.
        partnerOfWrapper[newWrapper] = partnerId;
        currentWrapperOf[partnerId] = newWrapper;
        _wrappersOfPartner[partnerId].push(newWrapper);
        isRegisteredWrapper[newWrapper] = true;

        _appendActive(newWrapper);

        emit WrapperReplaced(partnerId, oldCurrent, newWrapper);
    }

    // ──────────────────────────────────────────────────────────────────
    // admin-only
    // ──────────────────────────────────────────────────────────────────

    function updatePartnerTreasury(bytes32 partnerId, address newTreasury)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (currentWrapperOf[partnerId] == address(0)) revert PartnerNotRegistered();
        address old = payoutTreasury[partnerId];
        payoutTreasury[partnerId] = newTreasury;
        emit PartnerTreasuryUpdated(partnerId, old, newTreasury);
    }

    function pauseDepositsForWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        if (isWrapperDepositsPaused[wrapper]) return;
        isWrapperDepositsPaused[wrapper] = true;
        emit WrapperDepositsPaused(partnerOfWrapper[wrapper], wrapper);
    }

    function unpauseDepositsForWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        // Only the CURRENT wrapper of its partner may be unpaused. This
        // structurally prevents two simultaneous deposit-active wrappers
        // for the same partner.
        bytes32 pid = partnerOfWrapper[wrapper];
        if (currentWrapperOf[pid] != wrapper) revert CannotUnpauseLegacy();
        if (!isWrapperDepositsPaused[wrapper]) return;
        isWrapperDepositsPaused[wrapper] = false;
        emit WrapperDepositsUnpaused(pid, wrapper);
    }

    function retireWrapper(address wrapper) external override onlyRole(ADMIN_ROLE) {
        if (!isRegisteredWrapper[wrapper]) revert WrapperNotRegistered();
        if (isRetiredWrapper[wrapper]) revert WrapperRetiredAlready();
        bytes32 pid = partnerOfWrapper[wrapper];
        if (currentWrapperOf[pid] == wrapper) revert CannotRetireCurrent();
        if (IERC20(vault).balanceOf(wrapper) != 0) revert WrapperHasShares();

        isRetiredWrapper[wrapper] = true;
        _removeActive(wrapper);

        emit WrapperRetired(pid, wrapper);
    }

    // ──────────────────────────────────────────────────────────────────
    // internal: active-set bookkeeping
    // ──────────────────────────────────────────────────────────────────

    function _appendActive(address wrapper) internal {
        _activeWrapperList.push(wrapper);
        _activeIndexPlusOne[wrapper] = _activeWrapperList.length; // i+1
    }

    function _removeActive(address wrapper) internal {
        uint256 ip1 = _activeIndexPlusOne[wrapper];
        if (ip1 == 0) return;
        uint256 i = ip1 - 1;
        uint256 lastIdx = _activeWrapperList.length - 1;
        if (i != lastIdx) {
            address last = _activeWrapperList[lastIdx];
            _activeWrapperList[i] = last;
            _activeIndexPlusOne[last] = i + 1;
        }
        _activeWrapperList.pop();
        delete _activeIndexPlusOne[wrapper];
    }
}
