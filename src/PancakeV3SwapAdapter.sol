// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPairedSwapper, IRewardSwapper, IPairedSwapIn} from "./interfaces/IDedicatedVenue.sol";

/// @dev Minimal PancakeSwap V3 SmartRouter surface.
interface ISmartRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut);
}

/// @title PancakeV3SwapAdapter (PROTOTYPE)
/// @notice Bounded, caller-only swap adapter for Vault B's three legs:
///   USDT→WBNB (swap-in, two-sided mint), WBNB→USDT and CAKE→USDT (close realization).
/// Replaces the `DepositPathUnsupported` stub. Every swap pulls input from `msg.sender`
/// and routes output (recipient) BACK to `msg.sender` — NO arbitrary recipient. `minOut`
/// + `deadline` are passed straight to the router (which reverts on violation). Only the
/// configured token pairs/fees are swappable; anything else reverts in the router.
contract PancakeV3SwapAdapter is IPairedSwapper, IRewardSwapper, IPairedSwapIn {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;     // USDT
    IERC20 public immutable paired;    // WBNB
    IERC20 public immutable reward;    // CAKE (may be 0 if unused)
    ISmartRouterV3 public immutable router;
    uint24 public immutable pairFee;   // USDT/WBNB fee tier
    uint24 public immutable rewardFee; // CAKE/USDT fee tier

    error ZeroMinOut();
    error RewardUnconfigured();
    error ZeroAddress();
    error AssetEqualsPaired();
    error ZeroPairFee();
    error RewardEqualsAsset();
    error RewardEqualsPaired();
    error ZeroRewardFee();

    constructor(IERC20 asset_, IERC20 paired_, IERC20 reward_, ISmartRouterV3 router_, uint24 pairFee_, uint24 rewardFee_) {
        if (address(asset_) == address(0) || address(paired_) == address(0) || address(router_) == address(0)) revert ZeroAddress();
        if (address(asset_) == address(paired_)) revert AssetEqualsPaired();
        if (pairFee_ == 0) revert ZeroPairFee();
        // reward == 0 allowed ONLY for deployments that never call swapRewardToAsset.
        if (address(reward_) != address(0)) {
            if (address(reward_) == address(asset_)) revert RewardEqualsAsset();
            if (address(reward_) == address(paired_)) revert RewardEqualsPaired();
            if (rewardFee_ == 0) revert ZeroRewardFee();
        }
        asset = asset_; paired = paired_; reward = reward_; router = router_;
        pairFee = pairFee_; rewardFee = rewardFee_;
    }

    function _swap(IERC20 tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal returns (uint256 out)
    {
        if (minOut == 0) revert ZeroMinOut(); // bounded: no zero-min normal path
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.forceApprove(address(router), amountIn);
        out = router.exactInputSingle(ISmartRouterV3.ExactInputSingleParams({
            tokenIn: address(tokenIn), tokenOut: tokenOut, fee: fee,
            recipient: msg.sender,              // output goes straight to the caller — never a third party
            deadline: deadline, amountIn: amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0
        }));
        tokenIn.forceApprove(address(router), 0);
    }

    function swapPairedToAsset(uint256 pairedAmount, uint256 minOut, uint256 deadline) external returns (uint256) {
        return _swap(paired, address(asset), pairFee, pairedAmount, minOut, deadline);
    }

    function swapAssetToPaired(uint256 assetAmount, uint256 minOut, uint256 deadline) external returns (uint256) {
        return _swap(asset, address(paired), pairFee, assetAmount, minOut, deadline);
    }

    function swapRewardToAsset(uint256 rewardAmount, uint256 minOut, uint256 deadline) external returns (uint256) {
        if (address(reward) == address(0)) revert RewardUnconfigured();
        return _swap(reward, address(asset), rewardFee, rewardAmount, minOut, deadline);
    }
}
