// SPDX-License-Identifier: MIT
pragma solidity =0.8.24 >=0.4.16;

// src/interfaces/IDeepYieldStrategy.sol

interface IDeepYieldStrategy {
    function deploy(uint256 assets) external;
    function withdrawToVault(uint256 assetsNeeded) external returns (uint256 withdrawn);
    function managerWithdrawAll() external returns (uint256 withdrawn);
    function harvest() external returns (uint256 profit, uint256 feeAssets);
    function panic() external;
    function estimatedTotalAssets() external view returns (uint256);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// src/interfaces/IVaultBAsyncStrategy.sol

/// @notice Vault B strategy surface for synchronous ERC-4626 liquidity and
/// explicit asynchronous redeem requests.
interface IVaultBAsyncStrategy is IDeepYieldStrategy {
    function asset() external view returns (IERC20);
    function vault() external view returns (address);

    /// @notice Address that directly holds the strategy's deposit-time asset
    /// backing. The vault pins this address when the strategy is activated and
    /// reads the ERC20 balance itself as an independent NAV floor.
    function depositAssetSource() external view returns (address);

    /// @notice Deposit-conservative estimate of strategy assets (B10-T2): the
    /// upper (max TWAP/spot geometry) counterpart of `estimatedTotalAssets`, net of
    /// pending performance fee. The vault prices deposits/mints on this so a spot
    /// manipulation cannot under-value NAV; redemptions keep using the lower
    /// `estimatedTotalAssets`.
    function estimatedTotalAssetsUpper() external view returns (uint256);

    /// @dev `assetsHint` is observability only. The queued shares remain exposed
    /// to NAV until claim, so settlement uses the claim-time amount.
    function requestWithdrawal(bytes32 requestId, uint256 assetsHint) external;

    function commitWithdrawalCycle() external;

    function claimWithdrawal(bytes32 requestId, uint256 assetsNeeded) external returns (uint256 withdrawn);

    function cancelWithdrawal(bytes32 requestId) external;

    function withdrawalReady(bytes32 requestId) external view returns (bool);
    function withdrawalCycleCommitted() external view returns (bool);
    function withdrawalCycleBatchCommitted() external view returns (bool);
    /// @notice Gross fair-value execution loss. Used for the immutable loss cap
    /// and protocol observability.
    function withdrawalCycleExecutionLoss() external view returns (uint256);
    /// @notice Shareholder loss attributable to execution after accounting for
    /// the reduction in pending performance-fee liability caused by that loss.
    function withdrawalCycleChargeableExecutionLoss() external view returns (uint256);
    function availableWithdrawLimit() external view returns (uint256);
    function depositsAllowed() external view returns (bool);
}

// src/libraries/VaultBDepositLib.sol

interface IVaultBDirectWithdrawalCancellation {
    function cancelWithdrawalFromVault(bytes32 requestId) external returns (bool canceled);
}

interface IVaultBDirectForceSettlement {
    function forceClearWithdrawalFromVault(bytes32 requestId) external returns (bool cleared);
}

/// @notice Stateless strategy checks and recovery dispatch kept outside Vault B's
/// runtime bytecode. No library function writes Vault storage.
library VaultBDepositLib {
    error StrategyWiringMismatch();
    error InvalidStrategyAssetSource();

    function cancelWithdrawal(IVaultBAsyncStrategy strategy, address assetSource, bytes32 requestId) external {
        try strategy.cancelWithdrawal(requestId) {}
        catch {
            try IVaultBDirectWithdrawalCancellation(assetSource).cancelWithdrawalFromVault(requestId) returns (
                bool canceled
            ) {
                if (canceled) return;
            } catch {}
            bool cleared = IVaultBDirectForceSettlement(assetSource).forceClearWithdrawalFromVault(requestId);
            if (!cleared) revert StrategyWiringMismatch();
        }
    }

    /// @notice F4 (Audit 2 delta): failure-tolerant handle release for a FORCE-SETTLED
    /// claim, whose payout is already fully covered by known idle and is therefore
    /// independent of the canonical strategy/Main handle. Same three-tier dispatch as
    /// {cancelWithdrawal}, but returns `false` instead of reverting when every tier
    /// fails, so one un-releasable handle can never freeze the whole vault by bricking a
    /// single `claimRedeem`. Safe because the receiver is paid from idle, not from this
    /// handle: a handle later honored by Main returns assets to the vault's idle pool as
    /// shareholder value — never a second payout to the already-paid receiver. The caller
    /// records the orphaned handle for the admin escape hatch to retry once the strategy
    /// or Main endpoint recovers.
    function cancelWithdrawalTolerant(IVaultBAsyncStrategy strategy, address assetSource, bytes32 requestId)
        external
        returns (bool released)
    {
        try strategy.cancelWithdrawal(requestId) {
            return true;
        } catch {
            try IVaultBDirectWithdrawalCancellation(assetSource).cancelWithdrawalFromVault(requestId) returns (
                bool canceled
            ) {
                if (canceled) return true;
            } catch {}
            try IVaultBDirectForceSettlement(assetSource).forceClearWithdrawalFromVault(requestId) returns (
                bool cleared
            ) {
                return cleared;
            } catch {
                return false;
            }
        }
    }

    /// @notice Canonical journal release after Vault has fixed a zero-asset
    /// force payout. The immutable Main accepts it only from the configured
    /// root Vault while that Vault exposes its force-settled flag. Failure must
    /// revert the whole claim: local settlement may not outrun Main's journal.
    function forceClearWithdrawal(address assetSource, bytes32 requestId) external {
        bool cleared = IVaultBDirectForceSettlement(assetSource).forceClearWithdrawalFromVault(requestId);
        if (!cleared) revert StrategyWiringMismatch();
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
        // A Vault without its first strategy has no attested deployment graph
        // behind it. This is an unconditional admission gate: neither an
        // admin cap update nor an unpause may make ERC-4626 deposit/mint live
        // before strategy installation. Direct ERC-20 donations remain assets
        // (and therefore keep the immediate bootstrap `VaultNotEmpty` gate
        // closed), but they never create shares through this path.
        if (blocked || address(strategy) == address(0)) return 0;

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
