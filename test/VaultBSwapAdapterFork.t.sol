// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PancakeV3SwapAdapter, ISmartRouterV3} from "../src/PancakeV3SwapAdapter.sol";

/// @notice Resolves a NEEDS_SOURCE before the wired lifecycle proof: does the real
/// PancakeV3SwapAdapter (whose ISmartRouterV3.exactInputSingle struct INCLUDES a
/// `deadline` field) actually work against a live BSC router? Two candidates exist:
///   - PancakeSwap V3 SwapRouter (Uniswap-V3 style, WITH deadline): 0x1b81D678ffb9C0263b24A97847620C99d213eB14
///   - PancakeSwap SmartRouter (SwapRouter02 style, NO deadline):   0x13f4EA83D0bd40E75C8222255bc855a974568Dd4
/// The adapter ABI matches the FORMER. This test proves which router the adapter can
/// drive for a real USDT->WBNB 0.01% swap, returning output to the caller.
contract VaultBSwapAdapterForkTest is Test {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address constant V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // with-deadline ABI
    uint24 constant FEE = 100;     // USDT/WBNB 0.01%
    /// Production-configured CAKE->USDT tier. 500 and 2500 are BOTH deep CAKE/USDT V3
    /// pools whose marginal best output flips per block; we pin a static tier and assert
    /// it is within tolerance of the per-block best (near-optimal), not "always best".
    uint24 constant CAKE_FEE = 500;
    address caller = makeAddr("caller");
    bool forkAvailable;

    function setUp() public {
        try this._fork() {} catch { forkAvailable = false; emit log("VaultBSwapAdapterFork: no BSC fork - skip"); return; }
        forkAvailable = USDT.code.length > 0 && V3_SWAP_ROUTER.code.length > 0;
    }
    function _fork() external {
        require(msg.sender == address(this), "internal");
        string memory rpc = vm.envOr("BSC_FORK_RPC", vm.rpcUrl("bsc"));
        uint256 pin = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pin);
    }
    modifier whenFork() { if (!forkAvailable) { emit log("skip: no fork"); return; } _; }

    /// @notice The adapter (with-deadline ABI) drives the real V3 SwapRouter for a
    /// bounded USDT->WBNB swap; output lands with the caller, none stranded in adapter.
    function test_AdapterSwapsUsdtToWbnb_RealRouter() public whenFork {
        PancakeV3SwapAdapter adapter = new PancakeV3SwapAdapter(
            IERC20(USDT), IERC20(WBNB), IERC20(CAKE), ISmartRouterV3(V3_SWAP_ROUTER), FEE, CAKE_FEE
        );
        deal(USDT, caller, 1000e18);
        vm.startPrank(caller);
        IERC20(USDT).approve(address(adapter), 1000e18);
        uint256 wbnbBefore = IERC20(WBNB).balanceOf(caller);
        // 1000 USDT -> WBNB; minOut ~1 USDT-worth floor (loose, just must be > 0 & realistic)
        uint256 out = adapter.swapAssetToPaired(1000e18, 0.5e18, block.timestamp);
        vm.stopPrank();
        emit log_named_uint("WBNB out", out);
        assertGt(out, 0, "received WBNB");
        assertEq(IERC20(WBNB).balanceOf(caller) - wbnbBefore, out, "output to caller only");
        assertEq(IERC20(USDT).balanceOf(address(adapter)), 0, "no USDT stranded in adapter");
        assertEq(IERC20(WBNB).balanceOf(address(adapter)), 0, "no WBNB stranded in adapter");
    }

    /// @notice Round-trip the other direction (WBNB->USDT) — the close-realization leg.
    function test_AdapterSwapsWbnbToUsdt_RealRouter() public whenFork {
        PancakeV3SwapAdapter adapter = new PancakeV3SwapAdapter(
            IERC20(USDT), IERC20(WBNB), IERC20(CAKE), ISmartRouterV3(V3_SWAP_ROUTER), FEE, CAKE_FEE
        );
        deal(WBNB, caller, 1e18);
        vm.startPrank(caller);
        IERC20(WBNB).approve(address(adapter), 1e18);
        uint256 out = adapter.swapPairedToAsset(1e18, 100e18, block.timestamp); // 1 WBNB -> >=100 USDT
        vm.stopPrank();
        emit log_named_uint("USDT out", out);
        assertGt(out, 100e18, "received USDT above floor");
        assertEq(IERC20(USDT).balanceOf(caller), out, "output to caller only");
    }

    /// @notice Validate the production CAKE->USDT single-hop tier policy. Tries all
    /// standard Pancake V3 tiers, finds the per-block best, and asserts the STATIC
    /// configured `CAKE_FEE` (a) clears and (b) is within 3% of the per-block best — i.e.
    /// a near-optimal static choice. Avoids the unstable "always best" claim (500 vs 2500
    /// flip marginally per block) and closes the silent config/winner mismatch gap.
    function test_CakeToUsdtFeePolicyIsNearOptimal() public whenFork {
        uint24[4] memory tiers = [uint24(100), uint24(500), uint24(2500), uint24(10000)];
        uint256 amt = 100e18; // 100 CAKE
        uint256 best;
        uint24 winner;
        uint256 cfgOut;     // output at the configured CAKE_FEE
        bool cfgCleared;
        for (uint256 i; i < tiers.length; i++) {
            PancakeV3SwapAdapter a = new PancakeV3SwapAdapter(
                IERC20(USDT), IERC20(WBNB), IERC20(CAKE), ISmartRouterV3(V3_SWAP_ROUTER), FEE, tiers[i]
            );
            deal(CAKE, caller, amt);
            vm.startPrank(caller);
            IERC20(CAKE).approve(address(a), amt);
            uint256 usdtBefore = IERC20(USDT).balanceOf(caller);
            try a.swapRewardToAsset(amt, 1, block.timestamp) returns (uint256 out) {
                assertEq(IERC20(USDT).balanceOf(caller) - usdtBefore, out, "output to caller only");
                emit log_named_uint(string.concat("CAKE->USDT ok at fee ", vm.toString(tiers[i])), out);
                if (out > best) { best = out; winner = tiers[i]; }
                if (tiers[i] == CAKE_FEE) { cfgCleared = true; cfgOut = out; }
            } catch {
                emit log_named_uint("CAKE->USDT REVERT at fee", tiers[i]);
            }
            vm.stopPrank();
        }
        emit log_named_uint("per-block best CAKE->USDT tier", winner);
        emit log_named_uint("best USDT out (100 CAKE)", best);
        emit log_named_uint("configured CAKE_FEE", CAKE_FEE);
        emit log_named_uint("configured tier USDT out", cfgOut);
        // the STATIC production choice must clear and be near-optimal on any block
        assertTrue(cfgCleared, "configured CAKE_FEE must clear a single-hop CAKE->USDT swap");
        assertGe(cfgOut, best * 97 / 100, "configured CAKE_FEE within 3% of per-block best");
    }
}
