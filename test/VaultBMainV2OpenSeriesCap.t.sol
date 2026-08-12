// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice B9-T1 — the aggregate open bound. Before this fix `canaryOpenCap` was
/// checked against a PER-JOB accumulator, so switching jobId reset it and the vault
/// could swap several multiples of the cap into WBNB with no violation. The fix is
/// a single global active open series (`activeOpenJobId`): the first chunk fixes
/// the series, any other jobId is refused until the series is minted or cancelled,
/// and a cancel is allowed only once the paired inventory is drained to dust.
/// Chunk indices are also forced consecutive from zero.
contract VaultBMainV2OpenSeriesCapTest is VaultBMainV2Test {
    function _mint(bytes32 jobId, uint256 assetBudget) internal returns (uint256) {
        vm.prank(keeper);
        return main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: jobId,
                tickLower: -100,
                tickUpper: 100,
                assetBudget: assetBudget,
                swapAssetIn: 0,
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
    }

    // (#1) A second jobId cannot start while a series is live — this is what blocks
    //      the 5×-cap bypass. With canaryOpenCap == per-chunk cap == 300, one series
    //      swaps 300; a second jobId reverts OpenSeriesActive, so the vault never
    //      accumulates beyond the cap.
    function testSecondJobIdCannotBypassCap() public {
        vm.prank(admin);
        main.setOperationalCaps(600e18, 300e18, 100_000e18);
        _fund(5_000e18);

        // B11-T1: budget must exceed the swap leg; reserve budget 500, swap leg 300.
        _reserve(keccak256("series-1"), 500e18, 300e18);
        vm.prank(keeper);
        main.openSwapChunk(keccak256("series-1"), 0, 300e18, 1, block.timestamp + 60);
        assertEq(wbnb.balanceOf(address(main)), 300e18, "one cap worth accumulated");
        assertEq(main.activeOpenJobId(), keccak256("series-1"), "series is locked to job 1");

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.OpenSeriesActive.selector);
        main.openSwapChunk(keccak256("series-2"), 0, 300e18, 1, block.timestamp + 60);

        assertEq(wbnb.balanceOf(address(main)), 300e18, "second series never swapped");
    }

    // (#2) An aborted series can be released, but ONLY after its inventory is drained
    //      — otherwise cancel would itself be a bypass (swap to cap, cancel, repeat).
    function testCancelRequiresDrainedInventoryThenReleasesLock() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 100_000e18);
        _fund(5_000e18);

        bytes32 aborted = keccak256("aborted");
        _reserve(aborted, 1_000e18);
        vm.prank(keeper);
        main.openSwapChunk(aborted, 0, 300e18, 1, block.timestamp + 60); // 300 WBNB, no mint

        // Cancel with inventory still present reverts.
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.InventoryPresent.selector);
        main.cancelOpenSeries(aborted);

        // Drain the accumulated WBNB via a liquidation job, then cancel succeeds.
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("drain"), 0, 1, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0, "inventory drained");

        vm.prank(keeper);
        main.cancelOpenSeries(aborted);
        assertEq(main.activeOpenJobId(), bytes32(0), "lock released after drained cancel");

        // A fresh series can now start (the reserved context cleared with the cancel).
        _reserve(keccak256("after-cancel"), 1_000e18);
        vm.prank(keeper);
        main.openSwapChunk(keccak256("after-cancel"), 0, 300e18, 1, block.timestamp + 60);
        assertEq(main.activeOpenJobId(), keccak256("after-cancel"), "new series accepted");
    }

    // (#3) Chunk indices must be consecutive from zero: a sparse first index reverts;
    //      0,1,2 pass; replaying a used index reverts DuplicateChunk (not sequential).
    function testChunkIndicesMustBeConsecutive() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 100_000e18);
        _fund(5_000e18);

        // A sparse first index (7) is rejected.
        _reserve(keccak256("sparse"), 1_000e18);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.NonSequentialChunk.selector);
        main.openSwapChunk(keccak256("sparse"), 7, 300e18, 1, block.timestamp + 60);
        // The sparse chunk reverted with no inventory accumulated; release the reserved
        // series so a fresh one can start (B11-T1: a reservation must be cancelled).
        vm.prank(keeper);
        main.cancelOpenSeries(keccak256("sparse"));

        // 0,1,2 consecutive on one series succeed (300*3 = 900 <= canaryOpenCap 1000).
        bytes32 seq = keccak256("seq");
        _reserve(seq, 1_000e18, 950e18); // B11-T1: swap leg 950 (< budget); series swaps 900
        vm.prank(keeper);
        main.openSwapChunk(seq, 0, 300e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        main.openSwapChunk(seq, 1, 300e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        main.openSwapChunk(seq, 2, 300e18, 1, block.timestamp + 60);

        // Replaying index 2 reverts DuplicateChunk (the duplicate guard precedes the
        // sequential one), not NonSequentialChunk.
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.DuplicateChunk.selector);
        main.openSwapChunk(seq, 2, 300e18, 1, block.timestamp + 60);
    }

    // (#5-regression) A normal single-series open still mints and clears the lock.
    function testNormalSingleSeriesOpenStillWorks() public {
        _fund(2_000e18);
        uint256 id = _open(keccak256("normal"));
        assertGt(id, 0, "position opened");
        assertEq(main.activeOpenJobId(), bytes32(0), "lock cleared after mint");
    }
}
