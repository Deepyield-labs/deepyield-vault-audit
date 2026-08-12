// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

/// @notice P1-T1 part 2 — maxWithdraw/maxRedeem must not revert just because the
/// strategy's liquidity query fails; they degrade to the immediately-idle
/// balance. totalAssets is deliberately left able to revert (B3-T2).

contract Token is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Strategy with independent revert toggles: `revertLimit` fails only the
/// liquidity query; `revertViews` fails estimatedTotalAssets (a full outage).
contract FlakyStrategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public managed;
    uint256 public limit;
    bool public revertLimit;
    bool public revertViews;

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

    function setLimit(uint256 v) external {
        limit = v;
    }

    function setRevertLimit(bool v) external {
        revertLimit = v;
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

    function estimatedTotalAssetsUpper() external view returns (uint256) {
        require(!revertViews, "views down");
        return managed;
    }

    function requestWithdrawal(bytes32, uint256) external {}
    function commitWithdrawalCycle() external {}

    function claimWithdrawal(bytes32, uint256 assetsNeeded) external returns (uint256 withdrawn) {
        withdrawn = assetsNeeded;
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        if (managed >= withdrawn) managed -= withdrawn;
    }
    function cancelWithdrawal(bytes32) external {}

    function withdrawalReady(bytes32) external pure returns (bool) {
        return true;
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

    function availableWithdrawLimit() external view returns (uint256) {
        require(!revertLimit, "limit down");
        return limit;
    }

    function depositsAllowed() external view returns (bool) {
        require(!revertViews, "views down");
        return true;
    }
}

    contract VaultBV2MaxViewsFailSafeTest is Test {
        Token internal token;
        DeepYieldVaultB internal vault;
        FlakyStrategy internal strat;

        address internal admin = makeAddr("admin");
        address internal guardian = makeAddr("guardian");
        address internal treasury = makeAddr("treasury");
        address internal alice = makeAddr("alice");

        function setUp() public {
            token = new Token();
            vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
            strat = new FlakyStrategy(IERC20(address(token)), address(vault));
            vm.prank(admin);
            vault.setStrategy(address(strat));

            // Alice deposits 1000; move 600 to the strategy, leave 400 idle.
            token.mint(alice, 1_000e18);
            vm.startPrank(alice);
            token.approve(address(vault), 1_000e18);
            vault.deposit(1_000e18, alice);
            vm.stopPrank();
            vm.prank(address(vault));
            token.transfer(address(strat), 600e18);
            strat.setManaged(600e18);
            strat.setLimit(600e18);
        }

        // ── healthy baseline ──────────────────────────────────────────────────────
        function test_HealthyMaxViews() public view {
            // idle 400 + strategy limit 600 = 1000 liquid; alice owns all shares.
            assertEq(vault.availableImmediateLiquidity(), 1_000e18);
            assertGt(vault.maxWithdraw(alice), 0);
            assertGt(vault.maxRedeem(alice), 0);
        }

        // ── only the liquidity query fails → degrade to idle, do not revert ───────
        function test_LimitRevertDegradesToIdle() public {
            strat.setRevertLimit(true); // estimatedTotalAssets still works

            assertEq(vault.availableImmediateLiquidity(), 400e18, "degrades to idle only");
            // max* must not revert, and are capped by the idle liquidity.
            uint256 mw = vault.maxWithdraw(alice);
            uint256 mr = vault.maxRedeem(alice);
            assertEq(mw, 400e18, "maxWithdraw capped at idle");
            assertGt(mr, 0, "maxRedeem non-zero, capped by idle");
            // totalAssets still works here (views not down).
            assertEq(vault.totalAssets(), 1_000e18);
        }

        // ── full strategy outage: max* still must not revert; totalAssets may ─────
        function test_FullOutageMaxViewsDoNotRevert() public {
            strat.setRevertLimit(true);
            strat.setRevertViews(true);

            assertEq(vault.availableImmediateLiquidity(), 400e18, "idle only under full outage");
            // The ERC-4626 contract: max* MUST NOT revert. Under a full outage
            // owner-max is unpriceable (totalAssets reverts), so the only correct
            // non-reverting answer is 0 — not a fabricated idle value.
            assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw fails safe to 0, not revert");
            assertEq(vault.maxRedeem(alice), 0, "maxRedeem fails safe to 0, not revert");
            // totalAssets is deliberately allowed to revert (B3-T2).
            vm.expectRevert(bytes("views down"));
            vault.totalAssets();
        }

        // ── B9-T2: a strategy that returns type(uint256).max SUCCESSFULLY overflowed
        //          the maxDeposit/maxMint arithmetic (outside the try/catch). Both must
        //          now fail safe to 0, not revert. Needs a capped vault with idle
        //          balance so `balance + deployed` actually overflows. ───────────────
        function test_B9T2_MaxDepositMintDoNotOverflowOnHugeStrategyReturn() public {
            DeepYieldVaultB capped =
                new DeepYieldVaultB(IERC20(address(token)), "capped", "cap", admin, guardian, treasury, 10_000e18);
            FlakyStrategy s2 = new FlakyStrategy(IERC20(address(token)), address(capped));
            vm.prank(admin);
            capped.setStrategy(address(s2));

            // Put a non-zero idle balance in the capped vault (strategy healthy here).
            token.mint(alice, 100e18);
            vm.startPrank(alice);
            token.approve(address(capped), 100e18);
            capped.deposit(100e18, alice);
            vm.stopPrank();

            // Strategy now reports an absurd deployed total, SUCCESSFULLY.
            s2.setManaged(type(uint256).max);

            // balance(100) + max overflows the managed computation; the wrapper catches
            // it. Both views return 0 instead of reverting.
            assertEq(capped.maxDeposit(alice), 0, "maxDeposit fails safe to 0, not overflow-revert");
            assertEq(capped.maxMint(alice), 0, "maxMint inherits the safety via maxDeposit==0");
        }
    }
