// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TickMath} from "./TickMath.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";
import {FullMath} from "./FullMath.sol";

/// @title V3PositionValuer — conservative on-chain USDT value of a Pancake/Uniswap V3 position.
/// @notice Composes audited primitives only:
///   - `TickMath.getSqrtRatioAtTick` (already in repo, used by the router adapter),
///   - canonical `LiquidityAmounts.getAmountsForLiquidity`,
///   - audited `FullMath.mulDiv`.
/// No novel/hand-rolled crypto math. Assumes asset == token0 (USDT) and paired == token1
/// (WBNB) — the live 0.01% pool ordering (token0=USDT, token1=WBNB), both 18 decimals.
/// All conversions truncate DOWN (FullMath.mulDiv) ⇒ conservative (never overstates NAV).
library V3PositionValuer {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev (amount0, amount1) currently held by `liquidity` at `sqrtPriceX96`.
    function amounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal pure returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    /// @dev Value `amount1` (token1/WBNB) in token0 (USDT) at `sqrtPriceX96`, floored.
    /// token0-per-token1 = (Q96 / sqrtP)^2, applied via two flooring mulDivs (conservative).
    function token1ToToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount1 == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(amount1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// @dev Conservative USDT (token0) value of a position: liquidity-implied amounts +
    /// fees owed, with the WBNB side floored into USDT at the current price.
    function valueInAssetToken0(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal pure returns (uint256 valueToken0) {
        (uint256 a0, uint256 a1) = amounts(sqrtPriceX96, tickLower, tickUpper, liquidity);
        uint256 total1 = a1 + tokensOwed1;
        valueToken0 = a0 + tokensOwed0 + token1ToToken0(total1, sqrtPriceX96);
    }
}
