// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice INT-1 integration test — exists in no single branch. Exercises B1-T1
/// (chunked liquidation of an oversized residual) TOGETHER with B1-T12 (the
/// guard-basis output floor). The point: the floor must be computed on the
/// POST-SLICE amountIn actually swapped this chunk, not on the full balance.
/// A non-final chunk swaps only the per-job-cap slice; if the floor were taken
/// on the full (larger) balance it would exceed the sliced output and revert a
/// legitimate liquidation. Honest swaps here clear the guard floor on the sliced
/// amount and the residual drains to zero over two calls.
contract VaultBMainV2IntegrationChunkGuardFloorTest is VaultBMainV2Test {
    // swapPerJobCap = 1_000e18, dailySwapLimit = 2_000e18, guard normal 100 bps.
    function testChunkedLiquidationWithGuardFloorDrainsOversizedResidual() public {
        wbnb.mint(address(main), 1_500e18); // notional 1_500 > per-job cap 1_000

        // Non-final chunk: sliced to the 1_000 headroom; honest swap returns the
        // sliced amount, which clears guard.minimumOut(slicedAmountIn) (=990).
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("int-c1"), 0, 0, block.timestamp + 60, false, false);
        assertEq(wbnb.balanceOf(address(main)), 500e18, "first chunk drains only the sliced amount");

        // Final chunk: remaining 500 fits under the cap; drains to zero.
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("int-c2"), 0, 0, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0, "residual fully drained across chunks");
    }

    // Reward path mirror of the same integration invariant.
    function testChunkedRewardLiquidationWithGuardFloorDrains() public {
        cake.mint(address(main), 1_500e18);
        vm.prank(keeper);
        main.liquidateAllReward(keccak256("int-r1"), 0, 0, block.timestamp + 60, false, false);
        assertEq(cake.balanceOf(address(main)), 500e18);
        vm.prank(keeper);
        main.liquidateAllReward(keccak256("int-r2"), 0, 0, block.timestamp + 60, true, false);
        assertEq(cake.balanceOf(address(main)), 0);
    }
}
