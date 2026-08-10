// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BoundedPancakeExecutionAdapterV2} from "../src/BoundedPancakeExecutionAdapterV2.sol";
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {IVaultBPriceGuard} from "../src/interfaces/IVaultBExecutionV2.sol";

contract VaultBExecutionV2ForkTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    VaultBPriceGuard internal guard;
    BoundedPancakeExecutionAdapterV2 internal adapter;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        guard = new VaultBPriceGuard({
            normalLossBps_: 100,
            maxEmergencyLossBps_: 1_000,
            maxOracleDeviationBps_: 500,
            twapWindow_: 1_800,
            maxBnbFeedAge_: 3_600,
            maxUsdtFeedAge_: 90_000,
            maxEmergencyDuration_: 600,
            admin_: address(this),
            guardian_: address(this)
        });
        adapter = new BoundedPancakeExecutionAdapterV2(address(this), IVaultBPriceGuard(address(guard)), 120);
        adapter.bindMain(address(this));
    }

    function testForkCanonicalWbnbOracleAndTwapAgree() public view {
        VaultBPriceGuard.Quote memory buy = guard.quote(USDT, WBNB, 1_000e18, false);
        assertGt(buy.chainlinkOut, 0);
        assertGt(buy.twapOut, 0);
        assertLe(buy.deviationBps, 500);
        assertLt(buy.minOut, buy.fairOut);

        VaultBPriceGuard.Quote memory sell = guard.quote(WBNB, USDT, 1e18, false);
        assertGt(sell.minOut, 0);
        assertLe(sell.deviationBps, 500);
    }

    function testForkDirectPancakeRoundTripUsesOnlyCanonicalWbnb() public {
        uint256 usdtIn = 100e18;
        deal(USDT, address(this), usdtIn);
        IERC20(USDT).approve(address(adapter), usdtIn);

        uint256 wbnbBefore = IERC20(WBNB).balanceOf(address(this));
        uint256 wbnbOut = adapter.swapAssetToPaired(usdtIn, 1, block.timestamp + 60, false);
        assertEq(IERC20(WBNB).balanceOf(address(this)) - wbnbBefore, wbnbOut);
        assertGt(wbnbOut, 0);
        assertEq(IERC20(USDT).allowance(address(adapter), ROUTER), 0);
        assertEq(address(adapter).balance, 0, "no native BNB");

        IERC20(WBNB).approve(address(adapter), wbnbOut);
        uint256 usdtBeforeSell = IERC20(USDT).balanceOf(address(this));
        uint256 usdtOut = adapter.swapPairedToAsset(wbnbOut, 1, block.timestamp + 60, false);
        assertEq(IERC20(USDT).balanceOf(address(this)) - usdtBeforeSell, usdtOut);
        assertGt(usdtOut, 97e18, "round-trip loss unexpectedly high");
        assertEq(IERC20(WBNB).allowance(address(adapter), ROUTER), 0);
        assertEq(IERC20(WBNB).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDT).balanceOf(address(adapter)), 0);
    }
}
