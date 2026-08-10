// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IPancakeV3SwapRouterWithDeadline,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "./interfaces/IVaultBExecutionV2.sol";

/// @notice Typed direct-Pancake executor for canonical BSC CAKE-to-USDT.
/// No token, route, fee, recipient, calldata or native value is keeper-controlled.
contract BoundedPancakeRewardAdapterV2 is IVaultBRewardExecutionAdapterV2 {
    using SafeERC20 for IERC20;

    address public constant override rewardToken = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant override asset = 0x55d398326f99059fF775485246999027B3197955;
    address public constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    uint24 public constant POOL_FEE = 2_500;

    address public immutable binder;
    address public override main;
    IVaultBRewardPriceGuard public immutable override priceGuard;
    uint32 public immutable maxDeadlineDelay;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error NotBinder();
    error AlreadyBound();
    error InvalidMain();
    error NotMain();
    error InvalidAmount();
    error InvalidDeadline();
    error InputNotFullySpent(uint256 residual);
    error UnexpectedOutputBalance(uint256 beforeBalance, uint256 afterBalance);
    error RouterOutputMismatch(uint256 reported, uint256 observed);

    event RewardSwapExecuted(
        uint256 amountIn,
        uint256 amountOut,
        uint256 keeperMinOut,
        uint256 guardMinOut,
        uint256 effectiveMinOut,
        bool emergency
    );
    event MainBound(address indexed main);

    constructor(address binder_, IVaultBRewardPriceGuard priceGuard_, uint32 maxDeadlineDelay_) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (binder_ == address(0) || address(priceGuard_) == address(0)) revert ZeroAddress();
        if (maxDeadlineDelay_ == 0 || maxDeadlineDelay_ > 600) revert InvalidDeadline();
        binder = binder_;
        priceGuard = priceGuard_;
        maxDeadlineDelay = maxDeadlineDelay_;
    }

    function bindMain(address main_) external {
        if (msg.sender != binder) revert NotBinder();
        if (main != address(0)) revert AlreadyBound();
        if (main_ == address(0) || main_.code.length == 0) revert InvalidMain();
        main = main_;
        emit MainBound(main_);
    }

    function swapRewardToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != main) revert NotMain();
        if (amountIn == 0) revert InvalidAmount();
        if (deadline < block.timestamp || deadline > block.timestamp + maxDeadlineDelay) revert InvalidDeadline();

        uint256 guardMinOut = priceGuard.minimumOut(amountIn, emergency);
        uint256 effectiveMinOut = keeperMinOut > guardMinOut ? keeperMinOut : guardMinOut;

        IERC20 input = IERC20(rewardToken);
        IERC20 output = IERC20(asset);
        uint256 adapterInputBefore = input.balanceOf(address(this));
        uint256 adapterOutputBefore = output.balanceOf(address(this));
        uint256 mainOutputBefore = output.balanceOf(main);

        input.safeTransferFrom(main, address(this), amountIn);
        input.forceApprove(PANCAKE_V3_SWAP_ROUTER, amountIn);
        uint256 reportedOut = IPancakeV3SwapRouterWithDeadline(PANCAKE_V3_SWAP_ROUTER)
            .exactInputSingle(
                IPancakeV3SwapRouterWithDeadline.ExactInputSingleParams({
                tokenIn: rewardToken,
                tokenOut: asset,
                fee: POOL_FEE,
                recipient: main,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: effectiveMinOut,
                sqrtPriceLimitX96: 0
            })
            );
        input.forceApprove(PANCAKE_V3_SWAP_ROUTER, 0);

        uint256 adapterInputAfter = input.balanceOf(address(this));
        if (adapterInputAfter != adapterInputBefore) revert InputNotFullySpent(adapterInputAfter - adapterInputBefore);
        uint256 adapterOutputAfter = output.balanceOf(address(this));
        if (adapterOutputAfter != adapterOutputBefore) {
            revert UnexpectedOutputBalance(adapterOutputBefore, adapterOutputAfter);
        }

        amountOut = output.balanceOf(main) - mainOutputBefore;
        if (amountOut != reportedOut) revert RouterOutputMismatch(reportedOut, amountOut);
        if (amountOut < effectiveMinOut) revert RouterOutputMismatch(effectiveMinOut, amountOut);

        emit RewardSwapExecuted(amountIn, amountOut, keeperMinOut, guardMinOut, effectiveMinOut, emergency);
    }
}
