// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";

/// @notice B1-T13 — four independent Medium fixes on Main: halt gates keeper
/// close/liquidate; emergency swap volume is accounted in the daily limit; the
/// capital ceiling uses fair exposure (not the revenue-conservative NAV); and the
/// last admin cannot renounce/revoke themselves.
contract VaultBMainV2ModesCapAdminTest is VaultBMainV2Test {
    // ── 1. halt() stops keeper close/liquidate; emergency stays open ─────────
    function test_HaltGatesKeeperCloseAndLiquidate() public {
        _fund(2_000e18);
        _open(keccak256("open-halt"));
        vm.prank(guardian);
        main.halt();

        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.HaltedKeeperPath.selector);
        main.closeToInventory(keccak256("c"), block.timestamp + 60, false);

        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.HaltedKeeperPath.selector);
        main.liquidateAllWbnb(keccak256("lw"), 0, 1, block.timestamp + 60, true, false);

        vm.prank(keeper);
        vm.expectRevert(DedicatedVaultMainV2.HaltedKeeperPath.selector);
        main.liquidateAllReward(keccak256("lr"), 0, 1, block.timestamp + 60, true, false);
    }

    function test_HaltDoesNotBlockGuardianEmergencyClose() public {
        _fund(2_000e18);
        _open(keccak256("open-halt-e"));
        vm.prank(guardian);
        main.halt();

        venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);
        vm.prank(guardian);
        main.closeToInventory(keccak256("ce"), block.timestamp + 60, true); // emergency, not gated
        assertEq(main.activePositionId(), 0, "guardian emergency close proceeds while halted");
    }

    // ── 2. emergency swap volume is accounted in the daily limit ─────────────
    function test_EmergencySwapAccruesDailyNotionalAndConstrainsLaterNormalSwap() public {
        _fund(2_000e18);
        _open(keccak256("open-day"));
        venue.configureClose(0, 1_800e18, 0, 1_800e18, 0, 1_800e18);
        _mintCloseInventory(0, 1_800e18);
        vm.prank(guardian);
        main.closeToInventory(keccak256("cday"), block.timestamp + 60, true);

        uint64 day = uint64(block.timestamp / 1 days);
        // Guardian emergency liquidation of the full 1,800 WBNB — recorded in the
        // daily counter (which the daily limit of 2,000 is only 200 above).
        vm.prank(guardian);
        main.liquidateAllWbnb(keccak256("elw"), 0, 1, block.timestamp + 60, true, true);
        assertGe(main.dailySwapNotional(day), 1_800e18, "emergency turnover is recorded in the daily counter");

        // A later normal liquidation of fresh WBNB now trips the daily cap because
        // the emergency spend already counts against it (1,800 + 1,000 > 2,000).
        wbnb.mint(address(main), 1_000e18);
        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.DailySwapCapExceeded.selector);
        main.liquidateAllWbnb(keccak256("nlw"), 0, 1, block.timestamp + 60, true, false);
    }

    // ── 3. capital ceiling uses fair exposure, not under-valued NAV ──────────
    function test_FundCapUsesFairExposureNotUndervaluedNav() public {
        _fund(1_000e18);
        _open(keccak256("open-cap"));
        // Position reports a 40,000 WBNB leg on both geometries. Old cap used
        // minimumOut (39,600); the fix uses fairValue (40,000).
        venue.configureClose(0, 40_000e18, 0, 40_000e18, 0, 0);

        // 10,100 fits under the old (min-out) exposure 39,600 -> 49,700 <= 50,000,
        // but not under the fair exposure 40,000 -> 50,100 > 50,000.
        vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
        main.fundFromVault(10_100e18);
    }

    function test_PureUsdtFundingUnchanged() public {
        // No position: exposure is pure idle USDT; funding under the cap succeeds.
        main.fundFromVault(1_000e18);
        assertEq(usdt.balanceOf(address(main)), 1_000e18);
    }

    // ── 4. the last admin cannot remove itself ───────────────────────────────
    function test_LastAdminCannotRenounceButSecondToLastCan() public {
        bytes32 DA = main.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        vm.expectRevert(DedicatedVaultMainV2.LastAdminCannotBeRemoved.selector);
        main.renounceRole(DA, admin);

        // add a second admin, then the second-to-last one can be removed
        vm.prank(admin);
        main.grantRole(DA, outsider);
        vm.prank(admin);
        main.revokeRole(DA, outsider); // allowed: two -> one

        // the remaining admin is now the last and is protected again
        vm.prank(admin);
        vm.expectRevert(DedicatedVaultMainV2.LastAdminCannotBeRemoved.selector);
        main.renounceRole(DA, admin);

        // and the remaining admin can still administer (enableOperations path open)
        assertTrue(main.hasRole(DA, admin));
        vm.prank(admin);
        main.setOperationalCaps(1_500e18, 1_500e18, 3_000e18);
        assertEq(main.canaryOpenCap(), 1_500e18);
    }
}
