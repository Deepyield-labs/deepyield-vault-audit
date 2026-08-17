// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IVaultBPriceGuard {
    function POOL_FEE() external view returns (uint24);

    function minimumOut(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut);

    function minimumOutAndBudget(address tokenIn, address tokenOut, uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut, uint256 emergencyNotional, bool emergencyBudgetUsed);

    /// @notice One-snapshot policy for a staged LP decrease. The returned
    /// reference is the lower Chainlink/TWAP USDT value of one WBNB; the full
    /// notional uses an amount-specific quote from the upper source so capacity
    /// is not understated by unit-price rounding. An inactive, expired, or
    /// exhausted allocation selects normal policy without weakening oracle
    /// validation. This read-only staged-decrease policy does not itself debit
    /// the swap budget.
    function recoveryClosePolicy(uint256 assetExpected, uint256 pairedExpected)
        external
        view
        returns (uint256 referenceUsdtPerWbnb, uint256 fullNotional, uint16 selectedLossBps, bool emergencyBudgetUsed);

    function consumeEmergencyNotional(uint256 notional) external;

    function fairValue(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function twapSqrtPriceX96() external view returns (uint160);
}

interface IVaultBExecutionAdapterV2 {
    function main() external view returns (address);

    function priceGuard() external view returns (IVaultBPriceGuard);

    function swapAssetToPaired(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);

    function swapPairedToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);
}

interface IVaultBRewardPriceGuard {
    function DIRECT_ORACLE_FEE() external view returns (uint24);

    /// @notice Un-haircut CAKE liquidation data for Main's bounded chunk
    /// selection. This view neither reserves nor consumes emergency capacity.
    /// `fairNotional` is the conservative lower source; `capNotional` is the
    /// conservative upper source. `normalCapacity` is zero when the source
    /// spread needs the wider emergency deviation band. `emergencyCapacity`
    /// is the remaining active emergency allocation for an emergency request.
    function liquidationSnapshot(uint256 amountIn, bool requestedEmergency)
        external
        view
        returns (uint256 fairNotional, uint256 capNotional, uint256 normalCapacity, uint256 emergencyCapacity);

    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256 minOut);

    function minimumOutAndBudget(uint256 amountIn, bool emergency)
        external
        view
        returns (uint256 minOut, uint256 emergencyNotional, bool emergencyBudgetUsed);

    function consumeEmergencyNotional(uint256 notional) external;

    function fairValue(uint256 amountIn) external view returns (uint256 amountOut);
}

interface IVaultBRewardExecutionAdapterV2 {
    function main() external view returns (address);

    function priceGuard() external view returns (IVaultBRewardPriceGuard);

    function rewardToken() external view returns (address);

    function asset() external view returns (address);

    function swapRewardToAsset(uint256 amountIn, uint256 keeperMinOut, uint256 deadline, bool emergency)
        external
        returns (uint256 amountOut);
}

interface IPancakeV3SwapRouterWithDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
