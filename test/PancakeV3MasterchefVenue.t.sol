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
import {V3PositionValuer} from "../src/libraries/V3PositionValuer.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice Deterministic unit proof of `PancakeV3MasterchefVenue` (no fork):
///   - positionValueAsset wires the audited V3PositionValuer correctly;
///   - onlyController gating;
///   - every token-out goes to the controller only (no third party).
/// Live mainnet mint/stake/close correctness is NEEDS_FORK_PROOF (mocks prove
/// control-flow + security, not real PancakeV3 mint behavior).
contract MockNfpm is INfpmVenue {
    using SafeERC20 for IERC20;

    struct P {
        address t0;
        address t1;
        uint24 fee;
        int24 tl;
        int24 tu;
        uint128 liq;
        uint128 o0;
        uint128 o1;
        bool exists;
    }
    mapping(uint256 => P) public pos;
    uint256 public nextId = 6900340;
    IERC20 immutable a;
    IERC20 immutable b;

    constructor(IERC20 a_, IERC20 b_) {
        a = a_;
        b = b_;
    }

    function setPos(uint256 id, int24 tl, int24 tu, uint128 liq, uint128 o0, uint128 o1) external {
        pos[id] = P(address(a), address(b), 100, tl, tu, liq, o0, o1, true);
    }

    function mint(MintParams calldata p) external returns (uint256 id, uint128 liq, uint256 a0, uint256 a1) {
        if (p.amount0Desired > 0) a.safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        id = nextId;
        liq = uint128(p.amount0Desired);
        pos[id] = P(p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, liq, 0, 0, true);
        return (id, liq, p.amount0Desired, 0);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256, uint256) {
        pos[p.tokenId].liq = 0;
        return (uint256(p.liquidity), 0); // amounts become collectable
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256 a1) {
        // return the venue's locked USDT (mock held it from mint) to recipient
        a0 = a.balanceOf(address(this));
        if (a0 > 0) a.safeTransfer(p.recipient, a0);
        return (a0, 0);
    }

    function burn(uint256 id) external {
        delete pos[id];
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        P memory x = pos[id];
        require(x.exists, "Invalid token ID");
        return (0, address(0), x.t0, x.t1, x.fee, x.tl, x.tu, x.liq, 0, 0, x.o0, x.o1);
    }
    function safeTransferFrom(address, address, uint256) external {}
}

contract MockPool is IV3PoolVenue {
    uint160 public sp;
    int24 public tk;
    address public token0;
    address public token1;
    uint24 public fee;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function set(uint160 s, int24 t) external {
        sp = s;
        tk = t;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sp, tk, 0, 0, 0, 0, true);
    }
}

contract MockMasterchef is IMasterchefVenue {
    using SafeERC20 for IERC20;
    IERC20 public immutable cake;
    uint256 public reward;
    uint256 public harvestCalls;
    uint256 public withdrawCalls;

    constructor(IERC20 cake_, uint256 reward_) {
        cake = cake_;
        reward = reward_;
    }

    function harvest(uint256, address to) external returns (uint256) {
        harvestCalls++;
        if (reward > 0) cake.safeTransfer(to, reward); // CAKE → caller (venue)
        return reward;
    }

    function withdraw(uint256, address) external returns (uint256) {
        withdrawCalls++;
        return 0;
    }

    function collect(IMasterchefVenue.CollectParams calldata) external pure returns (uint256, uint256) {
        return (0, 0); // no LP fees accrued in the mock
    }

    function v3PoolAddressPid(address) external pure returns (uint256) {
        return 1; // any nonzero pid: this masterchef "knows" the pool
    }
}

contract PancakeV3MasterchefVenueTest is Test {
    MockUSDT usdt;
    MockUSDT wbnb;
    MockNfpm nfpm;
    MockPool pool;
    PancakeV3MasterchefVenue venue;
    address controller = makeAddr("controller"); // the DedicatedVaultMain
    address stranger = makeAddr("stranger");
    int24 constant TL = -63973;
    int24 constant TU = -63822;

    function setUp() public {
        usdt = new MockUSDT();
        wbnb = new MockUSDT();
        nfpm = new MockNfpm(IERC20(address(usdt)), IERC20(address(wbnb)));
        pool = new MockPool(address(usdt), address(wbnb), 100);
        // not farmed (masterchef=0) for the unit path; farmed path is wiring-only
        venue = new PancakeV3MasterchefVenue(
            controller,
            IERC20(address(usdt)),
            IERC20(address(wbnb)),
            100,
            IV3PoolVenue(address(pool)),
            INfpmVenue(address(nfpm)),
            IMasterchefVenue(address(0)),
            IERC20(address(0))
        );
    }

    function test_PositionValueAsset_WiresValuer() public {
        nfpm.setPos(6900340, TL, TU, 40300656248215109918, 1e18, 1e15);
        uint160 sp = TickMath.getSqrtRatioAtTick(-63900); // in-range
        pool.set(sp, -63900);
        uint256 got = venue.positionValueAsset(6900340);
        uint256 expect = V3PositionValuer.valueInAssetToken0(sp, TL, TU, 40300656248215109918, 1e18, 1e15);
        assertEq(got, expect, "venue NAV == audited valuer");
        assertGt(got, 0, "non-zero");
        assertEq(venue.positionValueAsset(0), 0, "no position -> 0");
    }

    function test_OnlyController() public {
        vm.startPrank(stranger);
        vm.expectRevert(PancakeV3MasterchefVenue.OnlyController.selector);
        venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: 1e18,
                pairedAmount: 0,
                tickLower: TL,
                tickUpper: TU,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.expectRevert(PancakeV3MasterchefVenue.OnlyController.selector);
        venue.close(6900340, 0, 0, block.timestamp);
        vm.expectRevert(PancakeV3MasterchefVenue.OnlyController.selector);
        venue.harvest(6900340);
        vm.stopPrank();
    }

    function test_OpenCloseReturnsToControllerOnly() public {
        // fund controller, approve venue, open
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(venue), 100e18);
        vm.prank(controller);
        uint256 id = venue.open(
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
        assertEq(venue.activeTokenId(), id, "position active");
        assertEq(usdt.balanceOf(address(venue)), 0, "venue holds no idle (swept)");

        // close → controller gets the USDT back; venue holds nothing; no third party
        uint256 before = usdt.balanceOf(controller);
        vm.prank(controller);
        venue.close(id, 0, 0, block.timestamp);
        assertEq(venue.activeTokenId(), 0, "closed");
        assertEq(usdt.balanceOf(address(venue)), 0, "venue drained to controller");
        assertEq(wbnb.balanceOf(address(venue)), 0, "no WBNB stranded");
        assertGt(usdt.balanceOf(controller) - before, 0, "controller received funds (only recipient)");
    }

    // ──────────── HARDENING: CAKE handling + ERC721 receiver (Codex #2, #3) ────────────

    function test_FarmedHarvestSweepsCakeToControllerOnly() public {
        MockUSDT cake = new MockUSDT();
        MockMasterchef mc = new MockMasterchef(IERC20(address(cake)), 5e18);
        cake.mint(address(mc), 1000e18);
        PancakeV3MasterchefVenue fv = new PancakeV3MasterchefVenue(
            controller,
            IERC20(address(usdt)),
            IERC20(address(wbnb)),
            100,
            IV3PoolVenue(address(pool)),
            INfpmVenue(address(nfpm)),
            IMasterchefVenue(address(mc)),
            IERC20(address(cake))
        );
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(fv), 100e18);
        vm.prank(controller);
        uint256 id = fv.open(
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

        uint256 before = cake.balanceOf(controller);
        vm.prank(controller);
        fv.harvest(id);
        assertEq(cake.balanceOf(controller) - before, 5e18, "CAKE swept to controller");
        assertEq(cake.balanceOf(address(fv)), 0, "no CAKE stranded in venue (not a third party)");
    }

    function test_ForceUnstakePersistsStateSoCloseDoesNotCallMasterchefAgain() public {
        MockUSDT cake = new MockUSDT();
        MockMasterchef mc = new MockMasterchef(IERC20(address(cake)), 0);
        PancakeV3MasterchefVenue fv = new PancakeV3MasterchefVenue(
            controller,
            IERC20(address(usdt)),
            IERC20(address(wbnb)),
            100,
            IV3PoolVenue(address(pool)),
            INfpmVenue(address(nfpm)),
            IMasterchefVenue(address(mc)),
            IERC20(address(cake))
        );
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(fv), 100e18);
        vm.prank(controller);
        uint256 id = fv.open(
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
        assertTrue(fv.activeStaked());

        vm.prank(controller);
        fv.forceUnstakeSkipHarvest(id);
        assertFalse(fv.activeStaked());
        assertEq(mc.harvestCalls(), 1);
        assertEq(mc.withdrawCalls(), 1);

        vm.prank(controller);
        fv.close(id, 0, 0, block.timestamp);
        assertEq(mc.harvestCalls(), 1, "close must not re-harvest an unstaked NFT");
        assertEq(mc.withdrawCalls(), 1, "close must not re-withdraw an unstaked NFT");
        assertEq(fv.activeTokenId(), 0);
    }

    function test_VenueImplementsERC721Receiver() public {
        // ERC721Holder → close's Masterchef safeTransferFrom(unstake) won't revert.
        bytes4 sel = venue.onERC721Received(address(0), address(0), 1, "");
        assertEq(sel, bytes4(0x150b7a02), "returns IERC721Receiver.onERC721Received selector");
    }

    /// @notice farmed venue MUST declare a reward token (else CAKE silently skipped).
    function test_FarmedRequiresRewardToken() public {
        MockMasterchef mc = new MockMasterchef(IERC20(address(usdt)), 0);
        vm.expectRevert(PancakeV3MasterchefVenue.RewardTokenRequired.selector);
        new PancakeV3MasterchefVenue(
            controller,
            IERC20(address(usdt)),
            IERC20(address(wbnb)),
            100,
            IV3PoolVenue(address(pool)),
            INfpmVenue(address(nfpm)),
            IMasterchefVenue(address(mc)),
            IERC20(address(0))
        );
    }
}
