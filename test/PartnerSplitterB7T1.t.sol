// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";

/// @notice B7-T1 — splitter failure isolation (F-1), anti-JIT weighting (F-3),
/// measured-delta crediting (F-4) and timelocked treasury change (F-6).
///
/// Self-contained harness: a mintable asset, a minimal ERC4626-shaped vault
/// (only asset()/totalSupply()/balanceOf are read by the splitter), a minimal
/// registry (only vault()/activeWrapperList()/partnerOfWrapper()/payoutTreasury()
/// are read), and mock wrappers that expose totalReceipts() with a revert toggle.

contract Asset is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Delivers `amount - fee` on transferFrom (fee-on-transfer / non-standard).
contract FeeOnTransferAsset is ERC20 {
    uint256 public feeBps;
    constructor(uint256 feeBps_) ERC20("Fee USD", "fUSD") { feeBps = feeBps_; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 cut = amount * feeBps / 10_000;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - cut);
        _burn(from, cut); // the cut leaves the system, so recipient gets less
        return true;
    }
}

contract MockVault {
    address public asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    constructor(address a) { asset = a; }
    /// @dev set a holder's share balance and keep totalSupply consistent.
    function setBalance(address who, uint256 b) external {
        totalSupply = totalSupply - balanceOf[who] + b;
        balanceOf[who] = b;
    }
}

contract MockWrapper {
    uint256 private _receipts;
    bool public boom;
    function setReceipts(uint256 v) external { _receipts = v; }
    function setBoom(bool b) external { boom = b; }
    function totalReceipts() external view returns (uint256) {
        require(!boom, "wrapper boom");
        return _receipts;
    }
}

contract MockRegistry {
    address public vault;
    address[] private _active;
    mapping(address => bytes32) public partnerOfWrapper;
    mapping(bytes32 => address) public payoutTreasury;
    constructor(address vault_) { vault = vault_; }
    function setActive(address[] calldata a) external { _active = a; }
    function activeWrapperList() external view returns (address[] memory) { return _active; }
    function register(address w, bytes32 pid, address payout) external {
        partnerOfWrapper[w] = pid;
        payoutTreasury[pid] = payout;
    }
}

contract PartnerSplitterB7T1Test is Test {
    Asset internal asset;
    MockVault internal vault;
    MockRegistry internal registry;
    PartnerAttributedSplitter internal splitter;

    address internal admin = makeAddr("admin");
    address internal project = makeAddr("project");
    address internal feePayer = makeAddr("feePayer");

    uint256 internal constant BPS = 5_000; // 50% partner share

    function setUp() public {
        asset = new Asset();
        vault = new MockVault(address(asset));
        registry = new MockRegistry(address(vault));
        splitter = new PartnerAttributedSplitter(address(registry), project, BPS, admin);
    }

    // ── harness helpers ──────────────────────────────────────────────────────

    function _wrapper(bytes32 pid, address payout, uint256 shares) internal returns (address w) {
        MockWrapper mw = new MockWrapper();
        mw.setReceipts(shares);
        w = address(mw);
        vault.setBalance(w, shares);          // 1:1 receipts == vault shares (honest wrapper)
        registry.register(w, pid, payout);
    }

    function _setActive(address[] memory ws) internal {
        registry.setActive(ws);
    }

    function _recordFee(uint256 amount) internal {
        asset.mint(feePayer, amount);
        vm.startPrank(feePayer);
        asset.approve(address(splitter), amount);
        splitter.recordFee(amount);
        vm.stopPrank();
    }

    // ── F-1: a reverting wrapper is skipped, not a whole-distribution revert ───
    function test_RevertingWrapperIsSkippedAndOthersPaid() public {
        address wA = _wrapper("A", makeAddr("pA"), 100e18);
        address wB = _wrapper("B", makeAddr("pB"), 100e18);
        vault.setBalance(makeAddr("direct"), 100e18); // 1/3 direct supply
        address[] memory ws = new address[](2);
        ws[0] = wA; ws[1] = wB;
        _setActive(ws);

        // warm both wrappers past their first observation
        _recordFee(30e18);

        MockWrapper(wB).setBoom(true); // wB.totalReceipts() now reverts

        uint256 aBefore = splitter.pendingForWrapper(wA);
        uint256 bBefore = splitter.pendingForWrapper(wB);

        // Do the token plumbing first so expectEmit sits right before recordFee.
        asset.mint(feePayer, 30e18);
        vm.prank(feePayer);
        asset.approve(address(splitter), 30e18);

        vm.expectEmit(true, false, false, false, address(splitter));
        emit PartnerAttributedSplitter.WrapperSkipped(wB);
        vm.prank(feePayer);
        splitter.recordFee(30e18); // must NOT revert

        assertGt(splitter.pendingForWrapper(wA), aBefore, "healthy wrapper still accrues");
        assertEq(splitter.pendingForWrapper(wB), bBefore, "skipped wrapper unchanged");
    }

    // ── F-1 (reviewer's key #2): skipping one does not inflate the others ──────
    function test_SkippingOneDoesNotInflateOthers() public {
        address wA = _wrapper("A", makeAddr("pA"), 100e18);
        address wB = _wrapper("B", makeAddr("pB"), 100e18);
        address wC = _wrapper("C", makeAddr("pC"), 100e18);
        address[] memory ws = new address[](3);
        ws[0] = wA; ws[1] = wB; ws[2] = wC;
        _setActive(ws);
        _recordFee(40e18); // warm all three

        // Baseline: a healthy fee, note A/B increments.
        uint256 a0 = splitter.pendingForWrapper(wA);
        uint256 b0 = splitter.pendingForWrapper(wB);
        _recordFee(40e18);
        uint256 aHealthyDelta = splitter.pendingForWrapper(wA) - a0;
        uint256 bHealthyDelta = splitter.pendingForWrapper(wB) - b0;

        // Now break wC and record the SAME fee.
        MockWrapper(wC).setBoom(true);
        uint256 a1 = splitter.pendingForWrapper(wA);
        uint256 b1 = splitter.pendingForWrapper(wB);
        _recordFee(40e18);
        uint256 aSkipDelta = splitter.pendingForWrapper(wA) - a1;
        uint256 bSkipDelta = splitter.pendingForWrapper(wB) - b1;

        // A and B get EXACTLY their own share whether or not C is skipped —
        // C's slice falls to the house, never to A/B.
        assertEq(aSkipDelta, aHealthyDelta, "A not inflated by C being skipped");
        assertEq(bSkipDelta, bHealthyDelta, "B not inflated by C being skipped");
    }

    // ── F-3: a JIT deposit right before recordFee cannot divert accrual ────────
    function test_JitDepositDoesNotDivertAccrual() public {
        address wA = _wrapper("A", makeAddr("pA"), 100e18);
        address wJ = _wrapper("J", makeAddr("pJ"), 100e18);
        vault.setBalance(makeAddr("direct"), 100e18);
        address[] memory ws = new address[](2);
        ws[0] = wA; ws[1] = wJ;
        _setActive(ws);
        _recordFee(20e18); // warm: both checkpointed at 100e18

        uint256 aBefore = splitter.pendingForWrapper(wA);
        uint256 jBefore = splitter.pendingForWrapper(wJ);

        // Attacker sees the fee in the mempool and doubles wJ's stake right before.
        MockWrapper(wJ).setReceipts(200e18);
        vault.setBalance(wJ, 200e18);

        _recordFee(20e18);

        uint256 aDelta = splitter.pendingForWrapper(wA) - aBefore;
        uint256 jDelta = splitter.pendingForWrapper(wJ) - jBefore;

        // wJ is weighted by min(200, checkpoint 100) = 100, the same as wA, even
        // though wJ momentarily held twice as much. The JIT capital earns nothing
        // this fee.
        assertEq(jDelta, aDelta, "JIT stake earns no more than the un-JIT'd peer");
    }

    // ── F-4: credit the measured delta, not the requested amount ───────────────
    function test_CreditsMeasuredDeltaNotRequestedAmount() public {
        // fee-on-transfer asset: 10% is skimmed on transferFrom.
        FeeOnTransferAsset fot = new FeeOnTransferAsset(1_000);
        MockVault v2 = new MockVault(address(fot));
        MockRegistry r2 = new MockRegistry(address(v2));
        PartnerAttributedSplitter s2 = new PartnerAttributedSplitter(address(r2), project, BPS, admin);
        v2.setBalance(makeAddr("direct"), 100e18); // some supply, no wrappers

        uint256 requested = 100e18;
        fot.mint(feePayer, requested);
        vm.startPrank(feePayer);
        fot.approve(address(s2), requested);
        s2.recordFee(requested);
        vm.stopPrank();

        uint256 delivered = 90e18; // 10% skimmed
        assertEq(fot.balanceOf(address(s2)), delivered, "only the delivered amount arrived");
        assertEq(s2.cumulativeReceived(), delivered, "accounting credits delivered, not requested");
        // _totalPending must match the real balance so claims never over-draw.
        assertEq(s2.unrecordedBalance(), 0, "no phantom pending above real balance");
    }

    // ── F-6: a treasury change is timelocked; already-accrued is not redirected ─
    function test_ProjectTreasuryChangeIsTimelocked() public {
        vault.setBalance(makeAddr("direct"), 100e18); // supply, no wrappers => all to project
        _recordFee(40e18); // accrues to project pools, payable to `project`

        address attacker = makeAddr("attacker");
        vm.prank(admin);
        splitter.setProjectTreasury(attacker); // proposal only

        // Not yet applied — claim still pays the ORIGINAL treasury.
        assertEq(splitter.projectTreasury(), project, "change not instant");
        vm.prank(admin);
        vm.expectPartialRevert(PartnerAttributedSplitter.TreasuryTimelockNotElapsed.selector);
        splitter.applyProjectTreasury();

        // The honest project can sweep what is already accrued before the change.
        uint256 owed = splitter.pendingProjectBaseSlice() + splitter.pendingProjectHouseSlice();
        assertGt(owed, 0);
        splitter.claimProject();
        assertEq(asset.balanceOf(project), owed, "already-accrued went to the original treasury");

        // After the timelock the change applies.
        vm.warp(block.timestamp + splitter.TREASURY_TIMELOCK());
        vm.prank(admin);
        splitter.applyProjectTreasury();
        assertEq(splitter.projectTreasury(), attacker);
    }

    function test_ApplyWithoutProposalReverts() public {
        vm.prank(admin);
        vm.expectRevert(PartnerAttributedSplitter.NoPendingTreasury.selector);
        splitter.applyProjectTreasury();
    }

    // ── regression: an honest single-wrapper distribution is unchanged ─────────
    function test_HonestDistributionUnchanged() public {
        address wA = _wrapper("A", makeAddr("pA"), 100e18);
        vault.setBalance(makeAddr("direct"), 100e18); // wA = 1/2 of supply
        address[] memory ws = new address[](1);
        ws[0] = wA;
        _setActive(ws);

        uint256 fee = 40e18;
        uint256 partnerCut = fee * BPS / 10_000;
        uint256 supply = vault.totalSupply();
        uint256 expected = partnerCut * 100e18 / supply; // first observation credits full

        _recordFee(fee);
        assertEq(splitter.pendingForWrapper(wA), expected, "first-observation slice is the honest pro-rata");
    }
}
