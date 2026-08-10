// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFeeSink} from "./IFeeSink.sol";

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
