// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAssetQuoter} from "./interfaces/IDedicatedVenue.sol";

/// @title ExcludeIdlePairedQuoter (Vault B NAV quoter — v1)
/// @notice Values idle paired (WBNB) at **zero** for user-facing NAV. This is the
/// provably-conservative v1: `0 ≤` whatever any close/swap path could realize, under any
/// price/fee/impact/staleness condition — so ERC-4626 share price / previews can NEVER be
/// overstated by un-realized idle WBNB. It is consistent with how CAKE is already excluded
/// from NAV until converted (`DedicatedVaultMain.convertIdleRewardToAsset`).
///
/// Rationale: in the normal Vault B flow idle WBNB is transient — `closePositionAndRealize`
/// converts WBNB→USDT atomically, and `convertIdlePairedToAsset` mops up any residual. The
/// only windows with idle WBNB are (a) post-close-before-realize and (b) emergency/stale
/// close; excluding it there understates NAV briefly (safe, favors correctness) rather than
/// risking an overstatement.
///
/// A TWAP-mid quoter was rejected for v1: a TWAP mid-price is NOT net-realizable (ignores
/// swap fee, price impact, and lags a fast WBNB drop), so it can exceed what a redeem would
/// realize. A future **v2** net-realizable quoter must prove `quote(amount) ≤ bounded swap
/// output` on a fork before it can value idle WBNB above zero. See
/// docs/audit/vault-b-production-wiring.md §4.
contract ExcludeIdlePairedQuoter is IAssetQuoter {
    /// @inheritdoc IAssetQuoter
    function quotePairedToAsset(uint256 /* pairedAmount */) external pure returns (uint256) {
        return 0; // conservative: idle paired excluded from NAV until converted to USDT
    }
}
