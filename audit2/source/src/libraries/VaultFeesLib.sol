// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library VaultFeesLib {
    uint256 internal constant MAX_BPS = 10_000;

    function performanceFee(uint256 profit, uint256 feeBps) internal pure returns (uint256) {
        if (profit == 0 || feeBps == 0) return 0;
        require(feeBps <= MAX_BPS, "fee too high");
        return (profit * feeBps) / MAX_BPS;
    }

    function sharesForAssets(uint256 feeAssets, uint256 totalSupply, uint256 totalAssets)
        internal
        pure
        returns (uint256)
    {
        if (feeAssets == 0) return 0;
        if (totalSupply == 0 || totalAssets == 0) return feeAssets;
        return (feeAssets * totalSupply) / totalAssets;
    }
}
