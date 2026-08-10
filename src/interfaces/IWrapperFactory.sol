// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
