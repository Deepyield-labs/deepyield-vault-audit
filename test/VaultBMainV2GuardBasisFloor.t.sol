// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice Coverage for B1-T12: the liquidation swap-output floor is computed
/// from the price guard's OWN swap budget (priceGuard.minimumOut /
/// rewardPriceGuard.minimumOut), the same rule the execution adapter enforces,
/// so Main's floor and the guard cannot diverge. This removes the DoS a static
/// close-budget floor caused when the guard's swap budget is wider, and makes
/// the floor track the guard's (expiring) emergency budget instead of a
/// permissive static one.
/// Harness note: uses the default-off forced-output hook on the mock adapters
/// and the loss-bps setter on the mock guard (both added for this task).
contract VaultBMainV2GuardBasisFloorTest is VaultBMainV2Test {
    // mock guard defaults: normal 100 bps (floor 99%), emergency 1000 bps (90%).

    // 1. Guard swap budget WIDER than the static close budget: a swap the guard
    //    accepts (97%, guard budget 3%) now settles. Under B1-T2's static 1%
    //    floor this reverts — a DoS created by the defensive check.
    function testGuardWiderBudgetNoLongerDoSLiquidation() public {
        wbnb.mint(address(main), 100e18);
        guard.setLossBps(300, 1_000); // guard swap budget 3%
        executor.setForcedOut(97e18); // within the guard budget
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("dos"), 0, 0, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0);
    }

    // 2. Output below the guard floor still reverts.
    function testOutputBelowGuardFloorReverts() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(98e18); // below the 99% normal guard floor
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("below"), 0, 0, block.timestamp + 60, true, false);
    }

    // 3. Emergency budget inactive: the guard reverts inside the floor call, so
    //    the emergency liquidation reverts — the floor tracks the guard's
    //    emergency gating instead of a static, permissive fallback.
    function testEmergencyInactiveGuardBlocksLiquidation() public {
        wbnb.mint(address(main), 100e18);
        guard.setEmergencyActive(false);
        executor.setForcedOut(95e18);
        vm.prank(guardian);
        vm.expectRevert(bytes("emergency inactive"));
        main.liquidateAllWbnb(keccak256("emg-off"), 0, 0, block.timestamp + 60, true, true);
    }

    // 4. Different budgets per branch: 92% fails the normal floor (99%) but
    //    clears the armed emergency floor (90%).
    function testEmergencyArmedBudgetAdmitsWhatNormalRejects() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(92e18);

        vm.prank(keeper); // normal rejects
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("norm-reject"), 0, 0, block.timestamp + 60, true, false);

        vm.prank(guardian); // emergency admits (default emergencyActive=true, 90% floor)
        main.liquidateAllWbnb(keccak256("emg-admit"), 0, 0, block.timestamp + 60, true, true);
        assertEq(wbnb.balanceOf(address(main)), 0);
    }

    // 5. Reward path mirrors: below the reward guard floor reverts.
    function testRewardPathFloorMirrors() public {
        cake.mint(address(main), 100e18);
        rewardExecutor.setForcedOut(98e18); // below the 99% reward guard floor
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllReward(keccak256("rwd-below"), 0, 0, block.timestamp + 60, true, false);
    }

    // 6. Regression: an honest full-value swap still settles.
    function testHonestSwapPasses() public {
        wbnb.mint(address(main), 100e18);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("honest"), 0, 0, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0);
    }
}
