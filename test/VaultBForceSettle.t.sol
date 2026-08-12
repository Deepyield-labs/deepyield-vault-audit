// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

contract FSToken is ERC20 {
    constructor() ERC20("USD Test", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Strategy whose readiness source can break IRREVERSIBLY: once `broken`,
/// EVERY external call reverts (the failure B11-T3 recovers from). `managed` models
/// the deployed NAV; the deployed capital is held here and cannot be returned once
/// broken. The vault keeps the rest idle.
contract BreakableStrategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public managed;
    bool public broken;
    bool public committedFlag;

    constructor(IERC20 a, address v) {
        asset = a;
        vault = v;
    }

    function depositAssetSource() external view returns (address) {
        return address(this);
    }

    function setManaged(uint256 v) external {
        managed = v;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    modifier live() {
        require(!broken, "strategy down");
        _;
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

    function estimatedTotalAssets() external view live returns (uint256) {
        return managed;
    }

    function estimatedTotalAssetsUpper() external view live returns (uint256) {
        return managed;
    }
    function requestWithdrawal(bytes32, uint256) external live {}

    function commitWithdrawalCycle() external live {
        committedFlag = true;
    }

    function commitWithVaultSnapshot() external live {
        DeepYieldVaultB(vault).prepareRedeemCycleCommit();
        committedFlag = true;
    }

    function claimWithdrawal(bytes32, uint256 needed) external live returns (uint256) {
        if (needed != 0) asset.safeTransfer(vault, needed);
        return needed;
    }
    function cancelWithdrawal(bytes32) external live {}

    function withdrawalReady(bytes32) external view live returns (bool) {
        return true;
    }

    function withdrawalCycleCommitted() external view live returns (bool) {
        return committedFlag;
    }

    function withdrawalCycleBatchCommitted() external view live returns (bool) {
        return committedFlag;
    }

    function withdrawalCycleExecutionLoss() external view live returns (uint256) {
        return 0;
    }

    function withdrawalCycleChargeableExecutionLoss() external view live returns (uint256) {
        return 0;
    }

    function availableWithdrawLimit() external view live returns (uint256) {
        return managed;
    }

    function depositsAllowed() external view live returns (bool) {
        return true;
    }
}

    contract VaultBForceSettleTest is Test {
        FSToken internal token;
        DeepYieldVaultB internal vault;
        BreakableStrategy internal strat;

        address internal admin = makeAddr("admin");
        address internal guardian = makeAddr("guardian");
        address internal treasury = makeAddr("treasury");
        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");
        address internal randomer = makeAddr("randomer");

        uint256 internal minDeposit;

        function setUp() public {
            token = new FSToken();
            vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
            strat = new BreakableStrategy(IERC20(address(token)), address(vault));
            vm.prank(admin);
            vault.setStrategy(address(strat)); // pristine vault → immediate (B11-T2)
            minDeposit = vault.MIN_DEPOSIT();
        }

        function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
            token.mint(who, assets);
            vm.startPrank(who);
            token.approve(address(vault), assets);
            shares = vault.deposit(assets, who);
            vm.stopPrank();
        }

        /// Deploy `amount` of the vault's idle to the strategy (models a keeper deploy).
        function _deployToStrategy(uint256 amount) internal {
            vm.prank(address(vault));
            token.transfer(address(strat), amount);
            strat.setManaged(strat.managed() + amount);
        }

        // ── (1) broken source + timeout → anyone force-settles; the batch exits. ──
        function test_ForceSettleAfterTimeoutLetsBatchExit() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit); // 100% of supply, all idle
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle(); // healthy: snapshot + committedAt frozen
            strat.setBroken(true); // readiness source dies irreversibly

            // Before recovery the claim is stuck forever (the strategy reverts).
            vm.prank(alice);
            vm.expectRevert(); // strategy down
            vault.claimRedeem(reqId);

            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vm.prank(randomer); // permissionless
            vault.forceSettleStuckCycle();

            uint256 before = token.balanceOf(alice);
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId);
            assertGt(claimed, 0, "batch exits after force-settle");
            assertEq(token.balanceOf(alice) - before, claimed, "receiver paid");
            assertEq(vault.outstandingRedeemCount(), 0, "cycle closed");
        }

        // ── (2) before the timeout, force-settle reverts. ────────────────────────
        function test_ForceSettleBeforeTimeoutReverts() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT() - 1);
            vm.expectRevert();
            vault.forceSettleStuckCycle();
        }

        // ── (3) the force path calls the strategy ZERO times (all-revert scenario). ─
        function test_ForcePathCallsStrategyZeroTimes() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            strat.setBroken(true); // every strategy call now reverts
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            // If force-settle or claim touched the strategy, these would revert "strategy down".
            vault.forceSettleStuckCycle();
            vm.prank(alice);
            vault.claimRedeem(reqId);
            assertEq(vault.outstandingRedeemCount(), 0, "settled without a single strategy call");
        }

        function test_ClaimablePreviewUsesLocalForceSettlement() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vault.forceSettleStuckCycle();

            assertEq(vault.claimableRedeemRequest(reqId), vault.redeemCyclePayoutAssets());
        }

        function test_AutomaticCommitFreezesRecoverySnapshotFirst() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);

            strat.commitWithVaultSnapshot();
            assertGt(vault.redeemCycleCommittedAt(), 0);
            assertEq(vault.redeemCycleCommittedShares(), shares);

            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vault.forceSettleStuckCycle();
            vm.prank(alice);
            assertGt(vault.claimRedeem(reqId), 0);
        }

        // ── (4) idle below the batch's fair share → pay min, shortfall acknowledged. ─
        function test_IdleBelowSharePaysMinWithShortfall() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            _deployToStrategy(600 * minDeposit); // idle 400, managed 600, NAV 1000
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle(); // assetsSnapshot = 1000
            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vault.forceSettleStuckCycle();
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId);
            assertEq(claimed, 400 * minDeposit, "paid min(fair share 1000, idle 400) = 400");
        }

        // ── (5) money the venue returns AFTER force-settle goes to remaining holders. ─
        function test_LateMoneyGoesToRemainingHolders() public {
            uint256 aShares = _deposit(alice, 500 * minDeposit);
            _deposit(bob, 500 * minDeposit); // bob stays in
            _deployToStrategy(600 * minDeposit); // idle 400, managed 600
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(aShares, alice, alice); // batch = alice (50%)
            vault.commitRedeemCycle();
            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vault.forceSettleStuckCycle();
            uint256 payoutFixed = vault.redeemCyclePayoutAssets();
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId);
            assertEq(claimed, payoutFixed, "alice paid the fixed force-settle payout");
            assertEq(vault.outstandingRedeemCount(), 0, "batch fully settled at the capped payout");

            // The venue "recovers" and returns funds to the vault AFTER settlement.
            uint256 idleBefore = token.balanceOf(address(vault));
            token.mint(address(vault), 600 * minDeposit);
            // The late money is NOT owed to the exited batch (no outstanding redeem, nothing
            // escrowed) — it is shareholder value for the remaining holder (bob).
            assertEq(vault.totalClaimableAssets(), 0, "late money not escrowed to the batch");
            assertEq(
                token.balanceOf(address(vault)) - idleBefore, 600 * minDeposit, "late money held for remaining holders"
            );
        }

        // ── (6) deposits + sync exit stay closed until the cycle is normally cleared. ─
        function test_DepositsAndSyncExitStayClosedUntilCleared() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            strat.setBroken(true);
            vm.warp(block.timestamp + vault.REDEEM_CYCLE_TIMEOUT());
            vault.forceSettleStuckCycle();
            // Still committed until claimed: deposits and synchronous exit are shut.
            assertEq(vault.maxDeposit(bob), 0, "deposits closed while the cycle is open");
            assertEq(vault.maxRedeem(alice), 0, "sync exit closed while the cycle is open");
            // Normal close via claim clears the cycle lock. Checked via strategy-free
            // getters: once the local commit flag is off, redeemCycleCommitted() itself
            // calls the (broken) strategy, so the cleared state is read from these instead.
            vm.prank(alice);
            vault.claimRedeem(reqId);
            assertEq(vault.outstandingRedeemCount(), 0, "cycle closed after the last claim");
            assertEq(vault.redeemCycleCommittedAt(), 0, "recovery clock reset");
            assertFalse(vault.redeemCycleForceSettled(), "force flag reset");
        }

        // ── (7) a normal, healthy cycle is unaffected (regression). ───────────────
        function test_NormalCycleStillWorks() public {
            uint256 shares = _deposit(alice, 1_000 * minDeposit);
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();
            // Strategy healthy: the normal claim path settles (no force).
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId);
            assertGt(claimed, 0, "healthy cycle settles normally");
            assertFalse(vault.redeemCycleForceSettled(), "no force path used");
        }
    }
