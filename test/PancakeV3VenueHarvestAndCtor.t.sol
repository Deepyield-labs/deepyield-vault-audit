// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    PancakeV3MasterchefVenue,
    INfpmVenue,
    IMasterchefVenue,
    IV3PoolVenue
} from "../src/PancakeV3MasterchefVenue.sol";
import {IDedicatedVenue} from "../src/interfaces/IDedicatedVenue.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice B4-T3 — harvest income must be measured from what the position
/// actually yields (asset entering the venue via collect), not from a delta of
/// the controller's shared balance (inflatable by a donation the sweep picks up).
/// And the constructor must validate its wiring instead of trusting it.

/// @dev NFPM mock whose collect delivers a configured fee INTO the recipient.
contract HNfpm is INfpmVenue {
    using SafeERC20 for IERC20;

    IERC20 immutable a;
    uint256 public nextId = 9000001;
    mapping(uint256 => uint128) public liq;
    uint256 public feeToReturn;

    constructor(IERC20 a_) {
        a = a_;
    }

    function setFee(uint256 v) external {
        feeToReturn = v;
    }

    function mint(MintParams calldata p) external returns (uint256 id, uint128 l, uint256, uint256) {
        if (p.amount0Desired > 0) a.safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        id = nextId++;
        l = uint128(p.amount0Desired);
        liq[id] = l;
        return (id, l, p.amount0Desired, 0);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256, uint256) {
        liq[p.tokenId] = 0;
        return (0, 0);
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256) {
        a0 = feeToReturn;
        if (a0 > 0) a.safeTransfer(p.recipient, a0); // fees flow IN to the venue
        return (a0, 0);
    }

    function burn(uint256 id) external {
        liq[id] = 0;
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), address(a), address(0), 100, int24(0), int24(0), liq[id], 0, 0, 0, 0);
    }

    function safeTransferFrom(address, address, uint256) external {}
}

contract HMasterchef is IMasterchefVenue {
    using SafeERC20 for IERC20;

    IERC20 public immutable cake;
    IERC20 public immutable asset;
    uint256 public feeToReturn;
    uint256 public pid = 1;

    constructor(IERC20 cake_, IERC20 asset_) {
        cake = cake_;
        asset = asset_;
    }

    function setFee(uint256 v) external {
        feeToReturn = v;
    }

    function setPid(uint256 v) external {
        pid = v;
    }

    function harvest(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function collect(IMasterchefVenue.CollectParams calldata p) external returns (uint256 a0, uint256) {
        a0 = feeToReturn;
        if (a0 > 0) asset.safeTransfer(p.recipient, a0);
        return (a0, 0);
    }

    function v3PoolAddressPid(address) external view returns (uint256) {
        return pid;
    }
}

contract HPool is IV3PoolVenue {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address t0, address t1, uint24 f) {
        token0 = t0;
        token1 = t1;
        fee = f;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, true);
    }
}

contract PancakeV3VenueHarvestAndCtorTest is Test {
    MockUSDT usdt;
    MockUSDT wbnb;
    MockUSDT cake;
    HNfpm nfpm;
    HMasterchef mc;
    HPool pool;
    address controller = makeAddr("controller");
    int24 constant TL = -63973;
    int24 constant TU = -63822;

    function setUp() public {
        usdt = new MockUSDT();
        wbnb = new MockUSDT();
        cake = new MockUSDT();
        nfpm = new HNfpm(IERC20(address(usdt)));
        mc = new HMasterchef(IERC20(address(cake)), IERC20(address(usdt)));
        pool = new HPool(address(usdt), address(wbnb), 100);
    }

    function _deployVenue(IMasterchefVenue masterchef_, IERC20 reward_) internal returns (PancakeV3MasterchefVenue v) {
        v = new PancakeV3MasterchefVenue(
            controller, IERC20(address(usdt)), IERC20(address(wbnb)), 100, IV3PoolVenue(address(pool)), INfpmVenue(address(nfpm)), masterchef_, reward_
        );
    }

    function _open(PancakeV3MasterchefVenue v) internal returns (uint256 id) {
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(v), 100e18);
        vm.prank(controller);
        id = v.open(
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

    // ── Finding 1: harvest income is donation-immune ─────────────────────────

    function test_HarvestUnstaked_DonationToVenueNotCountedAsIncome() public {
        PancakeV3MasterchefVenue v = _deployVenue(IMasterchefVenue(address(0)), IERC20(address(0)));
        uint256 id = _open(v);

        nfpm.setFee(7e18); // real fees collected this call
        usdt.mint(address(nfpm), 7e18); // fund the nfpm to pay them
        usdt.mint(address(v), 5e18); // an outsider donates to the venue

        uint256 ctrlBefore = usdt.balanceOf(controller);
        vm.prank(controller);
        uint256 collected = v.harvest(id);

        assertEq(collected, 7e18, "income = real fees only, donation excluded");
        assertEq(usdt.balanceOf(controller) - ctrlBefore, 12e18, "everything is still swept to the controller");
        assertEq(usdt.balanceOf(address(v)), 0, "venue drained");
    }

    function test_HarvestUnstaked_ZeroCollectionIsZero() public {
        PancakeV3MasterchefVenue v = _deployVenue(IMasterchefVenue(address(0)), IERC20(address(0)));
        uint256 id = _open(v);
        usdt.mint(address(v), 3e18); // donation only, no real fees
        vm.prank(controller);
        assertEq(v.harvest(id), 0, "no collection -> zero, not the donation");
    }

    function test_HarvestStaked_DonationNotCountedAsIncome() public {
        PancakeV3MasterchefVenue v = _deployVenue(mc, IERC20(address(cake)));
        uint256 id = _open(v);
        assertTrue(v.activeStaked());

        mc.setFee(4e18);
        usdt.mint(address(mc), 4e18);
        usdt.mint(address(v), 6e18); // donation

        vm.prank(controller);
        uint256 collected = v.harvest(id);
        assertEq(collected, 4e18, "staked path also counts only real LP fees");
    }

    // ── Finding 2: constructor validates its wiring ──────────────────────────

    function test_Ctor_RejectsZeroController() public {
        vm.expectRevert(PancakeV3MasterchefVenue.ZeroAddress.selector);
        new PancakeV3MasterchefVenue(
            address(0), IERC20(address(usdt)), IERC20(address(wbnb)), 100, IV3PoolVenue(address(pool)), INfpmVenue(address(nfpm)), IMasterchefVenue(address(0)), IERC20(address(0))
        );
    }

    function test_Ctor_RejectsNonContractNfpm() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(PancakeV3MasterchefVenue.NotContract.selector, eoa));
        new PancakeV3MasterchefVenue(
            controller, IERC20(address(usdt)), IERC20(address(wbnb)), 100, IV3PoolVenue(address(pool)), INfpmVenue(eoa), IMasterchefVenue(address(0)), IERC20(address(0))
        );
    }

    function test_Ctor_RejectsSwappedTokenOrder() public {
        HPool bad = new HPool(address(wbnb), address(usdt), 100); // token0/token1 swapped
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3MasterchefVenue.PoolTokenMismatch.selector,
                address(usdt),
                address(wbnb),
                address(wbnb),
                address(usdt)
            )
        );
        new PancakeV3MasterchefVenue(
            controller, IERC20(address(usdt)), IERC20(address(wbnb)), 100, IV3PoolVenue(address(bad)), INfpmVenue(address(nfpm)), IMasterchefVenue(address(0)), IERC20(address(0))
        );
    }

    function test_Ctor_RejectsWrongFeeTier() public {
        HPool bad = new HPool(address(usdt), address(wbnb), 500);
        vm.expectRevert(abi.encodeWithSelector(PancakeV3MasterchefVenue.PoolFeeMismatch.selector, uint24(100), uint24(500)));
        new PancakeV3MasterchefVenue(
            controller, IERC20(address(usdt)), IERC20(address(wbnb)), 100, IV3PoolVenue(address(bad)), INfpmVenue(address(nfpm)), IMasterchefVenue(address(0)), IERC20(address(0))
        );
    }

    function test_Ctor_RejectsMasterchefThatDoesNotFarmPool() public {
        mc.setPid(0); // masterchef does not know this pool
        vm.expectRevert(abi.encodeWithSelector(PancakeV3MasterchefVenue.MasterchefPoolUnknown.selector, address(pool)));
        _deployVenue(mc, IERC20(address(cake)));
    }

    function test_Ctor_ValidWiringDeploys() public {
        PancakeV3MasterchefVenue v = _deployVenue(mc, IERC20(address(cake)));
        assertEq(address(v.pool()), address(pool));
        assertTrue(v.farmed());
    }
}
