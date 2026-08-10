// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {DedicatedVaultStrategyAdapterV2} from "../src/DedicatedVaultStrategyAdapterV2.sol";
import {IFeeSink} from "../src/interfaces/IFeeSink.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";
import {
    MockMainV2Token,
    MockMainV2PriceGuard,
    MockMainV2ExecutionAdapter,
    MockMainV2RewardAdapter,
    MockMainV2Venue
} from "./VaultBMainV2.t.sol";

contract MockVaultBFeeSink is IFeeSink {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    uint256 public cumulativeReceived;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function recordFee(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        cumulativeReceived += amount;
    }
}

contract MockAsyncDestinationStrategy is IVaultBAsyncStrategy {
    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public managed;
    bool public allowDeposits = true;
    bool public override withdrawalCycleCommitted;

    constructor(IERC20 asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function setManaged(uint256 value) external {
        managed = value;
    }

    function deploy(uint256) external {}

    function withdrawToVault(uint256) external pure returns (uint256) {
        return 0;
    }

    function managerWithdrawAll() external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (uint256, uint256) {
        return (0, 0);
    }
    function panic() external {}

    function estimatedTotalAssets() external view returns (uint256) {
        return managed;
    }
    function requestWithdrawal(bytes32, uint256) external {}

    function commitWithdrawalCycle() external {
        withdrawalCycleCommitted = true;
    }

    function claimWithdrawal(bytes32, uint256) external pure returns (uint256) {
        return 0;
    }
    function cancelWithdrawal(bytes32) external {}

    function withdrawalReady(bytes32) external pure returns (bool) {
        return true;
    }

    function withdrawalCycleBatchCommitted() external view returns (bool) {
        return withdrawalCycleCommitted;
    }

    function withdrawalCycleExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function withdrawalCycleChargeableExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function availableWithdrawLimit() external pure returns (uint256) {
        return 0;
    }

    function depositsAllowed() external view returns (bool) {
        return allowDeposits;
    }
}

    contract VaultBAsyncRedeemV2Test is Test {
        address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
        address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

        address internal admin = makeAddr("admin");
        address internal manager = makeAddr("manager");
        address internal keeper = makeAddr("keeper");
        address internal guardian = makeAddr("guardian");
        address internal feeRecipient = makeAddr("feeRecipient");
        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");

        MockMainV2Token internal usdt;
        MockMainV2Token internal wbnb;
        MockMainV2Token internal cake;
        MockMainV2PriceGuard internal guard;
        MockMainV2PriceGuard internal rewardGuard;
        MockMainV2ExecutionAdapter internal executor;
        MockMainV2RewardAdapter internal rewardExecutor;
        MockMainV2Venue internal venue;
        MockVaultBFeeSink internal feeSink;
        DeepYieldVaultB internal vault;
        DedicatedVaultMainV2 internal main;
        DedicatedVaultStrategyAdapterV2 internal adapter;
        uint256 internal jobNonce;

        function setUp() public {
            vm.chainId(56);
            vm.warp(10 days);
            _etchToken(USDT);
            _etchToken(WBNB);
            _etchToken(CAKE);
            usdt = MockMainV2Token(USDT);
            wbnb = MockMainV2Token(WBNB);
            cake = MockMainV2Token(CAKE);
            feeSink = new MockVaultBFeeSink(IERC20(USDT));
            feeRecipient = address(feeSink);

            vault = new DeepYieldVaultB(
                IERC20(USDT), "DeepYield Vault B V2", "dyBV2", admin, guardian, feeRecipient, 50_000e18
            );
            guard = new MockMainV2PriceGuard();
            rewardGuard = new MockMainV2PriceGuard();
            executor = new MockMainV2ExecutionAdapter(address(this), guard);
            rewardExecutor = new MockMainV2RewardAdapter(address(this), rewardGuard);
            venue = new MockMainV2Venue(IERC20(USDT), IERC20(WBNB));

            uint64 nonce = vm.getNonce(address(this));
            address predictedMain = vm.computeCreateAddress(address(this), nonce);
            address predictedAdapter = vm.computeCreateAddress(address(this), nonce + 1);
            main = new DedicatedVaultMainV2({
                vault_: predictedAdapter,
                venue_: venue,
                executionAdapter_: executor,
                priceGuard_: guard,
                rewardExecutionAdapter_: rewardExecutor,
                rewardPriceGuard_: rewardGuard,
                rewardToken_: IERC20(CAKE),
                mintLossBps_: 100,
                normalCloseLossBps_: 100,
                emergencyCloseLossBps_: 1_000,
                hardMaxActiveAssets_: 50_000e18,
                hardMaxSwapPerJob_: 50_000e18,
                hardDailySwapLimit_: 100_000e18,
                initialCanaryOpenCap_: 1_000e18,
                initialSwapPerJobCap_: 1_000e18,
                initialDailySwapLimit_: 2_000e18,
                admin_: admin,
                keeper_: keeper,
                guardian_: guardian
            });
            assertEq(address(main), predictedMain);
            adapter = new DedicatedVaultStrategyAdapterV2(
                IERC20(USDT), address(vault), main, admin, manager, guardian, feeRecipient, 2_000
            );
            assertEq(address(adapter), predictedAdapter);

            executor.bindMain(address(main));
            rewardExecutor.bindMain(address(main));
            venue.bindController(address(main));
            usdt.mint(address(executor), 100_000e18);
            usdt.mint(address(rewardExecutor), 100_000e18);
            wbnb.mint(address(executor), 100_000e18);

            bytes32 mainGuardianRole = main.GUARDIAN_ROLE();
            vm.prank(admin);
            main.grantRole(mainGuardianRole, address(adapter));
            vm.prank(admin);
            vault.setStrategy(address(adapter));
            vm.prank(admin);
            main.enableOperations();
        }

        function testSynchronousRedeemRemainsStrictErc4626WhenMainIsLiquid() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            uint256 expected = vault.previewRedeem(shares);
            assertEq(vault.maxRedeem(alice), shares);

            vm.prank(alice);
            uint256 received = vault.redeem(shares, alice, alice);

            assertEq(received, expected);
            assertEq(usdt.balanceOf(alice), expected);
            assertEq(main.queuedWithdrawalCount(), 0);
        }

        function testRequestDoesNotReadBrokenOracleAndEscrowsShares() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            _open();
            guard.setFail(true);

            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares / 2, alice, alice);

            assertEq(requestId, 0);
            assertEq(vault.balanceOf(alice), shares - shares / 2);
            assertEq(vault.balanceOf(address(vault)), shares / 2);
            assertEq(vault.outstandingRedeemShares(), shares / 2);
            assertEq(main.queuedWithdrawalCount(), 1);
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));
            assertFalse(vault.redeemCycleCommitted());
            assertFalse(main.withdrawalCycleCommitted());
        }

        function testActiveRedeemQueuesThenClaimsAtCurrentNavAfterInventoryIsCleared() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            _open();
            assertGt(vault.maxRedeem(alice), 0, "the enforced idle reserve remains synchronously redeemable");

            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares / 2, alice, alice);
            vault.commitRedeemCycle();
            vm.expectRevert(DeepYieldVaultB.RedeemNotReady.selector);
            vault.claimRedeem(requestId);

            _closeAndLiquidate();
            uint256 expected = vault.previewRedeem(shares / 2);
            uint256 received = vault.claimRedeem(requestId);

            assertEq(received, expected);
            assertEq(usdt.balanceOf(alice), expected);
            assertEq(vault.outstandingRedeemShares(), 0);
            assertEq(main.queuedWithdrawalCount(), 0);
            assertEq(vault.totalSupply(), shares - shares / 2);
        }

        function testQueueClaimsAreOrderIndependentAndBlockDepositsAndSynchronousExit() public {
            uint256 aliceShares = _deposit(alice, 500e18);
            uint256 bobShares = _deposit(bob, 500e18);
            _deploy(adapter.maxDeployableAssets());
            _open();

            vm.prank(alice);
            uint256 first = vault.requestRedeem(aliceShares, alice, alice);
            vm.prank(bob);
            uint256 second = vault.requestRedeem(bobShares, bob, bob);
            vault.commitRedeemCycle();

            assertEq(vault.maxDeposit(alice), 0);
            usdt.mint(alice, 10e18);
            vm.startPrank(alice);
            IERC20(USDT).approve(address(vault), 10e18);
            vm.expectPartialRevert(DeepYieldVaultB.RedeemQueueActive.selector);
            vault.deposit(10e18, alice);
            vm.expectPartialRevert(DeepYieldVaultB.RedeemQueueActive.selector);
            vault.redeem(1, alice, alice);
            vm.stopPrank();

            _closeAndLiquidate();
            uint256 bobExpected = vault.previewRedeem(bobShares);
            assertEq(vault.claimRedeem(second), bobExpected, "later request cannot be blocked by an earlier receiver");
            vault.claimRedeem(first);
            assertEq(vault.outstandingRedeemCount(), 0);
        }

        function testClaimCrystallizesFeeOnceAndPaysClaimTimeNetNav() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            usdt.mint(address(main), 100e18);
            (uint256 profit, uint256 feeAssets) = adapter.pendingPerformanceFee();
            assertEq(profit, 100e18);
            assertEq(feeAssets, 20e18);

            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares, alice, alice);
            uint256 expected = vault.previewRedeem(shares);
            uint256 received = vault.claimRedeem(requestId);

            assertEq(received, expected);
            assertEq(usdt.balanceOf(feeRecipient), 20e18);
            assertEq(adapter.accountedAssets(), usdt.balanceOf(address(main)));
            assertLe(adapter.accountedAssets(), 1, "only ERC-4626 virtual-offset dust may remain");
            assertEq(main.queuedWithdrawalCount(), 0);
            vm.expectRevert(DeepYieldVaultB.RedeemRequestUnknown.selector);
            vault.claimRedeem(requestId);
        }

        function testOnePendingRequestPerOwnerAndMinimumSizePreventQueueSpam() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            uint256 minimum = vault.MIN_REDEEM_SHARES();

            vm.prank(alice);
            vm.expectPartialRevert(DeepYieldVaultB.RedeemBelowMinimum.selector);
            vault.requestRedeem(minimum - 1, alice, alice);

            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(minimum, alice, alice);
            vm.prank(alice);
            vm.expectPartialRevert(DeepYieldVaultB.PendingRequestExists.selector);
            vault.requestRedeem(minimum, alice, alice);
            assertEq(vault.pendingRequestPlusOne(alice), requestId + 1);
            assertEq(vault.balanceOf(alice), shares - minimum);
        }

        function testReceiverCanBeUpdatedAndOnlyOwnerCanCancelBeforeCommit() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares / 2, bob, alice);

            vm.prank(bob);
            vm.expectRevert(DeepYieldVaultB.RedeemRequestUnknown.selector);
            vault.updateRedeemReceiver(requestId, bob);
            vm.prank(alice);
            vault.updateRedeemReceiver(requestId, alice);

            vm.prank(bob);
            vm.expectRevert(DeepYieldVaultB.NotRedeemOwner.selector);
            vault.cancelRedeem(requestId);
            vm.prank(alice);
            vault.cancelRedeem(requestId);

            assertEq(vault.balanceOf(alice), shares, "escrow always returns to original owner");
            assertEq(vault.balanceOf(bob), 0);
            assertEq(vault.outstandingRedeemCount(), 0);
            assertEq(main.queuedWithdrawalCount(), 0);
            (, DedicatedVaultMainV2.WithdrawalStatus status) = main.withdrawals(vault.strategyRequestId(requestId));
            assertEq(uint256(status), uint256(DedicatedVaultMainV2.WithdrawalStatus.CANCELED));
        }

        function testPendingQueueHasHardSybilBound() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            uint256 minimum = vault.MIN_REDEEM_SHARES();
            uint256 limit = vault.MAX_PENDING_REDEEMS();
            assertGt(shares, minimum * (limit + 1));

            for (uint256 i; i < limit; ++i) {
                address requester = address(uint160(10_000 + i));
                vm.prank(alice);
                vault.transfer(requester, minimum);
                vm.prank(requester);
                vault.requestRedeem(minimum, requester, requester);
            }
            assertEq(vault.outstandingRedeemCount(), limit);
            assertEq(main.queuedWithdrawalCount(), limit);

            address overflow = address(uint160(20_000));
            vm.prank(alice);
            vault.transfer(overflow, minimum);
            vm.prank(overflow);
            vm.expectRevert(DeepYieldVaultB.RedeemQueueFull.selector);
            vault.requestRedeem(minimum, overflow, overflow);
        }

        function testPausedVaultStillAcceptsAndSettlesQueuedExit() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            _open();
            vm.prank(guardian);
            vault.pause();

            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            _closeAndLiquidate();
            vault.claimRedeem(requestId);

            assertEq(vault.balanceOf(alice), 0);
            assertGt(usdt.balanceOf(alice), 0);
        }

        function testClosedToInventoryBlocksDepositsUntilAdminReenablesMain() public {
            uint256 shares = _depositAndDeploy(alice, 1_000e18);
            _open();
            vm.prank(alice);
            uint256 requestId = vault.requestRedeem(shares / 2, alice, alice);
            vault.commitRedeemCycle();
            _closeAndLiquidate();
            vault.claimRedeem(requestId);

            assertEq(vault.outstandingRedeemShares(), 0);
            assertEq(vault.maxDeposit(bob), 0, "Main remains explicitly closed after withdrawal cycle");
            vm.prank(admin);
            main.enableOperations();
            assertGt(vault.maxDeposit(bob), 0);
        }

        function testAdapterPanicLeavesMainHaltedAfterEmergencyLpClose() public {
            _depositAndDeploy(alice, 1_000e18);
            _open();
            uint256 assetIn = venue.lastAssetIn();
            uint256 pairedIn = venue.lastPairedIn();
            venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetIn, pairedIn);

            vm.prank(guardian);
            adapter.panic();

            assertEq(main.activePositionId(), 0);
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED));
            assertEq(wbnb.balanceOf(address(main)), pairedIn, "panic closes custody before later bounded liquidation");
            assertEq(address(main).balance, 0);
        }

        function testStrategyCutoverRequiresEmptyCurrentAndPreservesSharesAndNav() public {
            uint256 shares = _deposit(alice, 1_000e18);
            MockAsyncDestinationStrategy destination = new MockAsyncDestinationStrategy(IERC20(USDT), address(vault));

            uint256 supplyBefore = vault.totalSupply();
            uint256 userSharesBefore = vault.balanceOf(alice);
            uint256 navBefore = vault.totalAssets();
            vm.prank(admin);
            vault.setStrategy(address(destination));

            assertEq(vault.totalSupply(), supplyBefore);
            assertEq(vault.balanceOf(alice), userSharesBefore);
            assertEq(vault.totalAssets(), navBefore);
            assertEq(shares, userSharesBefore);
        }

        function testStrategyCutoverRejectsNonEmptyCurrentAndWrongDestinationWiring() public {
            _depositAndDeploy(alice, 1_000e18);
            MockAsyncDestinationStrategy destination = new MockAsyncDestinationStrategy(IERC20(USDT), address(vault));
            vm.prank(admin);
            vm.expectRevert(DeepYieldVaultB.StrategyNotEmpty.selector);
            vault.setStrategy(address(destination));

            vm.prank(manager);
            adapter.managerWithdrawAll();
            MockAsyncDestinationStrategy wrong = new MockAsyncDestinationStrategy(IERC20(USDT), bob);
            vm.prank(admin);
            vm.expectRevert(DeepYieldVaultB.StrategyWiringMismatch.selector);
            vault.setStrategy(address(wrong));
        }

        function _depositAndDeploy(address user, uint256 assets) internal returns (uint256 shares) {
            shares = _deposit(user, assets);
            _deploy(adapter.maxDeployableAssets());
        }

        function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
            usdt.mint(user, assets);
            vm.startPrank(user);
            IERC20(USDT).approve(address(vault), assets);
            shares = vault.deposit(assets, user);
            vm.stopPrank();
        }

        function _deploy(uint256 assets) internal {
            vm.prank(manager);
            adapter.deploy(assets);
        }

        function _open() internal {
            uint256 budget = usdt.balanceOf(address(main));
            uint256 swapIn = budget / 2;
            uint256 assetForMint = budget - swapIn;
            bytes32 jobId = keccak256(abi.encode("OPEN", ++jobNonce));
            vm.prank(keeper);
            main.openPosition(
                DedicatedVaultMainV2.OpenParams({
                    jobId: jobId,
                    tickLower: -100,
                    tickUpper: 100,
                    assetBudget: budget,
                    swapAssetIn: swapIn,
                    keeperPairedMinOut: 1,
                    deadline: block.timestamp + 60
                })
            );
            venue.configureClose(assetForMint, swapIn, assetForMint, swapIn, assetForMint, swapIn);
        }

        function _closeAndLiquidate() internal {
            guard.setFail(false);
            uint256 assetIn = venue.lastAssetIn();
            uint256 pairedIn = venue.lastPairedIn();
            venue.configureClose(assetIn, pairedIn, assetIn, pairedIn, assetIn, pairedIn);
            vm.prank(keeper);
            main.closeToInventory(keccak256(abi.encode("CLOSE", block.number)), block.timestamp + 60, false);
            vm.prank(keeper);
            main.liquidateAllWbnb(keccak256(abi.encode("SELL", block.number)), 0, 1, block.timestamp + 60, true, false);
        }

        function _etchToken(address target) internal {
            MockMainV2Token template = new MockMainV2Token();
            vm.etch(target, address(template).code);
        }
    }
