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
