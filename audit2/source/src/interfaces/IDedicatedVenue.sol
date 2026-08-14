// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal venue abstraction for the dedicated-vault prototype. In
/// production this is implemented by a PancakeSwap-V3 + MasterchefV3 integration
/// (mint/stake/decrease/collect/burn). For the no-funds prototype a mock
/// implements it so the SECURITY MODEL (roles, vault-only egress, lifecycle,
/// NAV, stale-close) is provable deterministically.
///
/// Invariant the venue MUST honour: `open` pulls idle asset from the caller (the
/// Main) and `close`/`harvest` return ALL managed proceeds (asset, paired, AND
/// reward token) back to the Main. Managed protocol assets never reach a third
/// party; an implementation may separately rescue unrelated accidental tokens.
///
/// Slippage/deadline are explicit on open/close (no zero-min in normal paths);
/// emergency paths may pass 0 with documented emergency semantics.
interface IDedicatedVenue {
    /// @dev Two-sided open args. The Main pre-swaps USDT→WBNB and approves BOTH legs, then
    /// calls open(). The single-sided open was removed — a proven fork finding
    /// (test/VaultBLifecycleFork.t.sol) shows single-sided in-range mint reverts, so a
    /// single-arg open could not mint the intended in-range LP. (Struct groups the open
    /// inputs for call-site clarity; the two-sided open path requires `via_ir` — see
    /// foundry.toml.)
    struct OpenArgs {
        uint256 assetAmount;
        uint256 pairedAmount;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function open(OpenArgs calldata a) external returns (uint256 positionId);

    function close(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external;

    /// @dev Collect fees/rewards for `positionId` to the caller (asset terms returned).
    function harvest(uint256 positionId) external returns (uint256 assetCollected);

    /// @dev Current-SPOT value simulation of the active `positionId` in asset
    /// units. This raw Venue view is not an oracle: value-bearing consumers must
    /// independently validate/anchor the pool price before relying on it.
    function positionValueAsset(uint256 positionId) external view returns (uint256);
}

/// @notice V2 extension used by MainV2 to derive close minima from the LP's
/// current execution geometry. Raw previews are spot simulations, not oracles;
/// MainV2 validates spot/TWAP/oracle coherence around value-bearing actions. A
/// leg may legitimately be zero when the position is fully out of range; that
/// fact comes from this on-chain preview, never the keeper.
interface IDedicatedVenueV2 is IDedicatedVenue {
    function controller() external view returns (address);

    function asset() external view returns (IERC20);

    function paired() external view returns (IERC20);

    function fee() external view returns (uint24);

    function poolAddress() external view returns (address);

    function forceUnstakeSkipHarvest(uint256 positionId) external;

    function previewOpenAmounts(uint256 assetDesired, uint256 pairedDesired, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);

    function previewCloseAmounts(uint256 positionId)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);

    /// @dev Simulation at a caller-supplied, valid-domain V3 price. The Venue
    /// does not authenticate that price; the consumer must validate its source.
    function previewCloseAmountsAtSqrtPrice(uint256 positionId, uint160 sqrtPriceX96)
        external
        view
        returns (uint256 assetExpected, uint256 pairedExpected);
}

/// @notice Conservative paired(WBNB)→asset(USDT) quote (never above realizable).
interface IAssetQuoter {
    function quotePairedToAsset(uint256 pairedAmount) external view returns (uint256 assetAmount);
}

/// @notice Bounded paired(WBNB)→asset(USDT) swap. Pulls `pairedAmount` from the
/// caller, returns ≥ `minOut` asset TO the caller. Destination is always the
/// caller — no arbitrary recipient.
interface IPairedSwapper {
    function swapPairedToAsset(uint256 pairedAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 assetOut);
}

/// @notice Bounded reward(CAKE)→asset(USDT) swap. Pulls `rewardAmount` from the
/// caller, returns ≥ `minOut` asset TO the caller. Caller-only destination.
interface IRewardSwapper {
    function swapRewardToAsset(uint256 rewardAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 assetOut);
}

/// @notice Bounded asset(USDT)→paired(WBNB) swap-in for two-sided mint. Pulls
/// `assetAmount` from the caller, returns ≥ `minOut` paired TO the caller.
interface IPairedSwapIn {
    function swapAssetToPaired(uint256 assetAmount, uint256 minOut, uint256 deadline)
        external
        returns (uint256 pairedOut);
}
