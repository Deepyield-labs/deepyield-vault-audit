// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

contract B10Token is ERC20 {
    constructor() ERC20("USD Test", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Controllable async strategy: settable estimated NAV and reported
/// execution loss, holds no funds (the vault keeps everything idle in these tests),
/// so claims settle from idle and the finding-5 path is exercised without modelling
/// real strategy payout.
contract B10Strategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public managed;
    uint256 public execLoss;
    uint256 public chargeableLoss;
    bool public override withdrawalCycleCommitted;
    bool public allowDeposits = true;
    bool public viewsRevert;

    constructor(IERC20 asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function depositAssetSource() external view returns (address) {
        return address(this);
    }

    function setManaged(uint256 v) external {
        managed = v;
    }

    function setExecLoss(uint256 loss, uint256 chargeable) external {
        execLoss = loss;
        chargeableLoss = chargeable;
    }

    function setViewsRevert(bool v) external {
        viewsRevert = v;
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
        require(!viewsRevert, "views down");
        return managed;
    }

    function estimatedTotalAssetsUpper() external view returns (uint256) {
        require(!viewsRevert, "views down");
        return managed;
    }
    function requestWithdrawal(bytes32, uint256) external {}

    function commitWithdrawalCycle() external {
        withdrawalCycleCommitted = true;
    }

    function claimWithdrawal(bytes32, uint256 needed) external returns (uint256) {
        if (needed != 0) asset.safeTransfer(vault, needed);
        return needed;
    }
    function cancelWithdrawal(bytes32) external {}

    function withdrawalReady(bytes32) external pure returns (bool) {
        return true;
    }

    function withdrawalCycleBatchCommitted() external view returns (bool) {
        return withdrawalCycleCommitted;
    }

    function withdrawalCycleExecutionLoss() external view returns (uint256) {
        return execLoss;
    }

    function withdrawalCycleChargeableExecutionLoss() external view returns (uint256) {
        return chargeableLoss;
    }

    function availableWithdrawLimit() external view returns (uint256) {
        return viewsRevert ? 0 : managed;
    }

    function depositsAllowed() external view returns (bool) {
        require(!viewsRevert, "views down");
        return allowDeposits;
    }
}

    contract VaultBB10FindingsTest is Test {
        B10Token internal token;
        DeepYieldVaultB internal vault;
        B10Strategy internal strat;

        address internal admin = makeAddr("admin");
        address internal guardian = makeAddr("guardian");
        address internal treasury = makeAddr("treasury");
        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");

        uint256 internal minDeposit;
        uint256 internal minRedeem;

        function setUp() public {
            token = new B10Token();
            // depositCap 0 = uncapped; keeps maxDeposit on the type(uint256).max branch
            // unless a guard fires (finding 7).
            vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
            strat = new B10Strategy(IERC20(address(token)), address(vault));
            vm.prank(admin);
            vault.setStrategy(address(strat));
            minDeposit = vault.MIN_DEPOSIT();
            minRedeem = vault.MIN_REDEEM_SHARES();
        }

        function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
            token.mint(who, assets);
            vm.startPrank(who);
            token.approve(address(vault), assets);
            shares = vault.deposit(assets, who);
            vm.stopPrank();
        }

        // ── Finding 5: 100%-supply exit with >2% execution loss must still settle ──
        function test_F5_FullSupplyExitWithLossStillClaims() public {
            uint256 shares = _deposit(alice, 10 * minDeposit); // alice is 100% of supply
            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);

            // Report a loss far above the 2% cap (on the ~10-token snapshot).
            strat.setExecLoss(5 * minDeposit, 0); // 50% > 2%
            vault.commitRedeemCycle();

            // Preview and the real claim must agree (finding 5 also fixed the desync).
            uint256 preview = vault.claimableRedeemRequest(reqId);
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId); // must NOT revert (was a permanent freeze)
            assertGt(claimed, 0, "100% exit settles despite >2% loss");
            assertEq(preview, claimed, "claimableRedeemRequest matches the actual claim");
        }

        // ── Finding 7: zero NAV with live supply blocks deposits ──────────────────
        function test_F7_ZeroNavBlocksDeposit() public {
            _deposit(alice, 10 * minDeposit);
            // Drain all idle out of the vault and leave the strategy at zero: NAV == 0,
            // supply > 0. (Simulate a wipe.)
            uint256 idle = token.balanceOf(address(vault));
            vm.prank(address(vault));
            token.transfer(address(0xdead), idle);
            strat.setManaged(0);
            assertEq(vault.totalAssets(), 0, "NAV is zero");
            assertGt(vault.totalSupply(), 0, "shares still exist");

            assertEq(vault.maxDeposit(bob), 0, "insolvency blocks maxDeposit");
            assertEq(vault.maxMint(bob), 0, "insolvency blocks maxMint");
        }

        function test_F7_StrategyOutageStillZeroNotInsolvency() public {
            _deposit(alice, 10 * minDeposit);
            strat.setViewsRevert(true); // estimatedTotalAssets reverts → outage, not insolvency
            // The wrapper must return 0 (not revert) — a distinct path from the guard.
            assertEq(vault.maxDeposit(bob), 0, "strategy outage returns 0 via wrapper");
            assertEq(vault.maxMint(bob), 0, "strategy outage returns 0 via wrapper");
        }

        // ── Finding 8: commit threshold is snapshotted at queue-open ───────────────
        function test_F8_ThresholdBaseFrozenAtQueueOpen() public {
            uint256 aShares = _deposit(alice, 10 * minDeposit);
            vm.prank(alice);
            vault.requestRedeem(aShares, alice, alice); // opens the queue, snapshots base

            uint256 thresholdBefore = vault.commitThresholdShares();

            // Bob inflates supply after the queue opened.
            _deposit(bob, 1_000 * minDeposit);

            uint256 thresholdAfter = vault.commitThresholdShares();
            assertEq(thresholdAfter, thresholdBefore, "threshold does not move with post-open deposits");
            assertEq(vault.redeemCycleThresholdBase(), aShares, "base is the queue-open supply");
        }

        // ── Finding 9: reaching the queue cap commits atomically ──────────────────
        function test_F9_FullQueueCommitsInsteadOfRejectingTheNextRequest() public {
            _deposit(alice, 2 * minDeposit);
            // Fill the queue to the default cap (64) with distinct addresses.
            uint256 cap = vault.maxPendingRedeems();
            for (uint256 i; i < cap; ++i) {
                address sybil = address(uint160(0x5150 + i));
                _deposit(sybil, 2 * minDeposit); // > MIN_REDEEM_SHARES
                vm.prank(sybil);
                vault.requestRedeem(minRedeem, sybil, sybil);
            }
            assertTrue(vault.redeemCycleCommitted(), "the final admitted slot commits in the same transaction");

            // The queue is now a settling batch. Raising the next-cycle cap cannot
            // reopen it or admit a request into the committed snapshot.
            vm.prank(admin);
            vault.setMaxPendingRedeems(cap + 8);
            vm.prank(alice);
            vm.expectRevert(DeepYieldVaultB.RedeemCycleLocked.selector);
            vault.requestRedeem(minRedeem, alice, alice);

            // The ceiling is hard.
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(DeepYieldVaultB.InvalidMaxPendingRedeems.selector, 257));
            vault.setMaxPendingRedeems(257);
        }
    }
