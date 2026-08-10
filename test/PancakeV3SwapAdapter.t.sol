// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PancakeV3SwapAdapter, ISmartRouterV3} from "../src/PancakeV3SwapAdapter.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @dev Mock SmartRouter: fixed rate keyed by (tokenIn, tokenOut, fee), enforces
/// deadline + amountOutMinimum, reverts unsupported routes (incl. wrong fee tier),
/// sends output to params.recipient (the caller).
contract MockSmartRouter is ISmartRouterV3 {
    using SafeERC20 for IERC20;
    mapping(bytes32 => uint256) public rate; // out per 1e18 in, keyed by (tokenIn, tokenOut, fee)
    function setRate(address i, address o, uint24 fee, uint256 r) external { rate[keccak256(abi.encode(i, o, fee))] = r; }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(block.timestamp <= p.deadline, "deadline");
        uint256 r = rate[keccak256(abi.encode(p.tokenIn, p.tokenOut, p.fee))];
        require(r > 0, "unsupported pair"); // wrong fee tier -> no rate -> reverts
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * r / 1e18;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).safeTransfer(p.recipient, out);
    }
}

contract PancakeV3SwapAdapterTest is Test {
    MockUSDT usdt; MockUSDT wbnb; MockUSDT cake;
    MockSmartRouter router;
    PancakeV3SwapAdapter adapter;

    uint24 constant PAIR_FEE = 100;
    uint24 constant REWARD_FEE = 2500;

    function setUp() public {
        usdt = new MockUSDT(); wbnb = new MockUSDT(); cake = new MockUSDT();
        router = new MockSmartRouter();
        // rates (per 1e18) at the configured fee tiers only:
        router.setRate(address(wbnb), address(usdt), PAIR_FEE, 1000e18);  // 1 WBNB -> 1000 USDT
        router.setRate(address(usdt), address(wbnb), PAIR_FEE, 1e15);     // 1000e18 USDT -> 1e18 WBNB
        router.setRate(address(cake), address(usdt), REWARD_FEE, 4e18);   // 1 CAKE -> 4 USDT
        usdt.mint(address(router), 10_000_000e18);
        wbnb.mint(address(router), 100_000e18);
        adapter = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)),
            ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE
        );
    }

    // ---- happy paths: output to caller only ----

    function test_SwapAssetToPaired_OutputToCaller() public {
        usdt.mint(address(this), 1000e18);
        usdt.approve(address(adapter), 1000e18);
        uint256 before = wbnb.balanceOf(address(this));
        uint256 out = adapter.swapAssetToPaired(1000e18, 0.9e18, block.timestamp);
        assertEq(out, 1e18, "1000 USDT -> 1 WBNB");
        assertEq(wbnb.balanceOf(address(this)) - before, 1e18, "WBNB to caller only");
        assertEq(usdt.balanceOf(address(adapter)), 0, "no input stranded in adapter");
        assertEq(wbnb.balanceOf(address(adapter)), 0, "no output stranded in adapter");
    }

    function test_SwapPairedToAsset_OutputToCaller() public {
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(adapter), 1e18);
        uint256 out = adapter.swapPairedToAsset(1e18, 900e18, block.timestamp);
        assertEq(out, 1000e18, "1 WBNB -> 1000 USDT");
        assertEq(usdt.balanceOf(address(this)), 1000e18, "USDT to caller");
    }

    function test_SwapRewardToAsset_OutputToCaller() public {
        cake.mint(address(this), 10e18);
        cake.approve(address(adapter), 10e18);
        uint256 out = adapter.swapRewardToAsset(10e18, 35e18, block.timestamp);
        assertEq(out, 40e18, "10 CAKE -> 40 USDT");
        assertEq(usdt.balanceOf(address(this)), 40e18, "USDT to caller");
    }

    // ---- bounds: minOut / deadline / zero-min ----

    function test_MinOutTooHighReverts() public {
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(adapter), 1e18);
        vm.expectRevert(bytes("Too little received")); // 1000 < 1100 minOut
        adapter.swapPairedToAsset(1e18, 1100e18, block.timestamp);
    }

    function test_DeadlinePastReverts() public {
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(adapter), 1e18);
        vm.warp(1000);
        vm.expectRevert(bytes("deadline"));
        adapter.swapPairedToAsset(1e18, 900e18, 999);
    }

    function test_ZeroMinOutReverts() public {
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(adapter), 1e18);
        vm.expectRevert(PancakeV3SwapAdapter.ZeroMinOut.selector);
        adapter.swapPairedToAsset(1e18, 0, block.timestamp);
    }

    function test_UnconfiguredRewardReverts() public {
        PancakeV3SwapAdapter noReward = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(0)),
            ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE
        );
        vm.expectRevert(PancakeV3SwapAdapter.RewardUnconfigured.selector);
        noReward.swapRewardToAsset(1e18, 1, block.timestamp);
    }

    // ---- unsupported route: empty router has no rate at any fee ----

    function test_UnsupportedPairReverts() public {
        MockSmartRouter empty = new MockSmartRouter();
        PancakeV3SwapAdapter onEmpty = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)),
            ISmartRouterV3(address(empty)), PAIR_FEE, REWARD_FEE
        );
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(onEmpty), 1e18);
        vm.expectRevert(bytes("unsupported pair"));
        onEmpty.swapPairedToAsset(1e18, 1, block.timestamp);
    }

    // ---- wrong fee tier: router only has rates at PAIR_FEE/REWARD_FEE ----

    function test_WrongPairFeeReverts_AssetToPaired() public {
        PancakeV3SwapAdapter badPairFee = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)),
            ISmartRouterV3(address(router)), 500, REWARD_FEE // 500 != 100 -> no rate
        );
        usdt.mint(address(this), 1000e18);
        usdt.approve(address(badPairFee), 1000e18);
        vm.expectRevert(bytes("unsupported pair"));
        badPairFee.swapAssetToPaired(1000e18, 1, block.timestamp);
    }

    function test_WrongPairFeeReverts_PairedToAsset() public {
        PancakeV3SwapAdapter badPairFee = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)),
            ISmartRouterV3(address(router)), 500, REWARD_FEE
        );
        wbnb.mint(address(this), 1e18);
        wbnb.approve(address(badPairFee), 1e18);
        vm.expectRevert(bytes("unsupported pair"));
        badPairFee.swapPairedToAsset(1e18, 1, block.timestamp);
    }

    function test_WrongRewardFeeReverts() public {
        PancakeV3SwapAdapter badRewardFee = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)),
            ISmartRouterV3(address(router)), PAIR_FEE, 3000 // 3000 != 2500 -> no rate
        );
        cake.mint(address(this), 10e18);
        cake.approve(address(badRewardFee), 10e18);
        vm.expectRevert(bytes("unsupported pair"));
        badRewardFee.swapRewardToAsset(10e18, 1, block.timestamp);
    }

    // ---- constructor validation ----

    function test_Ctor_RejectsZeroAsset() public {
        vm.expectRevert(PancakeV3SwapAdapter.ZeroAddress.selector);
        new PancakeV3SwapAdapter(IERC20(address(0)), IERC20(address(wbnb)), IERC20(address(cake)), ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsZeroPaired() public {
        vm.expectRevert(PancakeV3SwapAdapter.ZeroAddress.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(0)), IERC20(address(cake)), ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsZeroRouter() public {
        vm.expectRevert(PancakeV3SwapAdapter.ZeroAddress.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)), ISmartRouterV3(address(0)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsAssetEqualsPaired() public {
        vm.expectRevert(PancakeV3SwapAdapter.AssetEqualsPaired.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(usdt)), IERC20(address(cake)), ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsZeroPairFee() public {
        vm.expectRevert(PancakeV3SwapAdapter.ZeroPairFee.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)), ISmartRouterV3(address(router)), 0, REWARD_FEE);
    }

    function test_Ctor_RejectsRewardEqualsAsset() public {
        vm.expectRevert(PancakeV3SwapAdapter.RewardEqualsAsset.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(usdt)), ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsRewardEqualsPaired() public {
        vm.expectRevert(PancakeV3SwapAdapter.RewardEqualsPaired.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(wbnb)), ISmartRouterV3(address(router)), PAIR_FEE, REWARD_FEE);
    }

    function test_Ctor_RejectsZeroRewardFeeWhenRewardSet() public {
        vm.expectRevert(PancakeV3SwapAdapter.ZeroRewardFee.selector);
        new PancakeV3SwapAdapter(IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(cake)), ISmartRouterV3(address(router)), PAIR_FEE, 0);
    }

    function test_Ctor_AllowsZeroRewardWithZeroRewardFee() public {
        // reward == 0 deployment: rewardFee == 0 is fine (swapRewardToAsset never called)
        PancakeV3SwapAdapter noReward = new PancakeV3SwapAdapter(
            IERC20(address(usdt)), IERC20(address(wbnb)), IERC20(address(0)),
            ISmartRouterV3(address(router)), PAIR_FEE, 0
        );
        assertEq(address(noReward.reward()), address(0), "reward unset");
    }
}
