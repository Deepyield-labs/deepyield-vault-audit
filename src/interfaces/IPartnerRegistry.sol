// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
