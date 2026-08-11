// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {DedicatedVaultStrategyAdapterV2} from "../src/DedicatedVaultStrategyAdapterV2.sol";
import {IFeeSink} from "../src/interfaces/IFeeSink.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {PartnerRegistry} from "../src/partners/PartnerRegistry.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";
import {IPartnerWrapper} from "../src/interfaces/IPartnerWrapper.sol";
import {
    MockMainV2Token,
    MockMainV2PriceGuard,
    MockMainV2ExecutionAdapter,
    MockMainV2RewardAdapter,
    MockMainV2Venue
} from "./VaultBMainV2.t.sol";

/// @notice A fee sink that can be toggled to revert, modelling a paused /
/// blacklisted / buggy recipient. When healthy it pulls the fee like the real
/// sink; when reverting it fails inside recordFee.
contract RevertingFeeSink is IFeeSink {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    bool public reverting;
    uint256 public cumulativeReceived;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function recordFee(uint256 amount) external {
        require(!reverting, "sink down");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        cumulativeReceived += amount;
    }
}

/// @notice B2-T1 (decoupled fee remittance) + B2-T2 (loss-path basis resync),
/// tested together on one branch as the two overlap in the adapter's fee/basis
/// accounting. Minimal harness: this test contract itself plays the ERC-4626
/// vault for the adapter (implements totalAssets(), holds USDT, approves the
/// adapter), so it can drive deploy / withdraw / harvest directly.
contract VaultBStrategyAdapterFeeBasisTest is Test {
    using SafeERC20 for IERC20;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal dead = makeAddr("dead");

    MockMainV2Token internal usdt;
    MockMainV2Token internal wbnb;
    MockMainV2Token internal cake;
    MockMainV2PriceGuard internal guard;
    MockMainV2PriceGuard internal rewardGuard;
    MockMainV2ExecutionAdapter internal executor;
    MockMainV2RewardAdapter internal rewardExecutor;
    MockMainV2Venue internal venue;
    RevertingFeeSink internal sink;
    DedicatedVaultMainV2 internal main;
    DedicatedVaultStrategyAdapterV2 internal adapter;

    uint16 internal constant PERF_FEE_BPS = 2_000; // 20%

    // --- this contract is the adapter's ERC-4626 vault ---
    function totalAssets() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    function _etch(address t) internal {
        MockMainV2Token tmpl = new MockMainV2Token();
        vm.etch(t, address(tmpl).code);
    }

    function setUp() public {
        vm.chainId(56);
        vm.warp(10 days);
        _etch(USDT);
        _etch(WBNB);
        _etch(CAKE);
        usdt = MockMainV2Token(USDT);
        wbnb = MockMainV2Token(WBNB);
        cake = MockMainV2Token(CAKE);

        guard = new MockMainV2PriceGuard();
        rewardGuard = new MockMainV2PriceGuard();
        executor = new MockMainV2ExecutionAdapter(address(this), guard);
        rewardExecutor = new MockMainV2RewardAdapter(address(this), rewardGuard);
        venue = new MockMainV2Venue(IERC20(USDT), IERC20(WBNB));
        sink = new RevertingFeeSink(IERC20(USDT));

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
        require(address(main) == predictedMain, "main addr");
        adapter = new DedicatedVaultStrategyAdapterV2(
            IERC20(USDT), address(this), main, admin, manager, guardian, address(sink), PERF_FEE_BPS
        );
        require(address(adapter) == predictedAdapter, "adapter addr");

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
        main.enableOperations();

        usdt.mint(address(this), 1_000_000e18);
        usdt.approve(address(adapter), type(uint256).max);
    }

    // --- helpers ---
    function _deploy(uint256 amount) internal {
        vm.prank(manager);
        adapter.deploy(amount);
    }

    function _profit(uint256 gain) internal {
        usdt.mint(address(main), gain); // realized gain shows up as extra idle USDT in Main
    }

    function _loss(uint256 amount) internal {
        vm.prank(address(main));
        usdt.transfer(dead, amount); // Main ends a close below its basis
    }

    function _claim(bytes32 id, uint256 hint, uint256 assetsNeeded) internal returns (uint256) {
        adapter.requestWithdrawal(id, hint); // this == vault
        return adapter.claimWithdrawal(id, assetsNeeded);
    }

    // ============================ B2-T2 ============================

    // Loss withdrawal must resync basis to Main's real remaining (0 on a full
    // drain). Pre-fix flat _reduceBasis leaves accountedAssets = 2_000e18.
    function testLossWithdrawalResyncsBasisToZero() public {
        _deploy(40_000e18);
        assertEq(adapter.accountedAssets(), 40_000e18);
        _loss(2_000e18); // Main 40_000 -> 38_000
        _claim(keccak256("loss"), 38_000e18, 38_000e18);
        assertEq(usdt.balanceOf(address(main)), 0);
        assertEq(adapter.accountedAssets(), 0, "basis must equal Main remaining, not a stale value");
    }

    // After a loss-and-withdraw the ratchet must be closed: fresh capital plus a
    // gain is charged fee from the real basis, not a phantom one.
    function testDeployAfterLossChargesFeeFromCorrectBasis() public {
        _deploy(40_000e18);
        _loss(2_000e18);
        _claim(keccak256("loss"), 38_000e18, 38_000e18); // basis now 0, Main 0
        _deploy(10_000e18); // basis 10_000
        _profit(2_000e18); // gain 2_000 on the fresh capital
        (uint256 profit, uint256 feeAssets) = adapter.pendingPerformanceFee();
        assertEq(profit, 2_000e18);
        assertEq(feeAssets, 400e18, "fee is 20% of the true 2_000 gain, not inflated by a phantom basis");
    }

    // ============================ B2-T1 ============================

    // A reverting sink must NOT freeze a claim: principal reaches the vault and
    // the fee is recorded as an obligation. Pre-fix _payFee reverts the whole tx.
    function testSinkFailureDoesNotFreezeClaimAndAccruesUnremitted() public {
        _deploy(40_000e18);
        _profit(10_000e18); // Main 50_000, basis 40_000 -> fee 2_000
        sink.setReverting(true);

        uint256 vaultBefore = usdt.balanceOf(address(this));
        _claim(keccak256("claim-sink-down"), 20_000e18, 20_000e18);

        assertEq(usdt.balanceOf(address(this)) - vaultBefore, 20_000e18, "principal still reaches the vault");
        assertEq(adapter.unremittedFee(), 2_000e18, "fee held as obligation");
        assertEq(usdt.balanceOf(address(adapter)), 2_000e18, "fee assets stay in the adapter");
        assertEq(sink.cumulativeReceived(), 0);
    }

    // The other three fee sites tolerate a failing sink the same way.
    function testSinkFailureDoesNotFreezeWithdrawToVault() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        sink.setReverting(true);
        adapter.withdrawToVault(5_000e18); // this == vault
        assertEq(adapter.unremittedFee(), 2_000e18);
    }

    function testSinkFailureDoesNotFreezeHarvest() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        sink.setReverting(true);
        vm.prank(manager);
        adapter.harvest();
        assertEq(adapter.unremittedFee(), 2_000e18);
    }

    function testSinkFailureDoesNotFreezeManagerWithdrawAll() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        sink.setReverting(true);
        vm.prank(manager);
        adapter.managerWithdrawAll();
        assertEq(adapter.unremittedFee(), 2_000e18);
    }

    // remitFee sends exactly the accrued amount to the fee recipient, is a no-op
    // at zero, and restores the obligation (paid exactly once) if the sink still
    // fails.
    function testRemitFeeExactAmountToRecipientOnlyAndExactlyOnce() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        sink.setReverting(true);
        _claim(keccak256("defer"), 20_000e18, 20_000e18);
        assertEq(adapter.unremittedFee(), 2_000e18);

        // sink still down -> remitFee reverts and restores the obligation
        vm.expectRevert(bytes("sink down"));
        adapter.remitFee();
        assertEq(adapter.unremittedFee(), 2_000e18, "obligation intact after a failed remit");

        // sink recovers -> exactly the accrued amount reaches the recipient
        sink.setReverting(false);
        uint256 remitted = adapter.remitFee();
        assertEq(remitted, 2_000e18);
        assertEq(sink.cumulativeReceived(), 2_000e18, "recipient got exactly the obligation");
        assertEq(adapter.unremittedFee(), 0);

        // second call is a no-op, no double pay
        uint256 again = adapter.remitFee();
        assertEq(again, 0);
        assertEq(sink.cumulativeReceived(), 2_000e18, "no second payment");
    }

    // The deferred obligation must not inflate vault NAV.
    function testUnremittedFeeNotCountedInEstimatedTotalAssets() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        sink.setReverting(true);
        _claim(keccak256("defer-nav"), 20_000e18, 20_000e18);

        assertEq(adapter.unremittedFee(), 2_000e18);
        assertEq(usdt.balanceOf(address(adapter)), 2_000e18);
        // Main holds 50_000 - (20_000 + 2_000) = 28_000, basis resynced to 28_000
        assertEq(usdt.balanceOf(address(main)), 28_000e18);
        assertEq(
            adapter.estimatedTotalAssets(),
            28_000e18,
            "NAV = Main assets only; the 2_000 obligation in the adapter is excluded"
        );
    }

    // Exactly-once across two profit->withdraw cycles with a healthy sink: total
    // fee equals 20% of total realized profit, no double charge.
    function testExactlyOnceAcrossProfitWithdrawCycles() public {
        _deploy(30_000e18);
        _profit(5_000e18); // gain 5_000 -> fee 1_000
        _claim(keccak256("c1"), 10_000e18, 10_000e18);
        _profit(4_000e18); // fresh gain 4_000 -> fee 800
        _claim(keccak256("c2"), 5_000e18, 5_000e18);
        assertEq(sink.cumulativeReceived(), 1_800e18, "fee == 20% of (5_000 + 4_000), charged once each");
    }

    // Regression: the profit path with a healthy sink is unchanged — fee reaches
    // the recipient and no obligation is left behind.
    function testProfitPathFeeUnchangedWithHealthySink() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        _claim(keccak256("healthy"), 20_000e18, 20_000e18);
        assertEq(sink.cumulativeReceived(), 2_000e18);
        assertEq(adapter.unremittedFee(), 0);
    }
}

/// @notice Minimal IPartnerWrapper stand-in. `reverting` mirrors a wrapper
/// whose `totalReceipts()` view fails (e.g. corrupted storage / bad upgrade),
/// which is what actually reverts the splitter's `recordFee` loop in
/// production — not the sink contract itself misbehaving.
contract MockPartnerWrapper is IPartnerWrapper {
    bool public reverting;

    constructor(bool reverting_) {
        reverting = reverting_;
    }

    function totalReceipts() external view returns (uint256) {
        require(!reverting, "wrapper down");
        return 0;
    }

    function partnerId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function vault() external pure returns (address) {
        return address(0);
    }

    function asset() external pure returns (address) {
        return address(0);
    }

    function registry() external pure returns (address) {
        return address(0);
    }

    function receiptBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function donatedExcess() external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function recoverDonatedShares(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice B2-T3: the B2-T1 decoupled-fee-remittance fix exercised against the
/// REAL PartnerAttributedSplitter + PartnerRegistry (instead of the
/// RevertingFeeSink mock above), so the "sink can revert" scenario is proven
/// against the actual production fee-recipient graph: a broken wrapper inside
/// the splitter's `activeWrapperList()` loop, not a hand-rolled toggle.
contract VaultBStrategyAdapterRealSplitterTest is Test {
    using SafeERC20 for IERC20;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal projectTreasury = makeAddr("projectTreasury");

    MockMainV2Token internal usdt;
    MockMainV2Token internal wbnb;
    MockMainV2Token internal cake;
    MockMainV2PriceGuard internal guard;
    MockMainV2PriceGuard internal rewardGuard;
    MockMainV2ExecutionAdapter internal executor;
    MockMainV2RewardAdapter internal rewardExecutor;
    MockMainV2Venue internal venue;

    DeepYieldVaultB internal vaultB;
    PartnerRegistry internal reg;
    PartnerAttributedSplitter internal splitter;
    DedicatedVaultMainV2 internal main;
    DedicatedVaultStrategyAdapterV2 internal adapter;

    MockPartnerWrapper internal wrapperA; // reverting
    MockPartnerWrapper internal wrapperB; // healthy

    bytes32 internal constant PARTNER_ID = keccak256("P");
    uint16 internal constant PERF_FEE_BPS = 2_000; // 20%

    // --- this contract also plays PartnerRegistry's one-shot wrapper factory ---
    function registry() external view returns (address) {
        return address(reg);
    }

    function vault() external view returns (address) {
        return address(vaultB);
    }

    function _etch(address t) internal {
        MockMainV2Token tmpl = new MockMainV2Token();
        vm.etch(t, address(tmpl).code);
    }

    function setUp() public {
        vm.chainId(56);
        vm.warp(10 days);
        _etch(USDT);
        _etch(WBNB);
        _etch(CAKE);
        usdt = MockMainV2Token(USDT);
        wbnb = MockMainV2Token(WBNB);
        cake = MockMainV2Token(CAKE);

        vaultB = new DeepYieldVaultB(
            IERC20(USDT), "DeepYield Vault B V2", "dyBV2", admin, guardian, projectTreasury, 0
        );
        reg = new PartnerRegistry(address(vaultB), admin);
        splitter = new PartnerAttributedSplitter(address(reg), projectTreasury, 1_000, admin);

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
        require(address(main) == predictedMain, "main addr");
        adapter = new DedicatedVaultStrategyAdapterV2(
            IERC20(USDT), address(vaultB), main, admin, manager, guardian, address(splitter), PERF_FEE_BPS
        );
        require(address(adapter) == predictedAdapter, "adapter addr");

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
        vaultB.setStrategy(address(adapter));
        vm.prank(admin);
        main.enableOperations();

        vm.prank(admin);
        reg.setFactory(address(this));
        wrapperA = new MockPartnerWrapper(true);
        wrapperB = new MockPartnerWrapper(false);
        reg.registerPartner(PARTNER_ID, address(wrapperA), projectTreasury);

        usdt.mint(address(this), 100_000e18);
        usdt.approve(address(vaultB), 100_000e18);
        vaultB.deposit(100_000e18, address(this));
    }

    // --- helpers ---
    function _deploy(uint256 amount) internal {
        vm.prank(manager);
        adapter.deploy(amount);
    }

    function _profit(uint256 gain) internal {
        usdt.mint(address(main), gain); // realized gain shows up as extra idle USDT in Main
    }

    function _requestAndClaim(bytes32 id, uint256 hint, uint256 assetsNeeded) internal returns (uint256) {
        vm.prank(address(vaultB));
        adapter.requestWithdrawal(id, hint);
        vm.prank(address(vaultB));
        return adapter.claimWithdrawal(id, assetsNeeded);
    }

    // (a) A reverting wrapper inside the splitter's activeWrapperList must not
    // freeze a claim: recordFee's loop hits wrapperA.totalReceipts() and
    // reverts, the adapter's try/catch around _payFee catches the whole
    // external call, principal still reaches the vault, and the fee becomes
    // an unremitted obligation instead of being lost or blocking the exit.
    function testRealSplitterFailureDefersFeeAndSettlesWithdrawal() public {
        _deploy(40_000e18);
        _profit(10_000e18); // Main 50_000, basis 40_000 -> fee 2_000

        uint256 vaultBefore = usdt.balanceOf(address(vaultB));
        _requestAndClaim(keccak256("claim-splitter-down"), 20_000e18, 20_000e18);

        assertEq(usdt.balanceOf(address(vaultB)) - vaultBefore, 20_000e18, "principal still reaches the vault");
        assertEq(adapter.unremittedFee(), 2_000e18, "fee held as obligation");
        assertEq(splitter.cumulativeReceived(), 0, "splitter never pulled the fee");
    }

    // (b) Once the broken wrapper is retired (replaced by a healthy one),
    // activeWrapperList no longer reverts, so remitFee's recordFee call
    // succeeds and the deferred obligation reaches the real splitter.
    function testRemitAfterRetiringBrokenWrapper() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        _requestAndClaim(keccak256("claim-splitter-down"), 20_000e18, 20_000e18);
        assertEq(adapter.unremittedFee(), 2_000e18);

        reg.addReplacementWrapper(PARTNER_ID, address(wrapperB));
        vm.prank(admin);
        reg.retireWrapper(address(wrapperA));

        adapter.remitFee();

        assertEq(adapter.unremittedFee(), 0);
        assertEq(splitter.cumulativeReceived(), 2_000e18, "obligation reached the real splitter exactly once");
    }

    // (c) The deferred obligation sits as an idle balance on the adapter, not
    // inside Main, so it must not inflate vault-visible NAV.
    function testUnremittedNotInNav() public {
        _deploy(40_000e18);
        _profit(10_000e18);
        _requestAndClaim(keccak256("claim-splitter-down"), 20_000e18, 20_000e18);
        assertEq(adapter.unremittedFee(), 2_000e18);

        assertEq(
            adapter.estimatedTotalAssets(),
            usdt.balanceOf(address(main)),
            "NAV = Main assets only; the unremitted fee obligation in the adapter is excluded"
        );
    }
}
