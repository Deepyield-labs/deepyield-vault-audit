// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice Coverage for B1-T2: liquidateAllWbnb / liquidateAllReward must floor
/// the realized output against the priced notional (less the branch's own loss
/// budget), independently of the calldata keeperMinOut. Uses the harness's
/// forced-output adapter hook to model an adapter whose only floor is
/// keeperMinOut (which may be 0). normalCloseLossBps = 100 (1%),
/// emergencyCloseLossBps = 1000 (10%); guard fairValue is 1:1.
contract VaultBMainV2LiquidationFloorTest is VaultBMainV2Test {
    // notional for a 100e18 balance at 1:1 fairValue is 100e18.
    // normal floor = 99e18 (1% budget); emergency floor = 90e18 (10% budget).

    // 1. A near-zero output on a normal call is rejected by the oracle floor.
    //    On pre-fix code (no floor) the swap completes and this does not revert.
    function testWbnbOutputBelowFloorReverts() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(1);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("floor-1wei"), 0, 0, block.timestamp + 60, true, false);
    }

    // 2. An honest full-value swap inside the normal budget still settles.
    function testWbnbHonestSwapWithinNormalBudgetPasses() public {
        wbnb.mint(address(main), 100e18);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("floor-honest"), 0, 0, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0);
    }

    // 3. Just below the normal budget is rejected.
    function testWbnbSwapJustBelowNormalBudgetReverts() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(98e18); // 98% < 99% normal floor
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("floor-below-normal"), 0, 0, block.timestamp + 60, true, false);
    }

    // 4. The emergency branch uses its own wider budget: an output that fails the
    //    normal floor but clears the emergency floor settles on the guardian
    //    path; below the emergency floor it still reverts. Confirms the two
    //    branches use DIFFERENT budgets.
    function testEmergencyBudgetAdmitsWhatNormalRejects() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(95e18); // 95%: below normal 99%, above emergency 90%

        vm.prank(keeper); // normal path rejects
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("floor-normal-rejects"), 0, 0, block.timestamp + 60, true, false);

        vm.prank(guardian); // emergency path admits the same output
        main.liquidateAllWbnb(keccak256("floor-emergency-admits"), 0, 0, block.timestamp + 60, true, true);
        assertEq(wbnb.balanceOf(address(main)), 0);

        // below the emergency floor, the emergency path also reverts
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(85e18); // 85% < 90% emergency floor
        vm.prank(guardian);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("floor-below-emergency"), 0, 0, block.timestamp + 60, true, true);
    }

    // 5. Same floor on the reward path: honest swap settles, near-zero reverts.
    function testRewardLiquidationFloorMirrorsWbnb() public {
        cake.mint(address(main), 100e18);
        vm.prank(keeper); // honest
        main.liquidateAllReward(keccak256("reward-honest"), 0, 0, block.timestamp + 60, true, false);
        assertEq(cake.balanceOf(address(main)), 0);

        cake.mint(address(main), 100e18);
        rewardExecutor.setForcedOut(1);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllReward(keccak256("reward-1wei"), 0, 0, block.timestamp + 60, true, false);
    }

    // 6. keeperMinOut = 0 no longer opens a hole: the oracle floor holds
    //    independently of it (an unprotected honest keeper tx cannot be drained).
    function testKeeperMinOutZeroDoesNotBypassFloor() public {
        wbnb.mint(address(main), 100e18);
        executor.setForcedOut(1);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SwapBelowFloor.selector);
        main.liquidateAllWbnb(keccak256("floor-minout0"), 0, 0, block.timestamp + 60, true, false);
    }
}
