// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal subset of PancakeSwap V3 SmartRouter required by the
/// production swap adapter. Matches the on-chain SmartRouter ABI at
/// 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4 on BSC mainnet (Uniswap V3
/// style, no `deadline` field).
interface IPancakeSwapV3SmartRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Minimal subset of a PancakeSwap V3 pool used for view-friendly
/// quoting. Quoter V2 cannot be used from a Solidity `view` context because
/// its body executes a real swap callback that performs SSTOREs; under the
/// EVM's strict `staticcall` rules those SSTOREs revert (even though RPC-
/// level `eth_call` tolerates them). Reading `slot0()` directly works in any
/// view context and is exact-enough for the small swap sizes the vault
/// exercises against deep pools.
interface IPancakeV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint32 feeProtocol,
        bool unlocked
    );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);

    /// @notice Returns cumulative tick and liquidity values as of each
    /// timestamp `secondsAgo` from the current block timestamp. Used to
    /// derive a TWAP that is not flash-manipulable like slot0.
    ///
    /// Reverts if any `secondsAgo` falls outside the pool's observation
    /// buffer (i.e. the pool's `observationCardinality` does not cover the
    /// requested window). Callers must size the TWAP window or increase the
    /// pool's cardinality accordingly.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
