// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ForkBlock
/// @notice Single source of truth + selector for the BSC fork used by every `*Fork`
/// test.
///
/// WHY A PIN. An unpinned `createSelectFork(rpcUrl("bsc"))` forks at the chain HEAD,
/// so the same commit yields different results run to run: real swaps and NFPM
/// liquidity mints execute against whatever pool tick is live, and a moved tick
/// trips the `Price slippage check`. Observed directly: the async-redeem fork test
/// returned PASS / PASS / FAIL across three consecutive head runs. Pinning a block
/// makes the forked state — and the result — reproducible.
///
/// WHY A SKIP. Pinning a historical block only works against an ARCHIVE node. The
/// default `bsc` endpoint (bsc-dataseed*.binance.org) is non-archive and serves only
/// a ~128-block (~90s) window; a fixed pin ages out of it within minutes. Forking a
/// pruned block there fails with a `missing trie node` EVM/database error that is
/// NOT catchable by Solidity try/catch (verified) — it aborts `setUp` hard, and a
/// permanently red suite is worse than a flapping one. So we DETECT the miss before
/// touching pruned state: fork the head first (always served), and if the pin is
/// older than the served window, `vm.skip` the whole suite with a clear reason
/// instead of crashing.
///
/// The three outcomes:
///   * archive RPC (BSC_FORK_RPC set)      -> pin selected, deterministic green run;
///   * non-archive default + a stale pin   -> suite SKIPPED cleanly (no false green,
///                                            no red noise);
///   * BSC_FORK_BLOCK=0                     -> head, for a live smoke run.
///
/// KNOBS: BSC_FORK_RPC (archive url; its presence is taken as "archive-capable"),
/// BSC_FORK_BLOCK (override the pin; 0 = head).
///
/// CHOSEN BLOCK: `DEFAULT_BSC` is a finalized BSC block at which the full LP/swap
/// traversal completes without tripping the slippage check. Any archive node serves
/// it; move it (one constant) if the pool/venue set changes, verifying green against
/// an archive RPC.
library ForkBlock {
    /// @dev Finalized BSC mainnet block used as the default fork pin.
    uint256 internal constant DEFAULT_BSC = 115509065;

    /// @dev Conservative bound (< the ~128-block non-archive window) beyond which a
    /// pin is assumed unserved by the default endpoint.
    uint256 internal constant NONARCHIVE_WINDOW = 100;

    /// @notice Select the pinned BSC fork, or skip the suite if the endpoint cannot
    /// serve the pinned block. Call at the top of a fork suite's `setUp`:
    ///   `if (!ForkBlock.selectBscFork(vm)) return;`
    /// Returns true when a fork is active and setUp should continue; false when the
    /// suite has been `vm.skip`-ped (the caller must return, leaving nothing to run).
    function selectBscFork(Vm vm) internal returns (bool) {
        string memory rpc = vm.envOr("BSC_FORK_RPC", vm.rpcUrl("bsc"));
        uint256 pin = vm.envOr("BSC_FORK_BLOCK", DEFAULT_BSC);

        // Live smoke (explicit) — accept head, non-deterministic by request.
        if (pin == 0) {
            vm.createSelectFork(rpc);
            return true;
        }
        // An explicit RPC is taken as archive-capable: pin directly.
        if (bytes(vm.envOr("BSC_FORK_RPC", string(""))).length != 0) {
            vm.createSelectFork(rpc, pin);
            return true;
        }
        // Default (non-archive) endpoint: head is always served. Fork it, and if the
        // pin is older than the served window, skip rather than crash on a state read.
        vm.createSelectFork(rpc);
        if (block.number > pin + NONARCHIVE_WINDOW) {
            emit SkippedNoArchive(pin, block.number);
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, pin);
        return true;
    }

    /// @dev Emitted (as a log) when a suite is skipped for want of an archive RPC.
    event SkippedNoArchive(uint256 pinnedBlock, uint256 servedHead);
}
