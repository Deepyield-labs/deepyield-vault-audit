// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";

contract TSToken is ERC20 {
    constructor() ERC20("USD Test", "USDT") {}
}

/// @notice B12-T1: root control (DEFAULT_ADMIN_ROLE) transfers only through the
/// two-step, timelocked, accept-required flow of AccessControlDefaultAdminRules.
contract VaultBTwoStepAdminTest is Test {
    TSToken internal token;
    DeepYieldVaultB internal vault;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal newAdmin = makeAddr("newAdmin");
    address internal wrong = makeAddr("wrong");
    address internal alice = makeAddr("alice");

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal ADMIN_ROLE;
    bytes32 internal GUARDIAN_ROLE;
    uint48 internal delay;

    function setUp() public {
        token = new TSToken();
        vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
        ADMIN_ROLE = vault.ADMIN_ROLE();
        GUARDIAN_ROLE = vault.GUARDIAN_ROLE();
        delay = vault.DEFAULT_ADMIN_TRANSFER_DELAY();
    }

    // ── (1) transfer needs the recipient to accept; the old admin keeps root until then. ──
    function test_TransferRequiresAcceptance() public {
        assertEq(vault.defaultAdmin(), admin);
        vm.prank(admin);
        vault.beginDefaultAdminTransfer(newAdmin);
        (address pending,) = vault.pendingDefaultAdmin();
        assertEq(pending, newAdmin, "pending set");

        vm.warp(block.timestamp + delay + 1);
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "old admin holds root until acceptance");
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "new admin has nothing before accept");

        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "new admin holds root after accept");
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "old admin lost root");
        assertEq(vault.defaultAdmin(), newAdmin);
    }

    // ── (2) a wrong address never holds root without accepting; the transfer is cancellable. ──
    function test_WrongAddressGetsNothingAndCancellable() public {
        vm.prank(admin);
        vault.beginDefaultAdminTransfer(wrong);
        vm.prank(admin);
        vault.cancelDefaultAdminTransfer();
        (address pending,) = vault.pendingDefaultAdmin();
        assertEq(pending, address(0), "transfer cancelled");

        // Even past the delay, the wrong address cannot accept a cancelled transfer.
        vm.warp(block.timestamp + delay + 1);
        vm.prank(wrong);
        vm.expectRevert();
        vault.acceptDefaultAdminTransfer();
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, wrong), "wrong address holds nothing");
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "old admin retained root");
    }

    // ── (3) the delay is enforced: accepting before the schedule reverts. ──
    function test_DelayEnforced() public {
        vm.prank(admin);
        vault.beginDefaultAdminTransfer(newAdmin);
        vm.warp(block.timestamp + delay - 1);
        vm.prank(newAdmin);
        vm.expectRevert();
        vault.acceptDefaultAdminTransfer();
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "not transferred before the delay");
    }

    // ── (4) ADMIN_ROLE and guardian paths are unchanged. ──
    function test_AdminAndGuardianRolesUnaffected() public {
        // The default admin still grants/revokes ADMIN_ROLE to a third party.
        vm.prank(admin);
        vault.grantRole(ADMIN_ROLE, alice);
        assertTrue(vault.hasRole(ADMIN_ROLE, alice));
        vm.prank(alice);
        vault.setMaxPendingRedeems(10); // an ADMIN_ROLE-gated call works
        assertEq(vault.maxPendingRedeems(), 10);
        vm.prank(admin);
        vault.revokeRole(ADMIN_ROLE, alice);
        assertFalse(vault.hasRole(ADMIN_ROLE, alice));

        // Guardian pauses; the admin unpauses — both unchanged.
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ── (5) DEFAULT_ADMIN_ROLE cannot be handed over in one tx via grantRole. ──
    function test_DirectDefaultAdminGrantBlocked() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.grantRole(DEFAULT_ADMIN_ROLE, wrong);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, wrong), "no one-tx handover");
    }
}
