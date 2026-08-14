// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultBAsyncStrategy} from "../interfaces/IVaultBAsyncStrategy.sol";

interface IVaultBDirectWithdrawalCancellation {
    function cancelWithdrawalFromVault(bytes32 requestId) external returns (bool canceled);
}

/// @notice Stateless strategy checks and recovery dispatch kept outside Vault B's
/// runtime bytecode. No library function writes Vault storage.
library VaultBDepositLib {
    error StrategyWiringMismatch();
    error InvalidStrategyAssetSource();

    function cancelWithdrawal(IVaultBAsyncStrategy strategy, address assetSource, bytes32 requestId) external {
        try strategy.cancelWithdrawal(requestId) {}
        catch {
            bool canceled = IVaultBDirectWithdrawalCancellation(assetSource).cancelWithdrawalFromVault(requestId);
            if (!canceled) revert StrategyWiringMismatch();
        }
    }

    function validateCandidate(IVaultBAsyncStrategy candidate, address expectedAsset, address expectedVault)
        external
        view
        returns (address source)
    {
        if (address(candidate.asset()) != expectedAsset || candidate.vault() != expectedVault) {
            revert StrategyWiringMismatch();
        }
        source = candidate.depositAssetSource();
        if (source == address(0) || source == expectedVault || source.code.length == 0) {
            revert InvalidStrategyAssetSource();
        }
    }

    function totalAssetsUpper(
        IERC20 asset,
        address vault,
        IVaultBAsyncStrategy strategy,
        address assetSource,
        uint256 claimableAssets
    ) external view returns (uint256) {
        uint256 idle = asset.balanceOf(vault);
        uint256 deployed;
        if (address(strategy) != address(0)) {
            deployed = strategy.estimatedTotalAssetsUpper();
            uint256 directBacking = asset.balanceOf(assetSource);
            if (directBacking > deployed) deployed = directBacking;
        }
        return idle + deployed - claimableAssets;
    }

    function maxDepositStrict(
        IERC20 asset,
        address vault,
        IVaultBAsyncStrategy strategy,
        address assetSource,
        bool blocked,
        uint256 supply,
        uint256 depositCap,
        uint256 claimableAssets
    ) external view returns (uint256) {
        if (blocked) return 0;

        uint256 deployedUpper;
        uint256 deployedLower;
        if (address(strategy) != address(0)) {
            if (strategy.withdrawalCycleCommitted() || !strategy.depositsAllowed()) return 0;
            deployedUpper = strategy.estimatedTotalAssetsUpper();
            uint256 directBacking = asset.balanceOf(assetSource);
            if (directBacking > deployedUpper) deployedUpper = directBacking;
            deployedLower = strategy.estimatedTotalAssets();
        }

        uint256 idle = asset.balanceOf(vault);
        if (supply != 0 && idle + deployedLower - claimableAssets == 0) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 managed = idle + deployedUpper - claimableAssets;
        return managed >= depositCap ? 0 : depositCap - managed;
    }
}
