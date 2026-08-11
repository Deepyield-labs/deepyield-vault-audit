// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    PancakeV3MasterchefVenue,
    INfpmVenue,
    IMasterchefVenue,
    IV3PoolVenue
} from "../src/PancakeV3MasterchefVenue.sol";
import {IDedicatedVenue} from "../src/interfaces/IDedicatedVenue.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice B4-T1 — `close()` was a six-external-call chain with no per-step
/// recovery; a revert on any step rolled everything back while `activeTokenId`
/// stayed set, so `open()` was blocked forever. These tests drive the resumable
/// staged close and the stranded-position write-off through mocks that revert on
/// a chosen stage (transiently or permanently).

/// @dev NFPM mock with per-call revert toggles and logical NFT-owner tracking.
contract RNfpm is INfpmVenue {
    using SafeERC20 for IERC20;

    struct P {
        int24 tl;
        int24 tu;
        uint128 liq;
        bool exists;
    }

    mapping(uint256 => P) public pos;
    mapping(uint256 => address) public tokenOwner;
    uint256 public nextId = 7000001;
    IERC20 immutable a;

    bool public revertDecrease;
    bool public revertCollect;
    bool public revertBurn;

    uint256 public decreaseCalls;
    uint256 public collectCalls;
    uint256 public burnCalls;

    constructor(IERC20 a_) {
        a = a_;
    }

    function setRevertDecrease(bool v) external {
        revertDecrease = v;
    }

    function setRevertCollect(bool v) external {
        revertCollect = v;
    }

    function setRevertBurn(bool v) external {
        revertBurn = v;
    }

    function mint(MintParams calldata p) external returns (uint256 id, uint128 liq, uint256, uint256) {
        if (p.amount0Desired > 0) a.safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        id = nextId++;
        liq = uint128(p.amount0Desired);
        pos[id] = P(p.tickLower, p.tickUpper, liq, true);
        tokenOwner[id] = p.recipient;
        return (id, liq, p.amount0Desired, 0);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256, uint256) {
        require(!revertDecrease, "decrease-revert");
        decreaseCalls++;
        pos[p.tokenId].liq = 0;
        return (uint256(p.liquidity), 0);
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256 a1) {
        require(!revertCollect, "collect-revert");
        collectCalls++;
        a0 = a.balanceOf(address(this));
        if (a0 > 0) a.safeTransfer(p.recipient, a0);
        return (a0, 0);
    }

    function burn(uint256 id) external {
        require(!revertBurn, "burn-revert");
        burnCalls++;
        delete pos[id];
        delete tokenOwner[id];
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        P memory x = pos[id];
        require(x.exists, "Invalid token ID");
        return (0, address(0), address(a), address(0), 100, x.tl, x.tu, x.liq, 0, 0, 0, 0);
    }

    function safeTransferFrom(address, address to, uint256 id) external {
        tokenOwner[id] = to;
    }
}

/// @dev Masterchef mock with harvest/withdraw revert toggles. On a successful
/// withdraw it hands the NFT (logical owner) back to `to`, like the real one.
contract RMasterchef is IMasterchefVenue {
    using SafeERC20 for IERC20;

    IERC20 public immutable cake;
    RNfpm public immutable nfpm;
    uint256 public reward;
    bool public revertHarvest;
    bool public revertWithdraw;
    uint256 public harvestCalls;
    uint256 public withdrawCalls;

    constructor(IERC20 cake_, RNfpm nfpm_, uint256 reward_) {
        cake = cake_;
        nfpm = nfpm_;
        reward = reward_;
    }

    function setRevertHarvest(bool v) external {
        revertHarvest = v;
    }

    function setRevertWithdraw(bool v) external {
        revertWithdraw = v;
    }

    function harvest(uint256, address to) external returns (uint256) {
        require(!revertHarvest, "harvest-revert");
        harvestCalls++;
        if (reward > 0) cake.safeTransfer(to, reward);
        return reward;
    }

    // Mirrors MasterChefV3.withdraw: the reward path runs first (so a broken
    // reward path reverts withdraw too — see report), then the NFT is released.
    function withdraw(uint256 tokenId, address to) external returns (uint256) {
        require(!revertWithdraw, "withdraw-revert");
        withdrawCalls++;
        nfpm.safeTransferFrom(address(this), to, tokenId);
        return 0;
    }

    function collect(IMasterchefVenue.CollectParams calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function v3PoolAddressPid(address) external pure returns (uint256) {
        return 1;
    }
}

contract MockPoolRC is IV3PoolVenue {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 100;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, true);
    }
}

contract PancakeV3VenueResumableCloseTest is Test {
    MockUSDT usdt;
    MockUSDT wbnb;
    MockUSDT cake;
    RNfpm nfpm;
    RMasterchef mc;
    MockPoolRC pool;
    PancakeV3MasterchefVenue venue;

    address controller = makeAddr("controller");
    address stranger = makeAddr("stranger");
    int24 constant TL = -63973;
    int24 constant TU = -63822;

    function setUp() public {
        usdt = new MockUSDT();
        wbnb = new MockUSDT();
        cake = new MockUSDT();
        nfpm = new RNfpm(IERC20(address(usdt)));
        mc = new RMasterchef(IERC20(address(cake)), nfpm, 3e18);
        cake.mint(address(mc), 1000e18);
        pool = new MockPoolRC(address(usdt), address(wbnb));
        venue = new PancakeV3MasterchefVenue(
            controller,
            IERC20(address(usdt)),
            IERC20(address(wbnb)),
            100,
            IV3PoolVenue(address(pool)),
            INfpmVenue(address(nfpm)),
            IMasterchefVenue(address(mc)),
            IERC20(address(cake))
        );
    }

    function _open() internal returns (uint256 id) {
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(venue), 100e18);
        vm.prank(controller);
        id = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: 100e18,
                pairedAmount: 0,
                tickLower: TL,
                tickUpper: TU,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _reopenWorks() internal {
        // A fresh position can be opened once the venue is unlocked.
        usdt.mint(controller, 10e18);
        vm.prank(controller);
        usdt.approve(address(venue), 10e18);
        vm.prank(controller);
        uint256 id2 = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: 10e18,
                pairedAmount: 0,
                tickLower: TL,
                tickUpper: TU,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertEq(venue.activeTokenId(), id2, "venue reopened after recovery");
    }

    // ── п.1: masterchef fully broken (harvest AND withdraw revert) ───────────
    // forceUnstakeSkipHarvest cannot save this (withdraw reverts too, verified
    // against MasterChefV3), and every close stage that touches masterchef
    // reverts. The write-off is the only exit; the NFT stays tracked in the
    // masterchef and the venue is freed.
    function test_MasterchefBrokenRecoveredByWriteOff() public {
        uint256 id = _open();
        assertTrue(venue.activeStaked());
        mc.setRevertHarvest(true);
        mc.setRevertWithdraw(true);

        vm.prank(controller);
        vm.expectRevert(PancakeV3MasterchefVenue.ForceUnstakeUnavailable.selector);
        venue.forceUnstakeSkipHarvest(id);

        vm.prank(controller);
        vm.expectRevert(bytes("harvest-revert"));
        venue.close(id, 0, 0, block.timestamp);

        vm.prank(controller);
        vm.expectRevert(bytes("harvest-revert"));
        venue.closeUnstake(id);

        vm.prank(controller);
        uint256 stranded = venue.writeOffStrandedPosition();
        assertEq(stranded, id);
        assertEq(venue.strandedTokenId(), id, "stranded id retained for accounting");
        assertTrue(venue.strandedWasStaked(), "recorded as still staked in masterchef");
        assertEq(nfpm.tokenOwner(id), address(mc), "NFT not lost: still in masterchef, tracked");
        assertEq(venue.activeTokenId(), 0, "venue freed");
        _reopenWorks();
    }

    // ── п.2: revert on decreaseLiquidity (permanent) ─────────────────────────
    function test_DecreaseRevertRecoveredByWriteOff() public {
        uint256 id = _open();
        vm.prank(controller);
        venue.closeUnstake(id); // masterchef ok
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.UNSTAKED));

        nfpm.setRevertDecrease(true);
        vm.prank(controller);
        vm.expectRevert(bytes("decrease-revert"));
        venue.closeDecrease(id, 0, 0, block.timestamp);
        // progress not lost: still UNSTAKED, masterchef not re-touched
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.UNSTAKED));

        vm.prank(controller);
        venue.writeOffStrandedPosition();
        assertFalse(venue.strandedWasStaked(), "NFT was already unstaked at the venue");
        assertEq(nfpm.tokenOwner(id), controller, "NFT not lost: returned to controller");
        assertEq(venue.activeTokenId(), 0);
        _reopenWorks();
    }

    // ── п.2: revert on collect (permanent) ───────────────────────────────────
    function test_CollectRevertRecoveredByWriteOff() public {
        uint256 id = _open();
        vm.startPrank(controller);
        venue.closeUnstake(id);
        venue.closeDecrease(id, 0, 0, block.timestamp);
        vm.stopPrank();

        nfpm.setRevertCollect(true);
        vm.prank(controller);
        vm.expectRevert(bytes("collect-revert"));
        venue.closeCollect(id);
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.DECREASED));

        vm.prank(controller);
        venue.writeOffStrandedPosition();
        assertEq(nfpm.tokenOwner(id), controller);
        assertEq(venue.activeTokenId(), 0);
        _reopenWorks();
    }

    // ── п.2: revert on burn (permanent) ──────────────────────────────────────
    function test_BurnRevertRecoveredByWriteOff() public {
        uint256 id = _open();
        vm.startPrank(controller);
        venue.closeUnstake(id);
        venue.closeDecrease(id, 0, 0, block.timestamp);
        venue.closeCollect(id);
        vm.stopPrank();
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.COLLECTED));
        // collected proceeds already returned to the controller
        assertGt(usdt.balanceOf(controller), 0);

        nfpm.setRevertBurn(true);
        vm.prank(controller);
        vm.expectRevert(bytes("burn-revert"));
        venue.closeBurn(id);
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.COLLECTED));

        vm.prank(controller);
        venue.writeOffStrandedPosition();
        assertEq(nfpm.tokenOwner(id), controller);
        assertEq(venue.activeTokenId(), 0);
        _reopenWorks();
    }

    // ── п.3: transient revert — progress is preserved across the retry ───────
    function test_TransientDecreaseRevert_ProgressPreservedThenCompletes() public {
        uint256 id = _open();
        vm.prank(controller);
        venue.closeUnstake(id);
        assertEq(mc.harvestCalls(), 1);
        assertEq(mc.withdrawCalls(), 1);

        nfpm.setRevertDecrease(true);
        vm.prank(controller);
        vm.expectRevert(bytes("decrease-revert"));
        venue.closeDecrease(id, 0, 0, block.timestamp);

        // transient condition clears; resume from the failed stage
        nfpm.setRevertDecrease(false);
        vm.startPrank(controller);
        venue.closeDecrease(id, 0, 0, block.timestamp);
        venue.closeCollect(id);
        venue.closeBurn(id);
        vm.stopPrank();

        // unstake stage was NOT replayed while resuming later stages
        assertEq(mc.harvestCalls(), 1, "unstake not redone");
        assertEq(mc.withdrawCalls(), 1, "unstake not redone");
        assertEq(nfpm.decreaseCalls(), 1);
        assertEq(nfpm.burnCalls(), 1);
        assertEq(venue.activeTokenId(), 0);
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.NONE));
        assertGt(usdt.balanceOf(controller), 0, "proceeds returned to controller only");
        _reopenWorks();
    }

    // ── п.4: write-off authorization + event + NFT tracking ──────────────────
    function test_WriteOffOnlyControllerAndEmitsEvent() public {
        uint256 id = _open();
        mc.setRevertHarvest(true);
        mc.setRevertWithdraw(true);

        vm.prank(stranger);
        vm.expectRevert(PancakeV3MasterchefVenue.OnlyController.selector);
        venue.writeOffStrandedPosition();

        vm.expectEmit(true, false, false, true, address(venue));
        emit PancakeV3MasterchefVenue.PositionStranded(id, true, address(mc));
        vm.prank(controller);
        venue.writeOffStrandedPosition();

        // no active position → write-off has nothing to abandon
        vm.prank(controller);
        vm.expectRevert(PancakeV3MasterchefVenue.NoActivePosition.selector);
        venue.writeOffStrandedPosition();
    }

    // ── п.5: regression — the happy-path atomic close is unchanged ───────────
    function test_HappyPathAtomicCloseUnchanged() public {
        uint256 id = _open();
        uint256 before = usdt.balanceOf(controller);

        vm.prank(controller);
        venue.close(id, 0, 0, block.timestamp);

        assertEq(venue.activeTokenId(), 0, "closed");
        assertEq(uint8(venue.closeStage()), uint8(PancakeV3MasterchefVenue.CloseStage.NONE));
        assertEq(usdt.balanceOf(address(venue)), 0, "venue drained to controller");
        assertEq(wbnb.balanceOf(address(venue)), 0, "no WBNB stranded");
        assertGt(usdt.balanceOf(controller) - before, 0, "controller is the only recipient");
        assertEq(mc.harvestCalls(), 1);
        assertEq(mc.withdrawCalls(), 1);
        assertEq(nfpm.burnCalls(), 1);
    }

    // ── staged ordering is enforced ──────────────────────────────────────────
    function test_StagedCallsRejectOutOfOrder() public {
        uint256 id = _open();
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3MasterchefVenue.CloseStageMismatch.selector,
                uint8(PancakeV3MasterchefVenue.CloseStage.DECREASED),
                uint8(PancakeV3MasterchefVenue.CloseStage.NONE)
            )
        );
        venue.closeCollect(id); // cannot collect before unstake+decrease
    }
}
