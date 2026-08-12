// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {VaultBAsyncRedeemV2Test} from "./VaultBAsyncRedeemV2.t.sol";

/// @notice B3-T1 — the redeem-cycle commit split-source-of-truth.
///
/// A keeper's routine LP close auto-commits any waiting batch on Main. Before
/// the fix the vault's local `_redeemCycleCommitted` flag became permanently
/// unreachable (its `commitRedeemCycle` reverted on Main's one-way door), so the
/// three functions that read the raw local flag — `claimRedeem`,
/// `claimableRedeemRequest`, `fundRedeemCycleDeficit` — settled the frozen cycle
/// at live per-claim NAV: no 2% execution-loss cap, no pro-rata between requests,
/// no protocol-credit netting, and non-exiting holders wrongly absorbed the
/// exiting batch's loss. These tests exercise the auto-commit trigger (no explicit
/// `commitRedeemCycle` before the close) and assert the batch math now runs.
contract VaultBRedeemCycleAutoCommitTest is VaultBAsyncRedeemV2Test {
    // Auto-commit a queued batch by having a keeper/guardian begin the LP close
    // WITHOUT a prior explicit commitRedeemCycle, then drain WBNB to full USDT.
    // outNum/outDen scales the realized close output to inject execution loss.
    function _autoCommitCloseAndLiquidate(bytes32 tag, uint256 outNum, uint256 outDen, bool emergency)
        internal
        returns (uint256 assetIn, uint256 pairedIn)
    {
        guard.setFail(false);
        assetIn = venue.lastAssetIn();
        pairedIn = venue.lastPairedIn();
        venue.configureClose(
            assetIn, pairedIn, assetIn, pairedIn, assetIn * outNum / outDen, pairedIn * outNum / outDen
        );
        address who = emergency ? guardian : keeper;
        vm.prank(who);
        main.closeToInventory(tag, block.timestamp + 60, emergency);
        vm.prank(who);
        main.liquidateAllWbnb(keccak256(abi.encode(tag, "SELL")), 0, 1, block.timestamp + 60, true, emergency);
    }

    // ---- п.1 + п.2 : batch path (cap + pro-rata) and preview==actual --------

    /// A within-cap execution loss on an auto-committed cycle must be borne by the
    /// exiting batch, not socialized onto remaining holders, and the preview a
    /// user reads must equal what the claim actually pays. On the old code
    /// `claimRedeem` fell through to live NAV, so the loss hit every holder —
    /// `assertGe(remainingAfter, remainingBefore)` fails.
    function testAutoCommittedBatchBearsLossAndPreviewMatchesClaim() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20; // 5%
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();
        uint256 remainingBefore = vault.previewRedeem(vault.balanceOf(alice));

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);

        (uint256 assetIn, uint256 pairedIn) = _autoCommitCloseAndLiquidate("B3T1_LOSS", 99, 100, false);
        assertGt(main.withdrawalCycleExecutionLoss(), 0, "auto-commit armed the loss journal");
        assertEq(main.withdrawalCycleExecutionLoss(), (assetIn - assetIn * 99 / 100) + (pairedIn - pairedIn * 99 / 100));

        uint256 preview = vault.claimableRedeemRequest(requestId);
        uint256 actual = vault.claimRedeem(requestId);
        assertApproxEqAbs(preview, actual, 1, "preview equals the actual batch settlement");

        uint256 remainingAfter = vault.previewRedeem(vault.balanceOf(alice));
        assertGe(remainingAfter, remainingBefore, "non-exiting NAV absorbs no execution loss under the batch path");
        assertLt(usdt.balanceOf(bob), 50e18, "the exiting batch bears the measured cycle loss");
    }

    // ---- п.1a (cap) + п.3 (treasury funding) --------------------------------

    /// An over-cap loss on an auto-committed cycle must revert `claimRedeem`
    /// (cap enforced) until the treasury funds the deficit; both the cap and the
    /// funding path are reachable only through the combined committed view. Old
    /// code settled at live NAV with no cap, so `claimRedeem` did not revert.
    function testAutoCommittedOverCapLossEnforcesCapThenTreasurySettles() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);

        _autoCommitCloseAndLiquidate("B3T1_OVERCAP", 97, 100, true); // ~3% loss, emergency budget

        // Cap enforced: settlement reverts rather than passing >2% through.
        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleExecutionLossExceeded.selector);
        vault.claimRedeem(requestId);

        // The snapshot was fixed atomically before Main began the close. A reverted
        // claim cannot roll it back because it belongs to the earlier close tx.
        uint256 maximum = vault.redeemCycleAssetsSnapshot() * vault.MAX_BATCH_EXECUTION_LOSS_BPS() / 10_000;
        uint256 measured = main.withdrawalCycleExecutionLoss();
        assertGt(measured, maximum, "close loss exceeds the 2% batch cap");

        uint256 credit = measured - maximum;
        usdt.mint(address(this), credit);
        vm.prank(admin);
        vault.setTreasury(address(this));
        IERC20(USDT).approve(address(vault), credit);
        vault.fundRedeemCycleDeficit(credit);

        assertGt(vault.claimRedeem(requestId), 0, "capped settlement completes once the deficit is funded");
    }

    // ---- п.5 : two requests settle pro-rata, no first-claimer edge ----------

    /// Two equal requests queued when Main auto-commits must settle at the same
    /// pro-rata price; the batch payout is frozen at the first claim, so NAV that
    /// drifts between the two claims cannot advantage whoever claims later. Old
    /// code recomputed live NAV per claim, so the second claimer captured the
    /// drift — the two payouts diverged.
    function testTwoQueuedRequestsSettleEquallyDespiteNavDriftBetweenClaims() public {
        address carol = makeAddr("carol");
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 q = (totalShares + 39) / 40; // 2.5% each, 5% together
        vm.prank(alice);
        vault.transfer(bob, q);
        vm.prank(alice);
        vault.transfer(carol, q);
        _open();

        vm.prank(bob);
        uint256 bobId = vault.requestRedeem(q, bob, bob);
        vm.prank(carol);
        uint256 carolId = vault.requestRedeem(q, carol, carol);

        _autoCommitCloseAndLiquidate("B3T1_FAIR", 1, 1, false); // honest close, no loss

        uint256 bobAssets = vault.claimRedeem(bobId);
        // NAV drifts up during the multi-tx settlement window.
        usdt.mint(address(vault), 10e18);
        uint256 carolAssets = vault.claimRedeem(carolId);

        assertApproxEqAbs(
            carolAssets, bobAssets, 1, "equal requests settle equally; late claimer gets no NAV-drift edge"
        );
    }

    // ---- п.4 : auto-commit snapshots before the irreversible close ----------

    /// Main's callback must materialize the Vault snapshot in the same transaction
    /// before the close crosses its one-way boundary. A second explicit commit is
    /// rejected because there is no intermediate Main-only committed state.
    function testAutoCommitSnapshotsBeforeCloseReturns() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();

        vm.prank(bob);
        vault.requestRedeem(queued, bob, bob);

        // Keeper auto-commit via a routine (honest) close; no explicit commit yet.
        guard.setFail(false);
        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetIn, pairedIn);
        vm.prank(keeper);
        main.closeToInventory("B3T1_SNAP", block.timestamp + 60, false);

        assertTrue(vault.redeemCycleCommitted(), "auto-commit is visible on both sides");
        assertEq(vault.redeemCycleCommittedShares(), queued, "snapshot fixes the committed shares atomically");
        assertEq(vault.redeemCycleSupplySnapshot(), vault.totalSupply(), "snapshot fixes the supply basis");

        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleLocked.selector);
        vault.commitRedeemCycle();
    }

    // ---- п.7 : the timely local-commit path is unchanged --------------------

    /// Regression: committing locally BEFORE the close still commits the strategy
    /// exactly once (both Main flags set), and the cycle settles normally.
    function testTimelyLocalCommitPathRemainsUnchanged() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();

        assertTrue(main.withdrawalCycleCommitted());
        assertTrue(main.withdrawalCycleBatchCommitted());
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY));

        _closeAndLiquidate();
        uint256 payout = vault.claimRedeem(requestId);
        assertGt(payout, 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalSupply(), totalShares - queued);
    }
}
