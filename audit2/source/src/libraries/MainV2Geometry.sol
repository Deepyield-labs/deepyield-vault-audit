// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/// @title MainV2Geometry
/// @notice Pure concentrated-liquidity geometry extracted from
/// `DedicatedVaultMainV2` so its heavy `TickMath`/`LiquidityAmounts` expansions
/// deploy once and link, instead of inlining into `Main` (EIP-170). These are the
/// exact computations that were internal to `Main` (B1-T4/B1-T5), moved verbatim —
/// no behavioural change. The `external` linkage is what removes the bytecode from
/// `Main`; the functions are `pure`, so the delegatecall carries no state risk.
/// @dev The error signatures match `DedicatedVaultMainV2`'s, so their selectors
/// are identical and existing `expectRevert(DedicatedVaultMainV2.X.selector)`
/// tests still match a revert originating here.
library MainV2Geometry {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error TwapOutsideTickRange();

    /// @notice USDT (18 dec) per 1e18 WBNB implied by a pool sqrtPriceX96. The
    /// pool is USDT(token0)/WBNB(token1), so price(token1/token0)=(sqrt/2^96)^2 is
    /// WBNB per USDT; its inverse, scaled by 1e18, is USDT per WBNB.
    function usdtPerWbnbFromSqrt(uint160 sqrtPriceX96) external pure returns (uint256) {
        uint256 tmp = FullMath.mulDiv(Q96, Q96, sqrtPriceX96); // 2^192 / sqrt
        return FullMath.mulDiv(tmp, 1e18, sqrtPriceX96); // (2^192/sqrt) * 1e18 / sqrt
    }

    /// @notice `expected` haircut by `lossBps`, floored at 1 so a two-sided leg
    /// never rounds its slippage guard to zero.
    function boundedLpMinimum(uint256 expected, uint16 lossBps) external pure returns (uint256) {
        if (expected == 0) return 0;
        uint256 minimum = FullMath.mulDiv(expected, BPS - lossBps, BPS);
        return minimum == 0 ? 1 : minimum;
    }

    /// @notice Amounts the mint would consume for `assetDesired`/`pairedDesired`
    /// evaluated at the TWAP price. Same geometry the venue previews, but anchored
    /// to TWAP rather than the current spot.
    function expectedMintAmountsAtTwap(
        uint256 assetDesired,
        uint256 pairedDesired,
        int24 tickLower,
        int24 tickUpper,
        uint160 twapSqrt
    ) external pure returns (uint256 assetExpected, uint256 pairedExpected) {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(twapSqrt, sqrtA, sqrtB, assetDesired, pairedDesired);
        (assetExpected, pairedExpected) = LiquidityAmounts.getAmountsForLiquidity(twapSqrt, sqrtA, sqrtB, liquidity);
    }

    /// @notice Validate the requested tick range against the TWAP sqrt price. The
    /// range must have a bounded width and strictly straddle the TWAP price, so a
    /// manipulated spot cannot steer the keeper into a degenerate or out-of-range
    /// mint. `minTickWidth`/`maxTickWidth`/`twapSqrt` are read in `Main` and passed
    /// in, keeping every state/oracle read on the caller side.
    function validateOpenTicks(
        int24 tickLower,
        int24 tickUpper,
        int24 minTickWidth,
        int24 maxTickWidth,
        uint160 twapSqrt
    ) external pure {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        int24 width = tickUpper - tickLower;
        if (width < minTickWidth || width > maxTickWidth) revert InvalidTickRange(tickLower, tickUpper);
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        if (twapSqrt <= sqrtLower || twapSqrt >= sqrtUpper) revert TwapOutsideTickRange();
    }
}
