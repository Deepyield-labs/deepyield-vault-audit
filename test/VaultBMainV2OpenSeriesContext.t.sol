// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice B11-T1: the open series reserves its FULL budget + ticks + deadline
/// ceiling BEFORE the first swap. The old two-phase design capped the swap leg in
/// phase 1 and the budget in phase 2 against one cap — different quantities — so a
/// swap leg equal to the cap could never be minted (funds stranded in the pair) and
/// ticks/deadline were unchecked until the mint. These tests pin the reservation
/// invariants.
contract VaultBMainV2OpenSeriesContextTest is VaultBMainV2Test {
    // (1) Reviewer scenario: reserve a budget EQUAL to the cap, then try to swap the
    //     WHOLE budget. The swap is bounded by the reserved swap leg (< budget), so a
    //     chunk that would push past it reverts. This closes the deterministic
    //     all-budget deadlock that the old two-cap design allowed.
    function test_ReserveBudgetEqCapThenSwapWholeBudgetRejected() public {
        vm.prank(admin);
        main.setOperationalCaps(500e18, 500e18, 2_000e18); // canaryOpenCap 500
        _fund(2_000e18);
        bytes32 jobId = keccak256("whole-budget");
        _reserve(jobId, 500e18, 300e18); // budget == cap; swap leg 300 (< budget)
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 300e18, 1, block.timestamp + 60); // fills the swap leg
        // A further chunk toward the full budget exceeds the swap leg → rejected.
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
        main.openSwapChunk(jobId, 1, 200e18, 1, block.timestamp + 60); // would make swapped == budget
        // Swap bounded at the leg (300), not the whole budget — the 200 mint leg survives.
        assertEq(wbnb.balanceOf(address(main)), 300e18, "swap bounded by the leg, not the budget");
    }

    // (2) A budget above the cap is rejected up front (swap + mint bounded together).
    function test_BudgetAboveCapRejectedBeforeSwap() public {
        _fund(2_000e18); // setUp canaryOpenCap is 1_000
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
        main.reserveOpenSeries(keccak256("over"), 1_001e18, 500e18, -100, 100, block.timestamp + 60);
        assertEq(main.activeOpenJobId(), bytes32(0));
    }

    // (3) Ticks are validated at reserve, before any swap moves USDT.
    function test_InvalidTicksRejectedAtReserve() public {
        _fund(2_000e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DedicatedVaultMainV2.InvalidTickRange.selector, int24(0), int24(1)));
        main.reserveOpenSeries(keccak256("bad-ticks"), 1_000e18, 500e18, 0, 1, block.timestamp + 60); // width 1 < min 2
        assertEq(main.activeOpenJobId(), bytes32(0));
    }

    // (4) The mint deadline is bounded above: by block.timestamp + 600 (close parity)
    //     AND by the ceiling fixed at reserve.
    function test_MintDeadlineBoundedAbove() public {
        _fund(2_000e18);
        bytes32 jobId = keccak256("deadline");
        _reserve(jobId, 1_000e18); // ceiling = block.timestamp + 60
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 500e18, 1, block.timestamp + 60);
        // Above the close-parity +600 bound.
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.InvalidDeadline.selector);
        main.openPosition(_mintParams(jobId, -100, 100, 1_000e18, block.timestamp + 601));
        // Within +600 but above the reserved ceiling (+60).
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.InvalidDeadline.selector);
        main.openPosition(_mintParams(jobId, -100, 100, 1_000e18, block.timestamp + 120));
    }

    // (5) The mint must finalize the RESERVED context — a different budget or ticks
    //     cannot slip past.
    function test_MintMustMatchReservedContext() public {
        _fund(2_000e18);
        bytes32 jobId = keccak256("ctx");
        _reserve(jobId, 1_000e18);
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 500e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.OpenSeriesContextMismatch.selector);
        main.openPosition(_mintParams(jobId, -100, 100, 999e18, block.timestamp + 60)); // wrong budget
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.OpenSeriesContextMismatch.selector);
        main.openPosition(_mintParams(jobId, -200, 200, 1_000e18, block.timestamp + 60)); // wrong ticks
    }

    // (6) cancelOpenSeries clears the context so the next series cannot inherit the
    //     previous budget.
    function test_CancelClearsContextForNextSeries() public {
        _fund(2_000e18);
        bytes32 a = keccak256("A");
        _reserve(a, 1_000e18); // no swap → no inventory to drain
        vm.prank(keeper);
        main.cancelOpenSeries(a);
        assertEq(main.activeOpenJobId(), bytes32(0), "lock cleared");
        (uint256 budget,,,,, bool set) = main.openSeriesContext();
        assertEq(budget, 0, "context budget cleared");
        assertFalse(set, "context flag cleared");

        bytes32 b = keccak256("B");
        _reserve(b, 800e18);
        assertEq(main.activeOpenJobId(), b);
        (uint256 budget2,,,,, bool set2) = main.openSeriesContext();
        assertEq(budget2, 800e18, "fresh series budget, no inheritance");
        assertTrue(set2);
    }

    // (7) A second series cannot be reserved while one is active (B9-T1 lock), and a
    //     normal open still mints and clears the lock (regression).
    function test_SecondSeriesLockedAndNormalOpenWorks() public {
        _fund(2_000e18);
        _reserve(keccak256("A"), 1_000e18);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.OpenSeriesActive.selector);
        main.reserveOpenSeries(keccak256("B"), 500e18, 250e18, -100, 100, block.timestamp + 60);

        vm.prank(keeper);
        main.openSwapChunk(keccak256("A"), 0, 500e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        uint256 id = main.openPosition(_mintParams(keccak256("A"), -100, 100, 1_000e18, block.timestamp + 60));
        assertGt(id, 0, "normal open mints");
        assertEq(main.activeOpenJobId(), bytes32(0), "lock cleared after mint");
    }

    // (8) A swap leg equal to (or above) the budget cannot be reserved at all —
    //     there would be no mint leg. Strict swapLeg < assetBudget.
    function test_ReserveSwapLegEqualOrAboveBudgetImpossible() public {
        _fund(2_000e18);
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.InvalidAmount.selector);
        main.reserveOpenSeries(keccak256("eq"), 1_000e18, 1_000e18, -100, 100, block.timestamp + 60);
        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.InvalidAmount.selector);
        main.reserveOpenSeries(keccak256("gt"), 1_000e18, 1_001e18, -100, 100, block.timestamp + 60);
    }

    // (9) After a normal series the mint leg (budget − swapLeg) is a real two-sided
    //     leg, not a one-wei remainder — the mint succeeds.
    function test_MintLegIsTwoSidedAfterSeries() public {
        _fund(2_000e18);
        bytes32 jobId = keccak256("two-sided");
        _reserve(jobId, 1_000e18, 500e18); // swap leg 500 → mint leg 500
        vm.prank(keeper);
        main.openSwapChunk(jobId, 0, 500e18, 1, block.timestamp + 60);
        vm.prank(keeper);
        uint256 id = main.openPosition(_mintParams(jobId, -100, 100, 1_000e18, block.timestamp + 60));
        assertGt(id, 0, "two-sided mint succeeds; the mint leg is not dust");
    }

    // A merely-positive mint leg is not enough: integer CL geometry can still
    // round one expected leg to zero and make the series impossible to mint.
    function test_OneWeiMintLegRejectedBeforeAnySwap() public {
        _fund(2_000e18);
        bytes32 jobId = keccak256("one-wei-mint-leg");

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.OpenNotTwoSided.selector);
        main.reserveOpenSeries(jobId, 1_000e18, 1_000e18 - 1, -100, 100, block.timestamp + 60);

        assertEq(main.activeOpenJobId(), bytes32(0), "invalid geometry cannot reserve a series");
        assertEq(wbnb.balanceOf(address(main)), 0, "no phase-one inventory moved");
    }

    function _mintParams(bytes32 jobId, int24 tl, int24 tu, uint256 budget, uint256 deadline)
        internal
        pure
        returns (DedicatedVaultMainV2.OpenParams memory)
    {
        return DedicatedVaultMainV2.OpenParams({
            jobId: jobId,
            tickLower: tl,
            tickUpper: tu,
            assetBudget: budget,
            swapAssetIn: 500e18,
            keeperPairedMinOut: 1,
            deadline: deadline
        });
    }
}
