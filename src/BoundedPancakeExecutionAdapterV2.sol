// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IPancakeV3SwapRouterWithDeadline,
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard
} from "./interfaces/IVaultBExecutionV2.sol";

/// @notice Typed, direct-Pancake-only executor for canonical BSC USDT/WBNB.
/// It accepts no arbitrary calldata, recipient, router, token, fee or msg.value.
contract BoundedPancakeExecutionAdapterV2 is IVaultBExecutionAdapterV2 {
    using SafeERC20 for IERC20;

    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    uint24 public constant POOL_FEE = 100;

    address public immutable binder;
    address public main;
    IVaultBPriceGuard public immutable override priceGuard;
    uint32 public immutable maxDeadlineDelay;

    error WrongChain(uint256 actual);
    error ZeroAddress();
    error InvalidPriceGuard();
    error PoolFeeMismatch(uint24 adapterFee, uint24 guardFee);
    error NotBinder();
    error AlreadyBound();
    error InvalidMain();
    error NotMain();
    error InvalidAmount();
    error InvalidDeadline();
    error InputNotFullySpent(uint256 residual);
    error UnexpectedOutputBalance(uint256 beforeBalance, uint256 afterBalance);
    error RouterOutputMismatch(uint256 reported, uint256 observed);

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 keeperMinOut,
        uint256 guardMinOut,
        uint256 effectiveMinOut,
        bool emergency,
        bool emergencyBudgetUsed
    );

    event MainBound(address indexed main);

    constructor(address binder_, IVaultBPriceGuard priceGuard_, uint32 maxDeadlineDelay_) {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        if (binder_ == address(0) || address(priceGuard_) == address(0)) revert ZeroAddress();
        if (address(priceGuard_).code.length == 0) revert InvalidPriceGuard();
        uint24 guardFee = priceGuard_.POOL_FEE();
        if (guardFee != POOL_FEE) revert PoolFeeMismatch(POOL_FEE, guardFee);
        if (maxDeadlineDelay_ == 0 || maxDeadlineDelay_ > 600) revert InvalidDeadline();
        binder = binder_;
        priceGuard = priceGuard_;
        maxDeadlineDelay = maxDeadlineDelay_;
    }

    function bindMain(address main_) external {
        // Intentionally one-shot. A bad pre-deployment binding is recovered by
        // redeploying this small adapter; runtime rotation would create a larger
        // authority surface over funds approved by Main.
        if (msg.sender != binder) revert NotBinder();
        if (main != address(0)) revert AlreadyBound();
        if (main_ == address(0) || main_.code.length == 0) revert InvalidMain();
        main = main_;
        emit MainBound(main_);
    }

    modifier onlyMain() {
        if (msg.sender != main) revert NotMain();
        _;
    }

    function swapAssetToPaired(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        onlyMain
        returns (uint256 amountOut)
    {
        return _swap(USDT, WBNB, amountIn, keeperMinOut, deadline, emergency);
    }

    function swapPairedToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        onlyMain
        returns (uint256 amountOut)
    {
        return _swap(WBNB, USDT, amountIn, keeperMinOut, deadline, emergency);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 keeperMinOut,
        uint256 deadline,
        bool emergency
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (deadline < block.timestamp || deadline > block.timestamp + maxDeadlineDelay) {
            revert InvalidDeadline();
        }

        (uint256 guardMinOut, uint256 emergencyNotional, bool emergencyBudgetUsed) =
            priceGuard.minimumOutAndBudget(tokenIn, tokenOut, amountIn, emergency);
        uint256 effectiveMinOut = keeperMinOut > guardMinOut ? keeperMinOut : guardMinOut;

        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 adapterInputBefore = input.balanceOf(address(this));
        uint256 adapterOutputBefore = output.balanceOf(address(this));
        uint256 mainOutputBefore = output.balanceOf(main);

        input.safeTransferFrom(main, address(this), amountIn);
        input.forceApprove(PANCAKE_V3_SWAP_ROUTER, amountIn);
        uint256 reportedOut = IPancakeV3SwapRouterWithDeadline(PANCAKE_V3_SWAP_ROUTER)
            .exactInputSingle(
                IPancakeV3SwapRouterWithDeadline.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: main,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: effectiveMinOut,
                sqrtPriceLimitX96: 0
            })
            );
        input.forceApprove(PANCAKE_V3_SWAP_ROUTER, 0);

        // Exact equality is deliberate for the fixed BSC USDT/WBNB pair. Both
        // deployed tokens were verified non-rebasing and non-fee-on-transfer;
        // relaxing this would hide real router/accounting mismatches.
        uint256 adapterInputAfter = input.balanceOf(address(this));
        if (adapterInputAfter != adapterInputBefore) {
            revert InputNotFullySpent(adapterInputAfter - adapterInputBefore);
        }
        uint256 adapterOutputAfter = output.balanceOf(address(this));
        if (adapterOutputAfter != adapterOutputBefore) {
            revert UnexpectedOutputBalance(adapterOutputBefore, adapterOutputAfter);
        }

        amountOut = output.balanceOf(main) - mainOutputBefore;
        if (amountOut != reportedOut) revert RouterOutputMismatch(reportedOut, amountOut);
        if (amountOut < effectiveMinOut) revert RouterOutputMismatch(effectiveMinOut, amountOut);

        if (emergencyBudgetUsed) priceGuard.consumeEmergencyNotional(emergencyNotional);

        emit SwapExecuted(
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            keeperMinOut,
            guardMinOut,
            effectiveMinOut,
            emergency,
            emergencyBudgetUsed
        );
    }
}
