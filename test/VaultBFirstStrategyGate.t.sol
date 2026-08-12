// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {B10T2Token, B10T2Strategy} from "./VaultBB10T2NavDirectional.t.sol";

/// @notice B11-T2: the FIRST strategy activation grants an unlimited allowance. It is
/// only immediate on a pristine vault; once shares or assets exist it must go through
/// the same timelock as a strategy change, so holders can exit before an arbitrary
/// contract is wired in.
contract VaultBFirstStrategyGateTest is Test {
    B10T2Token internal token;
    DeepYieldVaultB internal vault;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new B10T2Token();
        vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
    }

    function _strategy() internal returns (B10T2Strategy) {
        return new B10T2Strategy(IERC20(address(token)), address(vault));
    }

    function _deposit(address who, uint256 assets) internal {
        token.mint(who, assets);
        vm.startPrank(who);
        token.approve(address(vault), assets);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    // (1) A deposit while the strategy is unset blocks an immediate first activation.
    function test_DepositThenSetStrategyReverts() public {
        _deposit(alice, 10 * vault.MIN_DEPOSIT()); // supply > 0, strategy still unset
        B10T2Strategy strat = _strategy();
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.VaultNotEmpty.selector);
        vault.setStrategy(address(strat));
        assertEq(token.allowance(address(vault), address(strat)), 0, "no unlimited allowance granted");
        assertEq(address(vault.strategy()), address(0), "strategy still unset");
    }

    // (2) On a pristine vault the first activation is immediate.
    function test_EmptyVaultFirstActivationImmediate() public {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        B10T2Strategy strat = _strategy();
        vm.prank(admin);
        vault.setStrategy(address(strat));
        assertEq(address(vault.strategy()), address(strat), "strategy activated");
        assertEq(token.allowance(address(vault), address(strat)), type(uint256).max, "allowance granted");
    }

    // (3) A non-empty vault activates its first strategy through the timelock.
    function test_NonEmptyVaultFirstActivationViaTimelock() public {
        _deposit(alice, 10 * vault.MIN_DEPOSIT());
        B10T2Strategy strat = _strategy();
        vm.prank(admin);
        vault.proposeStrategy(address(strat));
        vm.prank(admin);
        vm.expectPartialRevert(DeepYieldVaultB.StrategyTimelockNotElapsed.selector);
        vault.applyStrategy();
        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());
        vm.prank(admin);
        vault.applyStrategy();
        assertEq(address(vault.strategy()), address(strat), "first strategy set via timelock on a funded vault");
    }

    // (4) Changing an already-set strategy still requires the timelock (unchanged).
    function test_StrategyChangeStillTimelocked() public {
        B10T2Strategy s1 = _strategy();
        vm.prank(admin);
        vault.setStrategy(address(s1)); // pristine vault → immediate
        B10T2Strategy s2 = _strategy();
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.StrategyAlreadySet.selector);
        vault.setStrategy(address(s2)); // setStrategy is first-activation only
        vm.prank(admin);
        vault.proposeStrategy(address(s2));
        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());
        vm.prank(admin);
        vault.applyStrategy();
        assertEq(address(vault.strategy()), address(s2), "change applied via timelock");
    }

    function test_PendingStrategyBlocksNewCapitalUntilCanceled() public {
        B10T2Strategy strat = _strategy();
        vm.prank(admin);
        vault.proposeStrategy(address(strat));
        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());

        uint256 assets = 10 * vault.MIN_DEPOSIT();
        token.mint(alice, assets);
        vm.startPrank(alice);
        token.approve(address(vault), assets);
        assertEq(vault.maxDeposit(alice), 0, "pending proposal blocks new capital");
        assertEq(vault.maxMint(alice), 0, "pending proposal blocks share-targeted minting");
        vm.expectRevert(DeepYieldVaultB.DepositCapExceeded.selector);
        vault.deposit(assets, alice);
        uint256 mintShares = vault.MIN_DEPOSIT();
        vm.expectRevert();
        vault.mint(mintShares, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.cancelStrategyProposal();
        assertEq(vault.pendingStrategy(), address(0));
        assertEq(vault.pendingStrategyReadyAt(), 0);
        vm.prank(admin);
        vault.cancelStrategyProposal(); // idempotent emergency cleanup

        vm.prank(alice);
        vault.deposit(assets, alice);
        assertGt(vault.balanceOf(alice), 0, "capital is admitted only after proposal cancellation");
    }

    function test_OnlyAdminCanCancelStrategyProposal() public {
        B10T2Strategy strat = _strategy();
        vm.prank(admin);
        vault.proposeStrategy(address(strat));

        vm.prank(alice);
        vm.expectRevert();
        vault.cancelStrategyProposal();
        assertEq(vault.pendingStrategy(), address(strat));
    }

    function test_ProposalPinsAssetSourceUntilApply() public {
        B10T2Strategy strat = _strategy();
        B10T2Strategy otherSource = _strategy();
        vm.prank(admin);
        vault.proposeStrategy(address(strat));

        strat.setDepositAssetSource(address(otherSource));
        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.StrategyWiringMismatch.selector);
        vault.applyStrategy();

        assertEq(address(vault.strategy()), address(0));
        assertEq(vault.pendingStrategy(), address(strat));
    }

    function test_InvalidAssetSourceCannotBeActivated() public {
        B10T2Strategy strat = _strategy();
        strat.setDepositAssetSource(address(0));
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.InvalidStrategyAssetSource.selector);
        vault.setStrategy(address(strat));

        strat.setDepositAssetSource(alice);
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.InvalidStrategyAssetSource.selector);
        vault.setStrategy(address(strat));
    }

    function test_StrategyChangeChecksPinnedAssetBalance() public {
        B10T2Strategy current = _strategy();
        vm.prank(admin);
        vault.setStrategy(address(current));
        token.mint(address(current), 1);
        current.setNav(0, 0);

        B10T2Strategy replacement = _strategy();
        vm.prank(admin);
        vault.proposeStrategy(address(replacement));
        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.StrategyNotEmpty.selector);
        vault.applyStrategy();
    }
}
