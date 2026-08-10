// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployVaultBV2} from "../script/DeployVaultBV2.s.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {DedicatedVaultStrategyAdapterV2} from "../src/DedicatedVaultStrategyAdapterV2.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";
import {VaultBAsyncRedeemV2Test} from "./VaultBAsyncRedeemV2.t.sol";
import {DeployVaultBV2DryRunTest} from "./DeployVaultBV2DryRun.t.sol";

contract DeployVaultBV2Harness is DeployVaultBV2 {
    function checkedUint16(uint256 value) external pure returns (uint16) {
        return _checkedUint16(value, ".testUint16");
    }

    function checkedUint32(uint256 value) external pure returns (uint32) {
        return _checkedUint32(value, ".testUint32");
    }
}

contract VaultBWithdrawalBatchRemediationTest is VaultBAsyncRedeemV2Test {
    function testMinimumRequestCannotCommitAtArbitraryCalendarBoundary() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 positionId = main.activePositionId();
        uint256 minimum = vault.MIN_REDEEM_SHARES();
        vm.prank(alice);
        vault.transfer(bob, minimum);

        vm.prank(bob);
        vault.requestRedeem(minimum, bob, bob);

        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));
        assertEq(main.activePositionId(), positionId);
        assertFalse(vault.redeemCycleCommitted());
        assertFalse(main.withdrawalCycleCommitted());
        vm.warp(block.timestamp + 52 weeks);
        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleNotReady.selector);
        vault.commitRedeemCycle();
        assertEq(vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(address(vault)), shares);
    }

    function testOwnerCanCancelBeforeCommitButThirdPartyCannot() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        uint256 minimum = vault.MIN_REDEEM_SHARES();
        vm.prank(alice);
        vault.transfer(bob, minimum);
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(minimum, bob, bob);

        vm.prank(alice);
        vm.expectRevert(DeepYieldVaultB.NotRedeemOwner.selector);
        vault.cancelRedeem(requestId);
        vm.prank(bob);
        vault.cancelRedeem(requestId);

        assertEq(vault.balanceOf(bob), minimum);
        assertEq(vault.outstandingRedeemCount(), 0);
        assertEq(main.queuedWithdrawalCount(), 0);
        assertEq(vault.balanceOf(alice) + vault.balanceOf(bob), shares);
    }

    function testFivePercentQueueCommitsEarlyAndCannotCancelAfterCommit() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 queued = (shares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);

        vm.prank(makeAddr("batch-settler"));
        vault.commitRedeemCycle();

        assertTrue(vault.redeemCycleCommitted());
        assertTrue(main.withdrawalCycleCommitted());
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY));
        vm.prank(bob);
        vm.expectRevert(DeepYieldVaultB.RedeemCycleLocked.selector);
        vault.cancelRedeem(requestId);

        _closeAndLiquidate();
        vault.claimRedeem(requestId);
        assertEq(vault.balanceOf(bob), 0, "committed requester settles instead of recovering shares");
        assertEq(vault.totalSupply(), shares - queued);
        assertFalse(vault.redeemCycleCommitted());
        assertFalse(main.withdrawalCycleCommitted());
    }

    function testProtocolCloseCommitsQueueWithoutMarkingItBatchFunded() public {
        _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 minimum = vault.MIN_REDEEM_SHARES();
        vm.prank(alice);
        vault.transfer(bob, minimum);
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(minimum, bob, bob);

        guard.setFail(false);
        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetIn * 99 / 100, pairedIn * 99 / 100);
        vm.prank(keeper);
        main.closeToInventory(keccak256("CLOSE_WITH_PENDING_BATCH"), block.timestamp + 60, false);

        assertTrue(main.withdrawalCycleCommitted());
        assertFalse(main.withdrawalCycleBatchCommitted());
        assertEq(main.withdrawalCycleExecutionLoss(), 0, "protocol close cost is not charged to a waiting batch");
        assertTrue(vault.redeemCycleCommitted());
        vm.prank(bob);
        vm.expectRevert(DeepYieldVaultB.RedeemCycleLocked.selector);
        vault.cancelRedeem(requestId);
    }

    function testUncommittedQueueDoesNotBlockSynchronousIdleReserveExit() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 minimum = vault.MIN_REDEEM_SHARES();
        vm.prank(alice);
        vault.transfer(bob, minimum);
        vm.prank(bob);
        vault.requestRedeem(minimum, bob, bob);

        uint256 redeemable = vault.maxRedeem(alice);
        assertGt(redeemable, 0, "the 2% idle reserve remains available");
        vm.prank(alice);
        uint256 received = vault.redeem(redeemable, alice, alice);

        assertGt(received, 19e18);
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));
        assertEq(vault.outstandingRedeemCount(), 1);
        assertEq(vault.totalSupply(), shares - redeemable);
    }

    function testCommittableBatchAbsorbsMeasuredExecutionLoss() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();
        uint256 remainingHolderBefore = vault.previewRedeem(vault.balanceOf(alice));

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();

        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        uint256 assetOut = assetIn * 99 / 100;
        uint256 pairedOut = pairedIn * 99 / 100;
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetOut, pairedOut);
        vm.prank(keeper);
        main.closeToInventory(keccak256("LOSS_CLOSE"), block.timestamp + 60, false);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("LOSS_LIQUIDATION"), 0, 1, block.timestamp + 60, true, false);

        uint256 measuredLoss = main.withdrawalCycleExecutionLoss();
        assertEq(measuredLoss, (assetIn - assetOut) + (pairedIn - pairedOut));
        assertEq(
            adapter.withdrawalCycleChargeableExecutionLoss(), measuredLoss, "no profit means no performance-fee relief"
        );
        vault.claimRedeem(requestId);

        uint256 remainingHolderAfter = vault.previewRedeem(vault.balanceOf(alice));
        assertGe(remainingHolderAfter, remainingHolderBefore, "non-requesting NAV absorbs no measured execution loss");
        assertLt(usdt.balanceOf(bob), 50e18, "the requesting batch bears the measured cycle loss");
        assertEq(vault.totalSupply(), totalShares - queued);
    }

    function testOverBudgetExecutionLossRequiresExplicitTreasuryCredit() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 queued = (shares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();

        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        uint256 assetOut = assetIn * 97 / 100;
        uint256 pairedOut = pairedIn * 97 / 100;
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetOut, pairedOut);
        vm.prank(guardian);
        main.closeToInventory(keccak256("OVER_BUDGET_CLOSE"), block.timestamp + 60, true);
        vm.prank(guardian);
        main.liquidateAllWbnb(keccak256("OVER_BUDGET_LIQUIDATION"), 0, 1, block.timestamp + 60, true, true);

        uint256 measured = main.withdrawalCycleExecutionLoss();
        uint256 maximum = vault.redeemCycleAssetsSnapshot() * vault.MAX_BATCH_EXECUTION_LOSS_BPS() / 10_000;
        assertGt(measured, maximum);
        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleExecutionLossExceeded.selector);
        vault.claimRedeem(requestId);

        uint256 credit = measured - maximum;
        usdt.mint(feeRecipient, credit);
        vm.startPrank(feeRecipient);
        IERC20(USDT).approve(address(vault), credit);
        vault.fundRedeemCycleDeficit(credit);
        vm.stopPrank();
        assertGt(vault.claimRedeem(requestId), 0);
    }

    function testEmergencyCloseRecordsFairLossAndRequiresExactCreditAboveCap() public {
        uint256 shares = _depositAndDeploy(alice, 1_000e18);
        _open();
        uint256 queued = (shares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();

        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        uint256 assetOut = assetIn * 979 / 1_000;
        uint256 pairedOut = pairedIn * 979 / 1_000;
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetOut, pairedOut);

        vm.prank(guardian);
        main.closeToInventory(keccak256("EMERGENCY_FAIR_CAP_CLOSE"), block.timestamp + 60, true);
        vm.prank(guardian);
        main.liquidateAllWbnb(keccak256("EMERGENCY_FAIR_CAP_SELL"), 0, 1, block.timestamp + 60, true, true);

        uint256 fairLoss = (assetIn - assetOut) + (pairedIn - pairedOut);
        uint256 measured = main.withdrawalCycleExecutionLoss();
        uint256 maximum = vault.redeemCycleAssetsSnapshot() * vault.MAX_BATCH_EXECUTION_LOSS_BPS() / 10_000;
        assertEq(measured, fairLoss, "emergency discount must not reduce loss accounting");
        assertGt(measured, maximum);
        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleExecutionLossExceeded.selector);
        vault.claimRedeem(requestId);

        uint256 exactCredit = measured - maximum;
        usdt.mint(feeRecipient, exactCredit);
        vm.startPrank(feeRecipient);
        IERC20(USDT).approve(address(vault), exactCredit);
        vault.fundRedeemCycleDeficit(exactCredit - 1);
        vm.stopPrank();

        vm.expectPartialRevert(DeepYieldVaultB.RedeemCycleExecutionLossExceeded.selector);
        vault.claimRedeem(requestId);
        vm.startPrank(feeRecipient);
        vault.fundRedeemCycleDeficit(1);
        vm.stopPrank();
        assertGt(vault.claimRedeem(requestId), 0, "exact treasury credit unlocks settlement");
    }

    function testPerformanceFeeReliefReducesBatchChargeButNotGrossLossCap() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();

        usdt.mint(address(venue), 50e18);
        wbnb.mint(address(venue), 50e18);
        venue.configureClose(540e18, 540e18, 540e18, 540e18, 535e18, 535e18);

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();
        vm.prank(keeper);
        main.closeToInventory(keccak256("FEE_RELIEF_CLOSE"), block.timestamp + 60, false);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("FEE_RELIEF_SELL"), 0, 1, block.timestamp + 60, true, false);

        assertEq(main.withdrawalCycleExecutionLoss(), 10e18, "gross fair-value loss remains observable");
        assertEq(adapter.withdrawalCycleChargeableExecutionLoss(), 8e18, "20% fee relief offsets batch charge");
        assertEq(vault.totalAssets(), 1_072e18, "post-loss NAV is net of the reduced fee liability");

        uint256 payout = vault.claimRedeem(requestId);
        uint256 remainingValue = vault.previewRedeem(vault.balanceOf(alice));
        assertEq(payout, 46e18, "batch bears exactly the shareholder NAV loss");
        assertApproxEqAbs(remainingValue, 1_026e18, 1, "non-requesting entitlement is unchanged");
    }

    function testPerformanceFeeReliefIsCappedByPreLossFeeLiability() public {
        uint256 totalShares = _depositAndDeploy(alice, 1_000e18);
        uint256 queued = (totalShares + 19) / 20;
        vm.prank(alice);
        vault.transfer(bob, queued);
        _open();

        uint256 profitPerLeg = 2_500_000_000_000_000_000;
        uint256 lossPerLeg = 4_900_000_000_000_000_000;
        uint256 expectedPerLeg = venue.lastAssetIn() + profitPerLeg;
        uint256 actualPerLeg = expectedPerLeg - lossPerLeg;
        usdt.mint(address(venue), profitPerLeg);
        wbnb.mint(address(venue), profitPerLeg);
        venue.configureClose(expectedPerLeg, expectedPerLeg, expectedPerLeg, expectedPerLeg, actualPerLeg, actualPerLeg);

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(queued, bob, bob);
        vault.commitRedeemCycle();
        vm.prank(keeper);
        main.closeToInventory(keccak256("FEE_RELIEF_CAP_CLOSE"), block.timestamp + 60, false);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("FEE_RELIEF_CAP_SELL"), 0, 1, block.timestamp + 60, true, false);

        assertEq(main.withdrawalCycleExecutionLoss(), 2 * lossPerLeg);
        assertEq(
            adapter.withdrawalCycleChargeableExecutionLoss(),
            2 * lossPerLeg - 1e18,
            "only the existing 1-unit fee can absorb loss"
        );
        assertEq(vault.totalAssets(), 995_200_000_000_000_000_000);

        uint256 payout = vault.claimRedeem(requestId);
        uint256 remainingValue = vault.previewRedeem(vault.balanceOf(alice));
        assertEq(payout, 41_400_000_000_000_000_000);
        assertApproxEqAbs(remainingValue, 953_800_000_000_000_000_000, 1);
    }

    function testActiveLpBlocksLateDepositUntilNavIsFullyRealized() public {
        _depositAndDeploy(alice, 1_000e18);
        _open();
        assertFalse(adapter.depositsAllowed());
        assertEq(vault.maxDeposit(bob), 0);

        usdt.mint(bob, 1_000e18);
        vm.startPrank(bob);
        IERC20(USDT).approve(address(vault), 1_000e18);
        vm.expectRevert(DeepYieldVaultB.DepositCapExceeded.selector);
        vault.deposit(1_000e18, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), 0);
    }

    function testAdapterAlwaysLeavesTwoPercentVaultIdleReserve() public {
        _deposit(alice, 1_000e18);
        uint256 deployable = adapter.maxDeployableAssets();
        uint256 reserve = adapter.minimumVaultIdleAssets();
        assertEq(deployable, 980e18);
        assertEq(reserve, 20e18);

        vm.prank(manager);
        vm.expectPartialRevert(DedicatedVaultStrategyAdapterV2.VaultIdleReserveViolation.selector);
        adapter.deploy(deployable + 1);
        vm.prank(manager);
        adapter.deploy(deployable);
        assertEq(usdt.balanceOf(address(vault)), reserve);
    }

    function testLpCloseLocksDepositsBeforeExternalVenueCall() public {
        _depositAndDeploy(alice, 1_000e18);
        _open();
        usdt.mint(address(this), 10e18);
        IERC20(USDT).approve(address(vault), 10e18);
        venue.configureCloseCallback(address(this), abi.encodeCall(this.callbackDepositDuringClose, (10e18)));
        uint256 assetIn = venue.lastAssetIn();
        uint256 pairedIn = venue.lastPairedIn();
        venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetIn, pairedIn);

        vm.prank(keeper);
        main.closeToInventory(keccak256("CLOSE_WITH_CALLBACK"), block.timestamp + 60, false);

        assertFalse(venue.closeCallbackSucceeded(), "deposit callback must fail while close is in progress");
        assertEq(vault.balanceOf(address(this)), 0);
    }

    function callbackDepositDuringClose(uint256 assets) external {
        require(msg.sender == address(venue), "venue only");
        vault.deposit(assets, address(this));
    }
}

contract VaultBFeeAndDeploymentRemediationTest is DeployVaultBV2DryRunTest {
    function testHarvestRecordsFeeInSplitterExactlyOnce() public {
        (DedicatedVaultStrategyAdapterV2 adapter,, PartnerAttributedSplitter splitter) = _fundProfitableMain();

        vm.prank(cfg.manager);
        (uint256 profit, uint256 feeAssets) = adapter.harvest();

        assertEq(profit, 100e18);
        assertEq(feeAssets, 20e18);
        assertEq(splitter.cumulativeReceived(), feeAssets);
        assertEq(splitter.pendingProjectBaseSlice() + splitter.pendingProjectHouseSlice(), feeAssets);
        assertEq(splitter.unrecordedBalance(), 0);
        assertEq(IERC20(USDT).allowance(address(adapter), address(splitter)), 0);

        vm.prank(cfg.manager);
        (uint256 secondProfit, uint256 secondFee) = adapter.harvest();
        assertEq(secondProfit, 0);
        assertEq(secondFee, 0);
        assertEq(splitter.cumulativeReceived(), feeAssets);
    }

    function testAsyncClaimRecordsFeeInSplitterExactlyOnce() public {
        DeepYieldVaultB vault = DeepYieldVaultB(deployed.vault);
        DedicatedVaultMainV2 main = DedicatedVaultMainV2(deployed.main);
        DedicatedVaultStrategyAdapterV2 adapter = DedicatedVaultStrategyAdapterV2(deployed.adapter);
        PartnerAttributedSplitter splitter = PartnerAttributedSplitter(deployed.splitter);
        vm.prank(address(script));
        main.enableOperations();
        address user = makeAddr("async-fee-user");
        deal(USDT, user, 1_000e18);
        vm.startPrank(user);
        IERC20(USDT).approve(address(vault), 1_000e18);
        uint256 shares = vault.deposit(1_000e18, user);
        vm.stopPrank();
        uint256 deployable = adapter.maxDeployableAssets();
        vm.prank(cfg.manager);
        adapter.deploy(deployable);
        deal(USDT, address(main), adapter.accountedAssets() + 100e18);

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);
        vault.claimRedeem(requestId);

        assertEq(splitter.cumulativeReceived(), 20e18);
        assertEq(splitter.pendingProjectBaseSlice() + splitter.pendingProjectHouseSlice(), 20e18);
        assertEq(splitter.unrecordedBalance(), 0);
        vm.expectRevert(DeepYieldVaultB.RedeemRequestUnknown.selector);
        vault.claimRedeem(requestId);
        assertEq(splitter.cumulativeReceived(), 20e18);
    }

    function testDeploymentRejectsCollapsedOperationalRoles() public {
        DeployVaultBV2.Config memory bad = cfg;
        bad.keeper = bad.manager;
        vm.expectRevert(DeployVaultBV2.RoleSeparationRequired.selector);
        script._deploy(bad, address(script));

        bad = cfg;
        bad.guardian = bad.admin;
        vm.expectRevert(DeployVaultBV2.RoleSeparationRequired.selector);
        script._deploy(bad, address(script));
    }

    function testDeploymentCheckedNarrowingRejectsOverflow() public {
        DeployVaultBV2Harness harness = new DeployVaultBV2Harness();
        assertEq(harness.checkedUint16(type(uint16).max), type(uint16).max);
        assertEq(harness.checkedUint32(type(uint32).max), type(uint32).max);
        vm.expectPartialRevert(DeployVaultBV2.ConfigValueOverflow.selector);
        harness.checkedUint16(uint256(type(uint16).max) + 1);
        vm.expectPartialRevert(DeployVaultBV2.ConfigValueOverflow.selector);
        harness.checkedUint32(uint256(type(uint32).max) + 1);
    }

    function _fundProfitableMain()
        internal
        returns (DedicatedVaultStrategyAdapterV2 adapter, DedicatedVaultMainV2 main, PartnerAttributedSplitter splitter)
    {
        DeepYieldVaultB vault = DeepYieldVaultB(deployed.vault);
        main = DedicatedVaultMainV2(deployed.main);
        adapter = DedicatedVaultStrategyAdapterV2(deployed.adapter);
        splitter = PartnerAttributedSplitter(deployed.splitter);
        vm.prank(address(script));
        main.enableOperations();

        address user = makeAddr("fee-user");
        deal(USDT, user, 1_000e18);
        vm.startPrank(user);
        IERC20(USDT).approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, user);
        vm.stopPrank();
        uint256 deployable = adapter.maxDeployableAssets();
        vm.prank(cfg.manager);
        adapter.deploy(deployable);
        deal(USDT, address(main), adapter.accountedAssets() + 100e18);
    }
}
