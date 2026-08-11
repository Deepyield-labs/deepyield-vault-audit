// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

/// @notice B3-T2 — claim jamming (1-wei surplus), blacklisted-receiver escrow,
/// timelocked strategy change, and non-reverting ERC-4626 max* views.

/// @dev ERC20 with an issuer blacklist that reverts transfers to listed accounts
/// (models BSC-USD). 18 decimals.
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blacklist USD", "bUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to] && !blocked[from], "blacklisted");
        super._update(from, to, value);
    }
}

/// @dev Configurable async strategy: overpay-on-claim and revert-on-views toggles.
contract ConfigStrategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public managed;
    uint256 public overpayWei;
    bool public revertViews;
    bool public ready = true;

    constructor(IERC20 asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function setManaged(uint256 v) external {
        managed = v;
    }

    function setOverpay(uint256 v) external {
        overpayWei = v;
    }

    function setRevertViews(bool v) external {
        revertViews = v;
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
        require(!revertViews, "views down");
        return managed;
    }

    function requestWithdrawal(bytes32, uint256) external {}
    function commitWithdrawalCycle() external {}

    function claimWithdrawal(bytes32, uint256 assetsNeeded) external returns (uint256 withdrawn) {
        withdrawn = assetsNeeded + overpayWei; // may exceed the requested amount
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        if (managed >= withdrawn) managed -= withdrawn;
    }

    function cancelWithdrawal(bytes32) external {}

    function withdrawalReady(bytes32) external view returns (bool) {
        return ready;
    }

    function withdrawalCycleCommitted() external view returns (bool) {
        require(!revertViews, "views down");
        return false;
    }

    function withdrawalCycleBatchCommitted() external pure returns (bool) {
        return false;
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
        require(!revertViews, "views down");
        return true;
    }
}

contract VaultBV2ClaimReceiverRolesTest is Test {
    BlacklistToken internal token;
    DeepYieldVaultB internal vault;
    ConfigStrategy internal strat;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new BlacklistToken();
        vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
        strat = new ConfigStrategy(IERC20(address(token)), address(vault));
        vm.prank(admin);
        vault.setStrategy(address(strat)); // initial bootstrap
    }

    function _depositAndDeployToStrategy(address user, uint256 assets) internal returns (uint256 shares) {
        token.mint(user, assets);
        vm.startPrank(user);
        token.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
        // Move idle to the strategy so claims must pull (missing > 0), like a
        // deployed position. Strategy reports it and holds the funds to pay.
        vm.prank(address(vault));
        token.transfer(address(strat), assets);
        strat.setManaged(assets);
    }

    function _requestRedeemAll(address user, address receiver) internal returns (uint256 requestId) {
        uint256 bal = vault.balanceOf(user);
        vm.prank(user);
        requestId = vault.requestRedeem(bal, receiver, user);
    }

    // ── 1. a 1-wei surplus no longer jams the claim ──────────────────────────
    function test_ClaimSucceedsWhenStrategyOverpaysByOneWei() public {
        _depositAndDeployToStrategy(alice, 1_000e18);
        uint256 id = _requestRedeemAll(alice, alice);
        strat.setOverpay(1); // strategy returns 1 wei more than requested
        token.mint(address(strat), 1); // fund the 1-wei surplus it will hand back

        vault.claimRedeem(id);
        assertEq(vault.outstandingRedeemCount(), 0, "cycle closes; claim not jammed");
        assertGt(token.balanceOf(alice), 0, "receiver paid");
    }

    // ── 2. a blacklisted receiver is escrowed, not a vault-wide jam ───────────
    function test_BlacklistedReceiverEscrowsAndRecovers() public {
        _depositAndDeployToStrategy(alice, 1_000e18);
        uint256 id = _requestRedeemAll(alice, alice);
        token.setBlocked(alice, true); // alice (receiver) now cannot receive

        vault.claimRedeem(id);
        assertEq(vault.outstandingRedeemCount(), 0, "request settled; cycle not jammed");
        uint256 owed = vault.claimableAssets(alice);
        assertGt(owed, 0, "payout escrowed as claimable");
        assertEq(vault.totalClaimableAssets(), owed);

        // recover to a clean address
        address clean = makeAddr("clean");
        vm.prank(alice);
        uint256 got = vault.withdrawClaimable(clean);
        assertEq(got, owed);
        assertEq(token.balanceOf(clean), owed, "receiver recovered via a clean address");
        assertEq(vault.totalClaimableAssets(), 0);
    }

    // ── 3. strategy change is timelocked; initial set is instant ─────────────
    function test_StrategyChangeIsTimelocked() public {
        ConfigStrategy next = new ConfigStrategy(IERC20(address(token)), address(vault));

        vm.expectEmit(true, false, false, false, address(vault));
        emit DeepYieldVaultB.StrategyProposed(address(next), 0);
        vm.prank(admin);
        vault.proposeStrategy(address(next));

        vm.prank(admin);
        vm.expectPartialRevert(DeepYieldVaultB.StrategyTimelockNotElapsed.selector);
        vault.applyStrategy();

        vm.warp(block.timestamp + vault.STRATEGY_TIMELOCK());
        vm.prank(admin);
        vault.applyStrategy();
        assertEq(address(vault.strategy()), address(next));
    }

    function test_SetStrategyRejectsInstantChange() public {
        ConfigStrategy next = new ConfigStrategy(IERC20(address(token)), address(vault));
        vm.prank(admin);
        vm.expectRevert(DeepYieldVaultB.StrategyAlreadySet.selector);
        vault.setStrategy(address(next));
    }

    // ── 4. max* views fail safe to 0 when the strategy reverts; totalAssets not ─
    function test_MaxViewsFailSafeButTotalAssetsReverts() public {
        strat.setRevertViews(true);
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit returns 0, not revert");
        assertEq(vault.maxMint(alice), 0, "maxMint returns 0, not revert");
        // totalAssets is deliberately allowed to revert (silent 0 would zero the
        // share price).
        vm.expectRevert(bytes("views down"));
        vault.totalAssets();
    }

    // ── 5. regression: an honest claim to a clean receiver pays directly ─────
    function test_HonestClaimPaysReceiverDirectly() public {
        _depositAndDeployToStrategy(alice, 1_000e18);
        uint256 id = _requestRedeemAll(alice, alice);
        vault.claimRedeem(id);
        assertEq(vault.claimableAssets(alice), 0, "no escrow on the happy path");
        assertGt(token.balanceOf(alice), 0);
        assertEq(vault.outstandingRedeemCount(), 0);
    }
}
