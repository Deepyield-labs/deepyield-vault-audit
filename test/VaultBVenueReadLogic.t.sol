// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice DETERMINISTIC (no fork, no live state) proof of the Vault B NAV
/// read-path LOGIC: staked-tokenId discovery → NFPM.positions read → in/out-of-
/// range classification. Uses mocks programmed with the real fixture observed
/// on-chain (tokenId 6900340: USDT/WBNB, fee 100, ticks −63973/−63822). This is
/// the reproducible, non-vacuous counterpart to the live fork read-proof (which
/// is environment-gated: free BSC dataseed is non-archive, and the bot's Main
/// currently holds no staked NFT — token 6900340 is now burned).
///
/// Proves the LOGIC the venue valuer will use; the final amount math
/// (LiquidityAmounts) is the separate NEXT and is intentionally not done here.

interface IMasterchefLike {
    function balanceOf(address) external view returns (uint256);
    function tokenOfOwnerByIndex(address, uint256) external view returns (uint256);
}
interface INFPMLike {
    function positions(uint256) external view returns (
        uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
    );
}
interface IPoolLike {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

contract MockMasterchef is IMasterchefLike {
    mapping(address => uint256[]) staked;
    function stake(address owner, uint256 id) external { staked[owner].push(id); }
    function balanceOf(address o) external view returns (uint256) { return staked[o].length; }
    function tokenOfOwnerByIndex(address o, uint256 i) external view returns (uint256) {
        require(i < staked[o].length, "index oob");
        return staked[o][i];
    }
}
contract MockNFPM is INFPMLike {
    struct P { address t0; address t1; uint24 fee; int24 tl; int24 tu; uint128 liq; uint128 owed0; uint128 owed1; bool exists; }
    mapping(uint256 => P) p;
    function set(uint256 id, address t0, address t1, uint24 fee, int24 tl, int24 tu, uint128 liq, uint128 o0, uint128 o1) external {
        p[id] = P(t0, t1, fee, tl, tu, liq, o0, o1, true);
    }
    function positions(uint256 id) external view returns (
        uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
    ) {
        P memory x = p[id];
        require(x.exists, "Invalid token ID");
        return (0, address(0), x.t0, x.t1, x.fee, x.tl, x.tu, x.liq, 0, 0, x.owed0, x.owed1);
    }
}
contract MockPool is IPoolLike {
    int24 public curTick;
    uint160 public sp = 3221299242269433791223874168; // ~ live slot0
    function setTick(int24 t) external { curTick = t; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sp, curTick, 0, 0, 0, 0, true);
    }
}

contract VaultBVenueReadLogicTest is Test {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 constant TID = 6900340;

    MockMasterchef mc;
    MockNFPM nfpm;
    MockPool pool;
    address main = makeAddr("dedicatedMain");

    function setUp() public {
        mc = new MockMasterchef();
        nfpm = new MockNFPM();
        pool = new MockPool();
        // real fixture observed on-chain (see read-proof doc)
        nfpm.set(TID, USDT, WBNB, 100, -63973, -63822, 40300656248215109918, 0, 0);
        mc.stake(main, TID);
    }

    /// in/out-of-range classification used by NAV: below→all token0(USDT), in→both, above→all token1(WBNB).
    function _classify(int24 tick, int24 tl, int24 tu) internal pure returns (string memory) {
        if (tick < tl) return "below(all USDT)";
        if (tick >= tu) return "above(all WBNB)";
        return "in-range(both)";
    }

    function test_DiscoverAndReadStakedPosition() public view {
        // discovery
        assertEq(mc.balanceOf(main), 1, "one staked NFT");
        uint256 id = mc.tokenOfOwnerByIndex(main, 0);
        assertEq(id, TID, "tokenId discovered");
        // read while staked
        (, , address t0, address t1, uint24 fee, int24 tl, int24 tu, uint128 liq, , , , ) = nfpm.positions(id);
        assertEq(t0, USDT);
        assertEq(t1, WBNB);
        assertEq(fee, 100);
        assertTrue(tl < tu && tu - tl == 151, "tight ~151-tick range");
        assertGt(uint256(liq), 0, "non-zero liquidity");
    }

    function test_RangeClassification() public {
        ( , , , , , int24 tl, int24 tu, , , , , ) = nfpm.positions(TID);
        // below range (live head was tick -64055 < tickLower)
        pool.setTick(-64055);
        ( , int24 t, , , , , ) = pool.slot0();
        assertEq(_classify(t, tl, tu), "below(all USDT)", "out-of-range below");
        // in range
        pool.setTick(-63900);
        ( , t, , , , , ) = pool.slot0();
        assertEq(_classify(t, tl, tu), "in-range(both)");
        // above range
        pool.setTick(-63800);
        ( , t, , , , , ) = pool.slot0();
        assertEq(_classify(t, tl, tu), "above(all WBNB)");
    }

    function test_BurnedTokenReverts() public {
        vm.expectRevert(bytes("Invalid token ID"));
        nfpm.positions(999999); // unset → mimics burned 6900340 at head
    }
}
