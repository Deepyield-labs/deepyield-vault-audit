// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

contract B10T2Token is ERC20 {
    constructor() ERC20("USD Test", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Strategy whose lower (min-geometry) and upper (max-geometry) NAV are set
/// independently, modelling exactly what a spot manipulation does to MainV2's
/// min/max valuation: a downward spot push drops `lower` below the fair `upper`.
/// Holds the deployed capital so claims settle from it.
contract B10T2Strategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    uint256 public lowerNav; // estimatedTotalAssets  (redemption-conservative, min)
    uint256 public upperNav; // estimatedTotalAssetsUpper (deposit-conservative, max)
    bool public override withdrawalCycleCommitted;
    bool public viewsRevert;
    address public depositSource;

    constructor(IERC20 asset_, address vault_) {
        asset = asset_;
        vault = vault_;
        depositSource = address(this);
    }

    function setNav(uint256 lower_, uint256 upper_) external {
        lowerNav = lower_;
        upperNav = upper_;
    }

    function setViewsRevert(bool v) external {
        viewsRevert = v;
    }

    function setDepositAssetSource(address source) external {
        depositSource = source;
    }

    function depositAssetSource() external view returns (address) {
        return depositSource;
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
        return lowerNav;
    }

    function estimatedTotalAssetsUpper() external view returns (uint256) {
        require(!viewsRevert, "views down");
        return upperNav;
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

    function withdrawalCycleExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function withdrawalCycleChargeableExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function availableWithdrawLimit() external view returns (uint256) {
        return viewsRevert ? 0 : lowerNav;
    }

    function depositsAllowed() external view returns (bool) {
        require(!viewsRevert, "views down");
        return true;
    }
}

    contract VaultBB10T2NavDirectionalTest is Test {
        B10T2Token internal token;
        DeepYieldVaultB internal vault;
        B10T2Strategy internal strat;

        address internal admin = makeAddr("admin");
        address internal guardian = makeAddr("guardian");
        address internal treasury = makeAddr("treasury");
        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");

        uint256 internal minDeposit;

        function setUp() public {
            token = new B10T2Token();
            vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
            strat = new B10T2Strategy(IERC20(address(token)), address(vault));
            vm.prank(admin);
            vault.setStrategy(address(strat));
            minDeposit = vault.MIN_DEPOSIT();
        }

        function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
            token.mint(who, assets);
            vm.startPrank(who);
            token.approve(address(vault), assets);
            shares = vault.deposit(assets, who);
            vm.stopPrank();
        }

        /// Move idle out of the vault into the strategy so the modelled `lower`/`upper`
        /// position values are not double-counted with idle.
        function _simulateDeploy(uint256 amount) internal {
            vm.prank(address(vault));
            token.transfer(address(strat), amount);
        }

        // ── Test 1: deposit prices on UPPER; a spot-down NAV understatement no longer
        //           lets a depositor capture cheap shares (dilution before/after). ──────
        function test_DepositPricesOnUpper_NotLower() public {
            uint256 fair = 1_000 * minDeposit;
            uint256 aliceShares = _deposit(alice, fair); // alice = the existing holder
            _simulateDeploy(fair);
            // Fair, unmanipulated: lower == upper == fair.
            strat.setNav(fair, fair);
            assertEq(vault.totalAssets(), fair, "lower NAV fair");
            assertEq(vault.totalAssetsUpper(), fair, "upper NAV fair");

            // Spot pushed DOWN: min-geometry (lower) understates; max-geometry (upper) fair.
            strat.setNav((fair * 80) / 100, fair); // lower = 80% of fair

            // previewDeposit prices on UPPER (the fix); convertToShares still reads the
            // lower NAV — i.e. exactly what the OLD deposit path minted. So the two are
            // the after/before numbers in one shot.
            uint256 sharesFix = vault.previewDeposit(fair); // upper -> fair shares
            uint256 sharesOld = vault.convertToShares(fair); // lower -> inflated shares
            assertLt(sharesFix, sharesOld, "upper pricing mints fewer shares than the understated lower");

            // Dilution to alice = drop in her fair-valued redeemable claim after bob's deposit.
            uint256 fairTotalAfter = fair + fair; // alice position (fair) + bob's 1000 idle
            // Under the FIX bob deposits and gets sharesFix:
            uint256 bobShares = _deposit(bob, fair);
            assertEq(bobShares, sharesFix, "bob minted at the upper (fair) price");
            uint256 aliceFairValueFix = Math.mulDiv(fairTotalAfter, aliceShares, vault.totalSupply());
            uint256 aliceDilutionFix = fair > aliceFairValueFix ? fair - aliceFairValueFix : 0;

            // Under the OLD path bob would have minted sharesOld:
            uint256 supplyOld = aliceShares + sharesOld;
            uint256 aliceFairValueOld = Math.mulDiv(fairTotalAfter, aliceShares, supplyOld);
            uint256 aliceDilutionOld = fair - aliceFairValueOld;

            emit log_named_uint("alice dilution OLD (lower-priced deposit)", aliceDilutionOld);
            emit log_named_uint("alice dilution FIX (upper-priced deposit)", aliceDilutionFix);
            assertGt(aliceDilutionOld, aliceDilutionFix * 1000, "old path dilutes; fix is dust by comparison");
            assertLe(aliceDilutionFix, fair / 1e6, "fix dilution is within rounding dust");
        }

        // ── Test 2: spot pushed UP (upper inflated) -> depositor gets NO MORE than fair
        //           (the griefer side-effect: fewer, never more). ──────────────────────
        function test_InflatedSpot_DepositGetsNoMoreThanFair() public {
            uint256 fair = 1_000 * minDeposit;
            _deposit(alice, fair);
            _simulateDeploy(fair);
            strat.setNav(fair, fair);
            uint256 sharesAtFair = vault.previewDeposit(fair);

            // Spot pushed UP: upper (max) inflated above fair.
            strat.setNav(fair, (fair * 120) / 100);
            uint256 sharesAtInflated = vault.previewDeposit(fair);
            assertLt(
                sharesAtInflated,
                sharesAtFair,
                "inflated upper mints FEWER shares (grief costs the depositor, never dilutes holders)"
            );
        }

        // ── Test 3: preview == execution on BOTH branches (no preview/execution split). ─
        function test_PreviewEqualsExecution_BothBranches() public {
            uint256 fair = 1_000 * minDeposit;
            _deposit(alice, fair);
            _simulateDeploy(fair);
            strat.setNav((fair * 80) / 100, fair); // lower != upper so the branch matters

            uint256 dep = 250 * minDeposit;
            uint256 predictedShares = vault.previewDeposit(dep);
            uint256 actualShares = _deposit(bob, dep);
            assertEq(actualShares, predictedShares, "deposit() mints exactly previewDeposit()");

            uint256 mintShares = 100 * minDeposit * 1e6;
            uint256 predictedAssets = vault.previewMint(mintShares);
            token.mint(bob, predictedAssets);
            vm.startPrank(bob);
            token.approve(address(vault), predictedAssets);
            uint256 actualAssets = vault.mint(mintShares, bob);
            vm.stopPrank();
            assertEq(actualAssets, predictedAssets, "mint() pulls exactly previewMint()");
        }

        // ── Test 4: redemption + convert* stay on the LOWER NAV even when upper differs. ─
        function test_RedeemAndConvertStayOnLower() public {
            uint256 fair = 1_000 * minDeposit;
            uint256 aliceShares = _deposit(alice, fair);
            _simulateDeploy(fair);
            strat.setNav((fair * 80) / 100, fair); // lower 80%, upper fair

            // previewRedeem / convertToAssets / maxWithdraw price on the LOWER NAV.
            uint256 lowerNav = vault.totalAssets();
            assertEq(lowerNav, (fair * 80) / 100, "totalAssets is the lower NAV");
            uint256 previewAssets = vault.previewRedeem(aliceShares);
            uint256 convertAssets = vault.convertToAssets(aliceShares);
            assertEq(previewAssets, convertAssets, "redeem preview == convertToAssets (both lower)");
            // Independent recompute on the lower NAV, to the wei.
            uint256 expected = Math.mulDiv(aliceShares, lowerNav + 1, vault.totalSupply() + 1e6, Math.Rounding.Floor);
            assertEq(previewAssets, expected, "redeem values on lower NAV exactly");

            // Raising ONLY the upper NAV must not move any redemption number.
            strat.setNav((fair * 80) / 100, fair * 2);
            assertEq(vault.previewRedeem(aliceShares), previewAssets, "upper change does not leak into redeem");
            assertEq(vault.convertToAssets(aliceShares), convertAssets, "upper change does not leak into convert");
        }

        // ── Test 5: convertToShares diverges from previewDeposit by design. ─────────────
        function test_ConvertDivergesFromPreview_ByDesign() public {
            uint256 fair = 1_000 * minDeposit;
            _deposit(alice, fair);
            _simulateDeploy(fair);
            strat.setNav((fair * 80) / 100, fair);

            uint256 dep = 500 * minDeposit;
            assertLt(
                vault.previewDeposit(dep),
                vault.convertToShares(dep),
                "previewDeposit (upper) < convertToShares (lower): documented, allowed divergence"
            );
        }

        // ── Test 6: strategy outage — totalAssets/totalAssetsUpper revert, max* fail to 0,
        //           the B10-T1 insolvency guard still holds. ───────────────────────────
        function test_Outage_MaxZero_And_GuardHolds() public {
            _deposit(alice, 1_000 * minDeposit);
            strat.setViewsRevert(true);
            // Both NAV views revert (outage), so max* must fail safe to 0 (P1-T1/B9-T2).
            assertEq(vault.maxDeposit(bob), 0, "outage -> maxDeposit 0");
            assertEq(vault.maxMint(bob), 0, "outage -> maxMint 0");

            // Insolvency (B10-T1 finding 7) is distinct: strategy healthy but NAV 0.
            strat.setViewsRevert(false);
            strat.setNav(0, 0);
            // drain idle to zero so lower NAV == 0 with supply > 0
            uint256 idle = token.balanceOf(address(vault));
            vm.prank(address(vault));
            token.transfer(address(0xdead), idle);
            assertEq(vault.totalAssets(), 0, "insolvent: lower NAV 0");
            assertGt(vault.totalSupply(), 0, "supply remains");
            assertEq(vault.maxDeposit(bob), 0, "insolvency guard blocks deposit");
        }

        // ── Test 7: maxDeposit/maxMint measured on the UPPER estimate. ──────────────────
        function test_MaxViewsOnUpper() public {
            // cap the vault so maxDeposit is finite and reflects the NAV estimate.
            vm.prank(admin);
            vault.setDepositCap(10_000 * minDeposit);
            uint256 fair = 1_000 * minDeposit;
            _deposit(alice, fair);
            _simulateDeploy(fair);

            // upper > lower: the cap headroom is measured against the (larger) upper managed.
            strat.setNav(fair, fair * 2);
            uint256 managedUpper = token.balanceOf(address(vault)) + strat.estimatedTotalAssetsUpper();
            uint256 expectedHeadroom = 10_000 * minDeposit - managedUpper;
            assertEq(vault.maxDeposit(bob), expectedHeadroom, "cap headroom uses the upper managed estimate");
            // maxMint converts that headroom at the upper (previewDeposit) rate.
            assertEq(vault.maxMint(bob), vault.previewDeposit(expectedHeadroom), "maxMint uses the upper conversion");
        }

        function test_DepositNavUsesPinnedDirectBalanceFloor() public {
            uint256 fair = 1_000 * minDeposit;
            uint256 aliceShares = _deposit(alice, fair);
            _simulateDeploy(fair);

            assertEq(vault.strategyAssetSource(), address(strat), "source pinned at activation");
            strat.setNav(fair / 10, fair / 10);
            assertEq(vault.totalAssetsUpper(), fair, "direct token balance floors deposit NAV");
            assertApproxEqAbs(vault.previewDeposit(fair), aliceShares, 1, "under-report cannot inflate minted shares");

            B10T2Strategy replacementSource = new B10T2Strategy(IERC20(address(token)), address(vault));
            token.mint(address(replacementSource), 10 * fair);
            strat.setDepositAssetSource(address(replacementSource));

            assertEq(vault.strategyAssetSource(), address(strat), "runtime source change is ignored");
            assertEq(vault.totalAssetsUpper(), fair, "only the activation-time source is read");
        }

        // ── Test 8: the ASYNC redeem cycle + claim must NOT see the upper NAV (reviewer
        //           #5: FAIL if upper leaks into settlement/claim). ────────────────────
        function test_AsyncClaimStaysOnLower() public {
            uint256 dep = 1_000 * minDeposit;
            uint256 shares = _deposit(alice, dep); // 100% of supply; funds sit idle in the vault
            // NAV lower == idle (no deployed position); push the UPPER far above it.
            strat.setNav(0, 2 * dep);
            assertEq(vault.totalAssets(), dep, "lower NAV = idle");
            assertEq(vault.totalAssetsUpper(), 3 * dep, "upper NAV inflated");

            vm.prank(alice);
            uint256 reqId = vault.requestRedeem(shares, alice, alice);
            vault.commitRedeemCycle();

            uint256 previewClaim = vault.claimableRedeemRequest(reqId);
            vm.prank(alice);
            uint256 claimed = vault.claimRedeem(reqId);
            assertEq(claimed, previewClaim, "claim matches its preview");
            // Full-supply exit pays the lower NAV (idle), NOT the 3x upper.
            assertEq(claimed, dep, "async claim settles on the lower NAV; upper did not leak");
        }
    }
