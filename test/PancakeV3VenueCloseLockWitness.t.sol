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

/// @notice B4-T1 witness — uses ONLY the pre-existing venue surface (`open` /
/// `close`), so it compiles and runs on `cf31ce4`. It documents the pre-fix
/// vulnerability: a revert inside `close()` leaves `activeTokenId` set and there
/// is no existing function that clears it, so `open()` is blocked and the venue
/// is permanently dead. This test PASSES on both the old and the new code (a
/// broken external call cannot be magicked away by `close()` alone); the recovery
/// that distinguishes the fix — the staged path and the write-off — lives in
/// `PancakeV3VenueResumableClose.t.sol` and references functions that do not
/// exist on `cf31ce4`.
contract LWNfpm is INfpmVenue {
    using SafeERC20 for IERC20;

    mapping(uint256 => uint128) public liq;
    uint256 public nextId = 8000001;
    IERC20 immutable a;
    bool public revertDecrease;

    constructor(IERC20 a_) {
        a = a_;
    }

    function setRevertDecrease(bool v) external {
        revertDecrease = v;
    }

    function mint(MintParams calldata p) external returns (uint256 id, uint128 l, uint256, uint256) {
        if (p.amount0Desired > 0) a.safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        id = nextId++;
        l = uint128(p.amount0Desired);
        liq[id] = l;
        return (id, l, p.amount0Desired, 0);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256, uint256) {
        require(!revertDecrease, "decrease-revert");
        liq[p.tokenId] = 0;
        return (uint256(p.liquidity), 0);
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256) {
        a0 = a.balanceOf(address(this));
        if (a0 > 0) a.safeTransfer(p.recipient, a0);
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

contract LWPool is IV3PoolVenue {
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

contract PancakeV3VenueCloseLockWitnessTest is Test {
    MockUSDT usdt;
    MockUSDT wbnb;
    LWNfpm nfpm;
    LWPool pool;
    PancakeV3MasterchefVenue venue;
    address controller = makeAddr("controller");

    function setUp() public {
        usdt = new MockUSDT();
        wbnb = new MockUSDT();
        nfpm = new LWNfpm(IERC20(address(usdt)));
        pool = new LWPool(address(usdt), address(wbnb));
        // not farmed: isolates the non-masterchef lock (forceUnstake cannot apply).
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

    function _open() internal returns (uint256 id) {
        usdt.mint(controller, 100e18);
        vm.prank(controller);
        usdt.approve(address(venue), 100e18);
        vm.prank(controller);
        id = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: 100e18,
                pairedAmount: 0,
                tickLower: -63973,
                tickUpper: -63822,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function test_StageRevertInCloseLocksVenue() public {
        uint256 id = _open();
        nfpm.setRevertDecrease(true);

        vm.prank(controller);
        vm.expectRevert(bytes("decrease-revert"));
        venue.close(id, 0, 0, block.timestamp);

        // The position is still marked active: close never reached the reset.
        assertEq(venue.activeTokenId(), id, "activeTokenId not cleared by a reverted close");

        // Therefore the venue cannot open a replacement — this is the lock.
        usdt.mint(controller, 10e18);
        vm.prank(controller);
        usdt.approve(address(venue), 10e18);
        vm.prank(controller);
        vm.expectRevert(PancakeV3MasterchefVenue.PositionActive.selector);
        venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: 10e18,
                pairedAmount: 0,
                tickLower: -63973,
                tickUpper: -63822,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }
}
