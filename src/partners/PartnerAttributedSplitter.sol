// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPartnerAttribution} from "../interfaces/IPartnerAttribution.sol";
import {IPartnerRegistry} from "../interfaces/IPartnerRegistry.sol";
import {IPartnerWrapper} from "../interfaces/IPartnerWrapper.sol";

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

    // ── F-3: anti-JIT weight checkpoint ──
    /// @dev `wrapperWeightCheckpoint[W]` is the `effective` value observed at the
    /// PREVIOUS `recordFee` for a wrapper that has been seen before
    /// (`wrapperCheckpointed[W]`). Accrual is then weighted by
    /// `min(current, checkpoint)`, so a JIT top-up made right before a fee cannot
    /// capture a slice earned by capital that was already there — the top-up only
    /// counts from the NEXT fee, once it has survived one observation. The FIRST
    /// observation credits the full `effective` (that capital was genuinely
    /// present and earned the yield being distributed, e.g. a wrapper whose only
    /// fee event is its own user's exit). Onboarding is admin-gated
    /// (`WrapperFactory.deployFirstWrapper` is `onlyRole(ADMIN_ROLE)`), so a
    /// wrapper cannot be spun up on demand to farm that first-observation credit.
    mapping(address => uint256) public wrapperWeightCheckpoint;
    mapping(address => bool)    public wrapperCheckpointed;

    // ── F-6: timelocked project-treasury change ──
    /// @dev A change of the project treasury is proposed, then applied after
    /// TREASURY_TIMELOCK, so the current treasury can sweep already-accrued
    /// project funds (claimProject) before the destination moves. The initial
    /// treasury is still set instantly in the constructor (bootstrap).
    uint256 public constant TREASURY_TIMELOCK = 2 days;
    address public pendingProjectTreasury;
    uint64  public pendingProjectTreasuryReadyAt;

    // ── local events/errors (splitter-specific, not part of IPartnerAttribution) ──
    event WrapperSkipped(address indexed wrapper);
    event ProjectTreasuryProposed(address indexed newTreasury, uint64 readyAt);

    error NoPendingTreasury();
    error TreasuryTimelockNotElapsed(uint64 readyAt);

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

        // CEI: pull asset first. F-4: credit the MEASURED delta of our own
        // balance, not the requested `amount`. For a strict ERC-20 they are
        // equal, but the assumption was never checked — and a token that
        // delivers less (fee-on-transfer / non-standard) would otherwise inflate
        // `_totalPending` above the real balance and strand later claims. Same
        // approach as B4-T3 harvest.
        uint256 balBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - balBefore;
        if (received == 0) return;

        _totalPending += received;
        cumulativeReceived += received;

        // Lock bps + supply at receipt time. Task 1.32 carry-forward:
        // a later `setPartnerShareBps` does NOT retroactively reprice.
        uint256 bpsLocked = partnerShareBps;
        uint256 totalSupply_ = IERC20(vault).totalSupply();
        uint256 partnerCut = (received * bpsLocked) / 10_000;
        uint256 baseSlice  = received - partnerCut;

        if (totalSupply_ == 0 || partnerCut == 0) {
            pendingProjectBaseSlice  += baseSlice;
            pendingProjectHouseSlice += partnerCut;
            emit FeeRouted(received, baseSlice, partnerCut, 0, totalSupply_, bpsLocked);
            return;
        }

        address[] memory wrappers = IPartnerRegistry(registry).activeWrapperList();
        uint256 distributedToWrappers = 0;
        uint256 n = wrappers.length;
        for (uint256 i = 0; i < n; ++i) {
            address W = wrappers[i];
            uint256 vBal = IERC20(vault).balanceOf(W); // vault is the trusted ERC4626

            // F-1: `totalReceipts()` is partner code. A revert (broken or
            // hostile wrapper) must skip THIS wrapper, not brick the whole
            // distribution. The skipped wrapper's slice is never assigned, so it
            // falls into the project house residual below — it is NOT
            // redistributed to the other wrappers (each wSlice is computed from
            // that wrapper's OWN weight, independent of how many are skipped), so
            // no one can profit by breaking a neighbour.
            uint256 receipts;
            try IPartnerWrapper(W).totalReceipts() returns (uint256 r) {
                receipts = r;
            } catch {
                emit WrapperSkipped(W);
                continue;
            }
            uint256 effective = vBal < receipts ? vBal : receipts;

            // F-3: weight by min(current, checkpoint) once the wrapper has been
            // seen, so a JIT top-up made right before this fee earns nothing
            // until it has survived one observation. The first observation
            // credits the full `effective` — that capital was already present
            // and earned the yield being distributed (a wrapper whose sole fee
            // event is its own user's exit must still accrue). Refresh the
            // checkpoint to `effective` for next time either way.
            uint256 weight;
            if (wrapperCheckpointed[W]) {
                uint256 prev = wrapperWeightCheckpoint[W];
                weight = effective < prev ? effective : prev;
            } else {
                weight = effective;
                wrapperCheckpointed[W] = true;
            }
            wrapperWeightCheckpoint[W] = effective;
            if (weight == 0) continue;

            uint256 wSlice = (partnerCut * weight) / totalSupply_;
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

        emit FeeRouted(received, baseSlice, houseSlice, distributedToWrappers, totalSupply_, bpsLocked);
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
        // Mirror recordFee's F-3 anti-JIT weighting so the preview matches what
        // would actually accrue: full on first observation, else min(current,
        // checkpoint).
        uint256 weight = effective;
        if (wrapperCheckpointed[wrapper]) {
            uint256 prev = wrapperWeightCheckpoint[wrapper];
            weight = effective < prev ? effective : prev;
        }
        wrapperSlice = (partnerCut * weight) / totalSupply_;
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

    /// @notice F-6: propose a project-treasury change. It does NOT take effect
    /// immediately — `applyProjectTreasury` commits it after TREASURY_TIMELOCK,
    /// giving the current treasury time to `claimProject` what is already
    /// accrued before the destination moves. Re-proposing overwrites the
    /// pending target and restarts the clock.
    function setProjectTreasury(address newTreasury) external override onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        pendingProjectTreasury = newTreasury;
        pendingProjectTreasuryReadyAt = uint64(block.timestamp + TREASURY_TIMELOCK);
        emit ProjectTreasuryProposed(newTreasury, pendingProjectTreasuryReadyAt);
    }

    /// @notice F-6: commit a previously proposed project-treasury change once
    /// the timelock has elapsed.
    function applyProjectTreasury() external onlyRole(ADMIN_ROLE) {
        address next = pendingProjectTreasury;
        if (next == address(0)) revert NoPendingTreasury();
        uint64 readyAt = pendingProjectTreasuryReadyAt;
        if (block.timestamp < readyAt) revert TreasuryTimelockNotElapsed(readyAt);
        address old = projectTreasury;
        projectTreasury = next;
        pendingProjectTreasury = address(0);
        pendingProjectTreasuryReadyAt = 0;
        emit ProjectTreasuryUpdated(old, next);
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
