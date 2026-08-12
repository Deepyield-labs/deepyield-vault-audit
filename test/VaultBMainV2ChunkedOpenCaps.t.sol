// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice B8-T1 (variant C) — chunked open cap semantics.
///
/// openPosition was split into a chunkable swap phase (openSwapChunk) plus a
/// single-tx mint (openPosition). The swap cap `swapPerJobCap` now bounds THIS
/// CHUNK (a leg larger than the per-tx cap is filled as a series of capped
/// chunks), while the day's turnover still accumulates across all chunks and the
/// position-size ceiling `canaryOpenCap` bounds the running SUM of USDT swapped,
/// checked incrementally BEFORE each swap moves funds — not only at the mint.
///
/// The liquidation path (`reserveSwapNotional`, per-JOB cumulative cap + slicing)
/// is deliberately left byte-for-byte unchanged; the final test is a regression
/// pinning that divergence.
contract VaultBMainV2ChunkedOpenCapsTest is VaultBMainV2Test {
    // Helper: single mint from whatever the swap chunks accumulated for `jobId`.
    function _mint(bytes32 jobId, uint256 assetBudget) internal returns (uint256) {
        vm.prank(keeper);
        return main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: jobId,
                tickLower: -100,
                tickUpper: 100,
                assetBudget: assetBudget,
                swapAssetIn: 0, // unused in phase 2
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
    }

    // (1) A swap leg larger than swapPerJobCap, filled as a SERIES of chunks each
    //     within the per-chunk cap, accumulates and mints. Under the pre-(C)
    //     per-JOB-sum cap the second chunk would have reverted SwapCapExceeded.
    function testSwapLegExceedingPerChunkCapMintsViaSeries() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18); // open, perChunk, daily
        _fund(2_000e18);

        bytes32 jobId = keccak256("series-open");
        _reserve(jobId, 1_000e18, 700e18); // B11-T1: swap leg 700 (< budget); this series swaps 600
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 300e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        main.openSwapChunk(jobId, 1, 300e18, 1, block.timestamp + 60); // sum 600 > per-chunk 300

        uint256 positionId = _mint(jobId, 1_000e18); // mint leg 400 = 1_000 - 600 swapped
        assertGt(positionId, 0, "series of capped chunks mints");
        assertEq(main.activePositionId(), positionId, "position active after series mint");
    }

    // (2) A SINGLE chunk above the per-chunk cap reverts — the cap still bites,
    //     just per-chunk instead of per-job-sum.
    function testSingleChunkAbovePerChunkCapReverts() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18);
        _fund(2_000e18);

        bytes32 jobId = keccak256("big-chunk");
        _reserve(jobId, 1_000e18); // budget bounds the leg; the per-chunk cap still bites
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapCapExceeded.selector);
        main.openSwapChunk(jobId, 0, 400e18, 1, block.timestamp + 60); // 400 > 300
    }

    // (3) The running SUM of swapped USDT is bounded by canaryOpenCap, enforced on
    //     the OVERFLOWING chunk (before it swaps), not deferred to the mint.
    function testSeriesExceedingCanaryOpenCapRevertsOnOverflowingChunk() public {
        vm.prank(admin);
        main.setOperationalCaps(500e18, 400e18, 2_000e18); // open 500, perChunk 400
        _fund(2_000e18);

        bytes32 jobId = keccak256("cap-overflow");
        _reserve(jobId, 500e18, 450e18); // B11-T1: swap leg 450 (< budget 500); series swaps 400 then over
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 400e18, 1, block.timestamp + 60); // cum 400 <= 500 ok

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
        main.openSwapChunk(jobId, 1, 200e18, 1, block.timestamp + 60); // cum 600 > 500 -> revert here
    }

    // (4) The daily swap limit accumulates across ALL chunks of the series.
    function testDailyLimitAccumulatesAcrossChunks() public {
        vm.prank(admin);
        main.setOperationalCaps(2_000e18, 400e18, 600e18); // open 2000, perChunk 400, daily 600
        _fund(2_000e18);

        bytes32 jobId = keccak256("daily-accum");
        _reserve(jobId, 2_000e18); // budget high enough that the DAILY cap fires first
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 400e18, 1, block.timestamp + 60); // day 400 <= 600 ok

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DedicatedVaultMainV2.DailySwapCapExceeded.selector, 800e18, 600e18));
        main.openSwapChunk(jobId, 1, 400e18, 1, block.timestamp + 60); // day 800 > 600 -> revert
    }

    // (5) Regression: liquidations keep the per-JOB cumulative cap + auto-slice
    //     (reserveSwapNotional), untouched by (C). With per-job cap 1_000 a single
    //     non-final chunk drains exactly the sliced 1_000 of a 1_500 residual —
    //     the pre-(C) behaviour, byte-for-byte.
    function testLiquidationPerJobCapAndSlicingUnchanged() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 1_000e18, 2_000e18);
        wbnb.mint(address(main), 1_500e18); // notional 1_500 > per-job cap 1_000

        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("liq-slice"), 0, 0, block.timestamp + 60, false, false);
        assertEq(wbnb.balanceOf(address(main)), 500e18, "liquidation still slices at the per-job cap");
    }

    // ---- reviewer's tests #2/#3/#4/#7 (written now; they never existed on base) ----

    // (#2) The executor guard floor protects EVERY chunk of a series, on that
    //      chunk's actual amountIn — not just a single swap, and not weakenable by
    //      a keeperMinOut of 1. Two differently-sized chunks prove the floor tracks
    //      the real per-chunk amount.
    function testSeriesGuardFloorEnforcedPerChunk() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18);
        _fund(2_000e18);
        bytes32 jobId = keccak256("floor-series");
        _reserve(jobId, 1_000e18);

        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 300e18, 1, block.timestamp + 60);
        // guard minimumOut(300) = 300 * (10000-100)/10000 = 297; keeperMinOut=1 raised.
        assertEq(executor.lastEffectiveMinOut(), 297e18, "chunk 0 floored at the guard minimum on 300");

        vm.prank(keeper);
        main.openSwapChunk(jobId, 1, 200e18, 1, block.timestamp + 60);
        assertEq(executor.lastEffectiveMinOut(), 198e18, "chunk 1 floored on its own 200, not the prior chunk");
    }

    // (#3) A paired-token donation injected MID-series is not silently swept into
    //      the position: the mint's inventory gate (actualPaired > acquired + dust)
    //      catches it and reverts InventoryPresent.
    function testMidSeriesDonationBlocksMint() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18);
        _fund(2_000e18);
        bytes32 jobId = keccak256("donate-mid");
        _reserve(jobId, 1_000e18, 700e18); // swap leg 700 (< budget); series swaps 600

        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 300e18, 1, block.timestamp + 60);
        wbnb.mint(address(main), 5e18); // donation between chunks, far above dust (1e14)
        vm.prank(keeper);
        main.openSwapChunk(jobId, 1, 300e18, 1, block.timestamp + 60); // acquired 600, actual 605

        // _mint pranks keeper internally; expectPartialRevert applies to its openPosition call.
        vm.expectPartialRevert(DedicatedVaultMainV2.InventoryPresent.selector);
        _mint(jobId, 1_000e18); // assetForMint 400; actualPaired 605 > 600 + dust
    }

    // (#4) An aborted open series (chunks swapped, never minted) is NOT locked: it
    //      drains back to dust. Documented asymmetry introduced by B8-T1 — the open
    //      leg may reach canaryOpenCap (600 here), but liquidation is still per-job
    //      capped (300), so a SINGLE final liquidation chunk of the whole residual
    //      MUST revert SwapCapExceeded. The drain is a series of SEPARATE jobs. This
    //      revert is the EXPECTED contract behaviour, not a defect.
    function testAbortedOpenSeriesDrainsViaSeparateJobs() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18);
        _fund(2_000e18);
        bytes32 jobId = keccak256("abort-series");
        _reserve(jobId, 1_000e18, 700e18); // swap leg 700 (< budget); series swaps 600

        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 300e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        main.openSwapChunk(jobId, 1, 300e18, 1, block.timestamp + 60);
        assertEq(wbnb.balanceOf(address(main)), 600e18, "series accumulated 600 WBNB, no mint");

        // A single FINAL liquidation chunk of the full 600 residual reverts: its
        // notional (600) exceeds the per-job liquidation cap (300). EXPECTED.
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapCapExceeded.selector);
        main.liquidateAllWbnb(keccak256("liq-final-fails"), 0, 1, block.timestamp + 60, true, false);

        // Drain via separate jobs: first job slices to the per-job cap, second
        // (fresh job) drains the remainder to zero.
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("liq-a"), 0, 1, block.timestamp + 60, false, false);
        assertEq(wbnb.balanceOf(address(main)), 300e18, "first job drains one per-job cap");
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("liq-b"), 0, 1, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0, "aborted open series fully drained via separate jobs");
    }

    // (#7) A second concurrent open series is rejected at its FIRST swap now
    //      (B9-T1 global lock), not merely at the mint's inventory gate — the lock
    //      is the stronger guarantee. seriesB never swaps.
    function testSecondConcurrentSeriesRejectedAtSwap() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 300e18, 2_000e18);
        _fund(2_000e18);
        bytes32 seriesA = keccak256("series-A");
        bytes32 seriesB = keccak256("series-B");
        _reserve(seriesA, 1_000e18); // only series A is reserved; B is rejected at its first swap

        vm.prank(keeper);
        main.openSwapChunk(seriesA, 0, 300e18, 1, block.timestamp + 60); // main holds 300, locks series A

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.OpenSeriesActive.selector);
        main.openSwapChunk(seriesB, 0, 300e18, 1, block.timestamp + 60);

        assertEq(wbnb.balanceOf(address(main)), 300e18, "second series never swapped");
    }
}
