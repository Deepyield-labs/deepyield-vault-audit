// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {IDedicatedVenue, IDedicatedVenueV2} from "../src/interfaces/IDedicatedVenue.sol";
import {
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "../src/interfaces/IVaultBExecutionV2.sol";

contract MockMainV2Token is ERC20 {
    constructor() ERC20("Mock MainV2 Token", "MV2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMainV2PriceGuard is IVaultBPriceGuard, IVaultBRewardPriceGuard {
    uint16 public normalLossBps = 100;
    uint16 public emergencyLossBps = 1_000;
    bool public fail;
    bool public emergencyActive = true;

    function setFail(bool value) external {
        fail = value;
    }

    function setEmergencyActive(bool value) external {
        emergencyActive = value;
    }

    function minimumOut(address, address, uint256 amountIn, bool emergency) external view returns (uint256) {
        require(!fail, "guard unavailable");
        require(!emergency || emergencyActive, "emergency inactive");
        uint256 loss = emergency ? emergencyLossBps : normalLossBps;
        return amountIn * (10_000 - loss) / 10_000;
    }

    function fairValue(address, address, uint256 amountIn) external view returns (uint256) {
        require(!fail, "guard unavailable");
        return amountIn;
    }

    function minimumOut(uint256 amountIn, bool emergency) external view returns (uint256) {
        require(!fail, "guard unavailable");
        require(!emergency || emergencyActive, "emergency inactive");
        uint256 loss = emergency ? emergencyLossBps : normalLossBps;
        return amountIn * (10_000 - loss) / 10_000;
    }

    function fairValue(uint256 amountIn) external view returns (uint256) {
        require(!fail, "guard unavailable");
        return amountIn;
    }

    function twapSqrtPriceX96() external view returns (uint160) {
        require(!fail, "guard unavailable");
        return uint160(1 << 96);
    }
}

contract MockMainV2RewardAdapter is IVaultBRewardExecutionAdapterV2 {
    using SafeERC20 for IERC20;

    address public constant override rewardToken = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant override asset = 0x55d398326f99059fF775485246999027B3197955;

    address public binder;
    address public override main;
    IVaultBRewardPriceGuard public guard;
    uint256 public lastEffectiveMinOut;
    bool public lastEmergency;

    constructor(address binder_, IVaultBRewardPriceGuard guard_) {
        binder = binder_;
        guard = guard_;
    }

    function bindMain(address main_) external {
        require(msg.sender == binder && main == address(0), "bind");
        main = main_;
    }

    function priceGuard() external view returns (IVaultBRewardPriceGuard) {
        return guard;
    }

    function swapRewardToAsset(uint256 amountIn, uint256 keeperMinOut, uint256, bool emergency)
        external
        returns (uint256 amountOut)
    {
        require(msg.sender == main, "main");
        uint256 guardMin = guard.minimumOut(amountIn, emergency);
        lastEffectiveMinOut = keeperMinOut > guardMin ? keeperMinOut : guardMin;
        lastEmergency = emergency;
        IERC20(rewardToken).safeTransferFrom(main, address(this), amountIn);
        amountOut = amountIn;
        require(amountOut >= lastEffectiveMinOut, "slippage");
        IERC20(asset).safeTransfer(main, amountOut);
    }
}

    contract MockMainV2ExecutionAdapter is IVaultBExecutionAdapterV2 {
        using SafeERC20 for IERC20;

        address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
        address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

        address public binder;
        address public main;
        IVaultBPriceGuard public guard;
        uint256 public lastEffectiveMinOut;
        bool public lastEmergency;

        constructor(address binder_, IVaultBPriceGuard guard_) {
            binder = binder_;
            guard = guard_;
        }

        function bindMain(address main_) external {
            require(msg.sender == binder && main == address(0), "bind");
            main = main_;
        }

        function priceGuard() external view returns (IVaultBPriceGuard) {
            return guard;
        }

        function swapAssetToPaired(uint256 amountIn, uint256 keeperMinOut, uint256, bool emergency)
            external
            returns (uint256 amountOut)
        {
            return _swap(USDT, WBNB, amountIn, keeperMinOut, emergency);
        }

        function swapPairedToAsset(uint256 amountIn, uint256 keeperMinOut, uint256, bool emergency)
            external
            returns (uint256 amountOut)
        {
            return _swap(WBNB, USDT, amountIn, keeperMinOut, emergency);
        }

        function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 keeperMinOut, bool emergency)
            internal
            returns (uint256 amountOut)
        {
            require(msg.sender == main, "main");
            uint256 guardMin = guard.minimumOut(tokenIn, tokenOut, amountIn, emergency);
            lastEffectiveMinOut = keeperMinOut > guardMin ? keeperMinOut : guardMin;
            lastEmergency = emergency;
            IERC20(tokenIn).safeTransferFrom(main, address(this), amountIn);
            amountOut = amountIn;
            require(amountOut >= lastEffectiveMinOut, "slippage");
            IERC20(tokenOut).safeTransfer(main, amountOut);
        }
    }

    contract MockMainV2Venue is IDedicatedVenueV2 {
        using SafeERC20 for IERC20;

        address public controller;
        IERC20 public immutable asset;
        IERC20 public immutable paired;
        uint24 public constant fee = 100;
        uint256 public activeId;
        uint256 public nextId = 1;

        uint256 public lastAssetIn;
        uint256 public lastPairedIn;
        uint256 public lastAmount0Min;
        uint256 public lastAmount1Min;
        uint256 public spotAssetExpected;
        uint256 public spotPairedExpected;
        uint256 public twapAssetExpected;
        uint256 public twapPairedExpected;
        uint256 public closeAssetOut;
        uint256 public closePairedOut;
        uint256 public positionValue;
        bool public forceUnstaked;
        address public closeCallback;
        bytes public closeCallbackData;
        bool public closeCallbackSucceeded;

        constructor(IERC20 asset_, IERC20 paired_) {
            asset = asset_;
            paired = paired_;
        }

        function bindController(address controller_) external {
            require(controller == address(0), "bound");
            controller = controller_;
        }

        function poolAddress() external pure returns (address) {
            return 0x172fcD41E0913e95784454622d1c3724f546f849;
        }

        function forceUnstakeSkipHarvest(uint256 positionId) external {
            require(msg.sender == controller && positionId == activeId, "position");
            forceUnstaked = true;
        }

        function configureClose(
            uint256 spotAsset,
            uint256 spotPaired,
            uint256 twapAsset,
            uint256 twapPaired,
            uint256 actualAsset,
            uint256 actualPaired
        ) external {
            spotAssetExpected = spotAsset;
            spotPairedExpected = spotPaired;
            twapAssetExpected = twapAsset;
            twapPairedExpected = twapPaired;
            closeAssetOut = actualAsset;
            closePairedOut = actualPaired;
        }

        function configureCloseCallback(address target, bytes calldata data) external {
            closeCallback = target;
            closeCallbackData = data;
            closeCallbackSucceeded = false;
        }

        function open(OpenArgs calldata a) external returns (uint256 positionId) {
            require(msg.sender == controller, "controller");
            asset.safeTransferFrom(msg.sender, address(this), a.assetAmount);
            paired.safeTransferFrom(msg.sender, address(this), a.pairedAmount);
            require(a.amount0Min <= a.assetAmount && a.amount1Min <= a.pairedAmount, "mint min");
            lastAssetIn = a.assetAmount;
            lastPairedIn = a.pairedAmount;
            positionId = nextId++;
            activeId = positionId;
            positionValue = a.assetAmount + a.pairedAmount;
        }

        function previewOpenAmounts(uint256 assetDesired, uint256 pairedDesired, int24, int24)
            external
            pure
            returns (uint256, uint256)
        {
            return (assetDesired, pairedDesired);
        }

        function close(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256) external {
            require(msg.sender == controller && positionId == activeId, "position");
            require(closeAssetOut >= amount0Min && closePairedOut >= amount1Min, "close min");
            address callback = closeCallback;
            if (callback != address(0)) {
                (closeCallbackSucceeded,) = callback.call(closeCallbackData);
                closeCallback = address(0);
                delete closeCallbackData;
            }
            lastAmount0Min = amount0Min;
            lastAmount1Min = amount1Min;
            activeId = 0;
            positionValue = 0;
            if (closeAssetOut != 0) asset.safeTransfer(msg.sender, closeAssetOut);
            if (closePairedOut != 0) paired.safeTransfer(msg.sender, closePairedOut);
        }

        function harvest(uint256) external pure returns (uint256) {
            return 0;
        }

        function positionValueAsset(uint256 positionId) external view returns (uint256) {
            return positionId == activeId ? positionValue : 0;
        }

        function previewCloseAmounts(uint256 positionId) external view returns (uint256, uint256) {
            require(positionId == activeId, "position");
            return (spotAssetExpected, spotPairedExpected);
        }

        function previewCloseAmountsAtSqrtPrice(uint256 positionId, uint160) external view returns (uint256, uint256) {
            require(positionId == activeId, "position");
            return (twapAssetExpected, twapPairedExpected);
        }
    }

    contract VaultBMainV2Test is Test {
        address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
        address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

        address internal admin = makeAddr("admin");
        address internal keeper = makeAddr("keeper");
        address internal guardian = makeAddr("guardian");
        address internal outsider = makeAddr("outsider");

        MockMainV2Token internal usdt;
        MockMainV2Token internal wbnb;
        MockMainV2Token internal cake;
        MockMainV2PriceGuard internal guard;
        MockMainV2PriceGuard internal rewardGuard;
        MockMainV2ExecutionAdapter internal executor;
        MockMainV2RewardAdapter internal rewardExecutor;
        MockMainV2Venue internal venue;
        DedicatedVaultMainV2 internal main;

        function setUp() public {
            vm.chainId(56);
            vm.warp(10 days);
            _etchToken(USDT);
            _etchToken(WBNB);
            _etchToken(CAKE);
            usdt = MockMainV2Token(USDT);
            wbnb = MockMainV2Token(WBNB);
            cake = MockMainV2Token(CAKE);

            guard = new MockMainV2PriceGuard();
            rewardGuard = new MockMainV2PriceGuard();
            executor = new MockMainV2ExecutionAdapter(address(this), guard);
            rewardExecutor = new MockMainV2RewardAdapter(address(this), rewardGuard);
            venue = new MockMainV2Venue(IERC20(USDT), IERC20(WBNB));
            main = new DedicatedVaultMainV2({
                vault_: address(this),
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
            executor.bindMain(address(main));
            rewardExecutor.bindMain(address(main));
            venue.bindController(address(main));

            usdt.mint(address(this), 100_000e18);
            usdt.mint(address(executor), 100_000e18);
            usdt.mint(address(rewardExecutor), 100_000e18);
            wbnb.mint(address(executor), 100_000e18);
            IERC20(USDT).approve(address(main), type(uint256).max);

            vm.prank(admin);
            main.enableOperations();
        }

        function _etchToken(address target) internal {
            MockMainV2Token template = new MockMainV2Token();
            vm.etch(target, address(template).code);
        }

        function _fund(uint256 amount) internal {
            main.fundFromVault(amount);
        }

        function _open(bytes32 jobId) internal returns (uint256) {
            vm.prank(keeper);
            return main.openPosition(
                DedicatedVaultMainV2.OpenParams({
                    jobId: jobId,
                    tickLower: -100,
                    tickUpper: 100,
                    assetBudget: 1_000e18,
                    swapAssetIn: 500e18,
                    keeperPairedMinOut: 1,
                    deadline: block.timestamp + 60
                })
            );
        }

        function _mintCloseInventory(uint256 assetAmount, uint256 pairedAmount) internal {
            if (assetAmount != 0) usdt.mint(address(venue), assetAmount);
            if (pairedAmount != 0) wbnb.mint(address(venue), pairedAmount);
        }

        function testStartsHaltedAndRequiresExplicitEnable() public {
            DedicatedVaultMainV2 fresh = new DedicatedVaultMainV2(
                address(this),
                venue,
                executor,
                guard,
                rewardExecutor,
                rewardGuard,
                IERC20(CAKE),
                100,
                100,
                1_000,
                50_000e18,
                50_000e18,
                100_000e18,
                1_000e18,
                1_000e18,
                2_000e18,
                admin,
                keeper,
                guardian
            );
            assertEq(uint256(fresh.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED));
        }

        function testEnableFailsClosedOnWrongVenueIdentity() public {
            vm.mockCall(
                address(venue),
                abi.encodeWithSelector(IDedicatedVenueV2.poolAddress.selector),
                abi.encode(makeAddr("wrong-pool"))
            );
            vm.prank(admin);
            vm.expectRevert(DedicatedVaultMainV2.InvalidVenueIdentity.selector);
            main.enableOperations();
        }

        function testEnableFailsClosedOnMismatchedAdapterPriceGuard() public {
            vm.mockCall(
                address(executor),
                abi.encodeWithSelector(IVaultBExecutionAdapterV2.priceGuard.selector),
                abi.encode(makeAddr("wrong-guard"))
            );
            vm.prank(admin);
            vm.expectRevert(DedicatedVaultMainV2.InvalidExecutionAdapter.selector);
            main.enableOperations();
        }

        function testEnableFailsClosedOnMismatchedRewardAdapterPriceGuard() public {
            vm.mockCall(
                address(rewardExecutor),
                abi.encodeWithSelector(IVaultBRewardExecutionAdapterV2.priceGuard.selector),
                abi.encode(makeAddr("wrong-reward-guard"))
            );
            vm.prank(admin);
            vm.expectRevert(DedicatedVaultMainV2.InvalidExecutionAdapter.selector);
            main.enableOperations();
        }

        function testEnableFailsClosedOnWrongRewardAdapterTokenIdentity() public {
            vm.mockCall(
                address(rewardExecutor),
                abi.encodeWithSelector(IVaultBRewardExecutionAdapterV2.rewardToken.selector),
                abi.encode(makeAddr("wrong-reward-token"))
            );
            vm.prank(admin);
            vm.expectRevert(DedicatedVaultMainV2.InvalidExecutionAdapter.selector);
            main.enableOperations();
        }

        function testOpenUsesExplicitBudgetAndDoesNotDeployAllIdle() public {
            _fund(5_000e18);
            uint256 id = _open(keccak256("open-1"));
            assertEq(id, 1);
            assertEq(venue.lastAssetIn(), 500e18);
            assertEq(venue.lastPairedIn(), 500e18);
            assertEq(usdt.balanceOf(address(main)), 4_000e18, "four fifths remains idle");
            assertEq(executor.lastEffectiveMinOut(), 495e18, "keeper min=1 was raised on chain");

            (, DedicatedVaultMainV2.JobStatus status,,,,,,) = main.jobs(keccak256("open-1"));
            assertEq(uint256(status), uint256(DedicatedVaultMainV2.JobStatus.COMPLETED));
        }

        function testOpenCanaryCapRejectsAllInBudget() public {
            _fund(5_000e18);
            vm.prank(keeper);
            vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
            main.openPosition(
                DedicatedVaultMainV2.OpenParams({
                    jobId: keccak256("too-large"),
                    tickLower: -100,
                    tickUpper: 100,
                    assetBudget: 1_001e18,
                    swapAssetIn: 500e18,
                    keeperPairedMinOut: 1,
                    deadline: block.timestamp + 60
                })
            );
        }

        function testDuplicateOpenJobRejectedOnChain() public {
            _fund(2_000e18);
            bytes32 jobId = keccak256("open-dedupe");
            _open(jobId);
            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.JobAlreadyCompleted.selector);
            main.openPosition(
                DedicatedVaultMainV2.OpenParams({
                    jobId: jobId,
                    tickLower: -100,
                    tickUpper: 100,
                    assetBudget: 1_000e18,
                    swapAssetIn: 500e18,
                    keeperPairedMinOut: 1,
                    deadline: block.timestamp + 60
                })
            );
        }

        function testAssetOnlyCloseAllowsOnlyProvenEmptyPairedLeg() public {
            _fund(2_000e18);
            _open(keccak256("open-asset-only"));
            venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
            _mintCloseInventory(1_000e18, 0);

            vm.prank(keeper);
            main.closeToInventory(keccak256("close-asset-only"), block.timestamp + 60, false);
            assertEq(venue.lastAmount0Min(), 990e18);
            assertEq(venue.lastAmount1Min(), 0, "only on-chain empty leg may use zero");
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY));
        }

        function testAssetOnlyCloseStillRequiresHealthyOraclePair() public {
            _fund(2_000e18);
            uint256 id = _open(keccak256("open-asset-only-oracle"));
            venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
            _mintCloseInventory(1_000e18, 0);
            guard.setFail(true);

            vm.prank(keeper);
            vm.expectRevert(bytes("guard unavailable"));
            main.closeToInventory(keccak256("close-asset-only-oracle"), block.timestamp + 60, false);
            assertEq(main.activePositionId(), id);
        }

        function testPairedOnlyCloseAllowsOnlyProvenEmptyAssetLegThenLiquidates() public {
            _fund(2_000e18);
            _open(keccak256("open-paired-only"));
            venue.configureClose(0, 1_000e18, 0, 1_000e18, 0, 1_000e18);
            _mintCloseInventory(0, 1_000e18);

            vm.prank(keeper);
            main.closeToInventory(keccak256("close-paired-only"), block.timestamp + 60, false);
            assertEq(venue.lastAmount0Min(), 0);
            assertEq(venue.lastAmount1Min(), 990e18);

            uint256 before = usdt.balanceOf(address(main));
            vm.prank(keeper);
            uint256 out = main.liquidateAllWbnb(keccak256("sell-wbnb"), 0, 1, block.timestamp + 60, true, false);
            assertEq(out, 1_000e18);
            assertEq(usdt.balanceOf(address(main)) - before, 1_000e18);
            assertEq(wbnb.balanceOf(address(main)), 0);
            assertEq(executor.lastEffectiveMinOut(), 990e18);
        }

        function testCloseRejectsAggregateValueLossAndRestoresPosition() public {
            _fund(2_000e18);
            uint256 id = _open(keccak256("open-loss"));
            // A manipulated spot preview would accept 900 (min 891), while the
            // independently TWAP-valued geometry still says the LP is worth 1000.
            venue.configureClose(900e18, 0, 1_000e18, 0, 900e18, 0);
            _mintCloseInventory(900e18, 0);

            vm.prank(keeper);
            vm.expectPartialRevert(DedicatedVaultMainV2.CloseValueBelowFloor.selector);
            main.closeToInventory(keccak256("close-loss"), block.timestamp + 60, false);
            assertEq(main.activePositionId(), id, "revert restores Main state");
            assertEq(venue.activeId(), id, "revert restores venue state");
        }

        function testDuplicateCloseAndLiquidationJobsRejected() public {
            _fund(2_000e18);
            _open(keccak256("open-dupe-close"));
            venue.configureClose(0, 100e18, 0, 100e18, 0, 100e18);
            _mintCloseInventory(0, 100e18);
            bytes32 closeJob = keccak256("close-dupe");
            vm.prank(keeper);
            main.closeToInventory(closeJob, block.timestamp + 60, false);

            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.JobAlreadyCompleted.selector);
            main.closeToInventory(closeJob, block.timestamp + 60, false);

            bytes32 sellJob = keccak256("sell-dupe");
            vm.prank(keeper);
            main.liquidateAllWbnb(sellJob, 0, 1, block.timestamp + 60, true, false);
            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.JobAlreadyCompleted.selector);
            main.liquidateAllWbnb(sellJob, 0, 1, block.timestamp + 60, true, false);
        }

        function testTemporalSlicingIsExplicitlyDisabled() public {
            wbnb.mint(address(main), 10e18);
            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.SlicingDisabled.selector);
            main.liquidateAllWbnb(keccak256("slice"), 1, 1, block.timestamp + 60, false, false);
        }

        function testNormalSwapCapsDoNotBlockBoundedGuardianExit() public {
            wbnb.mint(address(main), 1_500e18);
            vm.prank(keeper);
            vm.expectPartialRevert(DedicatedVaultMainV2.SwapCapExceeded.selector);
            main.liquidateAllWbnb(keccak256("normal-over-cap"), 0, 1, block.timestamp + 60, true, false);

            vm.prank(guardian);
            main.liquidateAllWbnb(keccak256("guardian-exit"), 0, 1, block.timestamp + 60, true, true);
            assertTrue(executor.lastEmergency());
            assertEq(wbnb.balanceOf(address(main)), 0);
        }

        function testEmergencyAssetOnlyCloseStillRequiresActiveEmergencyBudget() public {
            _fund(2_000e18);
            _open(keccak256("open-emergency-budget"));
            venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
            _mintCloseInventory(1_000e18, 0);
            guard.setEmergencyActive(false);

            vm.prank(guardian);
            vm.expectRevert(bytes("emergency inactive"));
            main.closeToInventory(keccak256("close-no-budget"), block.timestamp + 60, true);
            assertEq(main.activePositionId(), 1, "failed emergency check preserves position");
        }

        function testGuardianCanForceUnstakeWithoutClosingOrChangingPositionId() public {
            _fund(2_000e18);
            uint256 id = _open(keccak256("open-force-unstake"));

            vm.prank(guardian);
            main.forceUnstakeSkipHarvest();

            assertTrue(venue.forceUnstaked());
            assertEq(main.activePositionId(), id);
            assertEq(venue.activeId(), id);
        }

        function testWithdrawalBlocksNewCapitalOnlyAfterBatchCommit() public {
            _fund(1_000e18);
            bytes32 requestId = keccak256("withdraw-1");
            main.requestWithdrawal(requestId, 600e18);
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));

            main.commitWithdrawalCycle();
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY));

            vm.expectPartialRevert(DedicatedVaultMainV2.OpensDisabled.selector);
            main.fundFromVault(1e18);

            uint256 before = usdt.balanceOf(address(this));
            assertEq(main.claimWithdrawal(requestId, 600e18), 600e18);
            assertEq(usdt.balanceOf(address(this)) - before, 600e18);
            assertEq(main.queuedWithdrawalAssets(), 0);
            assertEq(main.queuedWithdrawalCount(), 0);
        }

        function testWithdrawalRequestIsNavIndependentAndClaimUsesActualAmount() public {
            _fund(1_000e18);
            guard.setFail(true);
            rewardGuard.setFail(true);
            bytes32 requestId = keccak256("withdraw-nav-independent");

            main.requestWithdrawal(requestId, 0);
            assertEq(main.queuedWithdrawalAssets(), 0, "zero hint is valid");
            assertEq(main.queuedWithdrawalCount(), 1);
            assertTrue(main.isWithdrawalReady(), "USDT-only inventory needs no oracle");

            uint256 before = usdt.balanceOf(address(this));
            assertEq(main.claimWithdrawal(requestId, 700e18), 700e18);
            assertEq(usdt.balanceOf(address(this)) - before, 700e18);
            assertEq(main.queuedWithdrawalCount(), 0);
        }

        function testClaimTimeAmountMayDifferFromRequestHintButCannotExceedIdle() public {
            _fund(1_000e18);
            bytes32 requestId = keccak256("withdraw-claim-time-nav");
            main.requestWithdrawal(requestId, 600e18);

            assertEq(main.claimWithdrawal(requestId, 500e18), 500e18);
            assertEq(main.queuedWithdrawalAssets(), 0, "hint clears, not claim amount");
            assertEq(main.queuedWithdrawalCount(), 0);

            bytes32 tooLarge = keccak256("withdraw-too-large");
            main.requestWithdrawal(tooLarge, 1);
            vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
            main.claimWithdrawal(tooLarge, 501e18);
            assertEq(main.queuedWithdrawalCount(), 1, "failed claim preserves request");
        }

        function testSynchronousIdleWithdrawCannotBypassQueueOrActiveInventory() public {
            _fund(1_000e18);
            bytes32 requestId = keccak256("withdraw-priority");
            main.requestWithdrawal(requestId, 0);
            vm.expectPartialRevert(DedicatedVaultMainV2.OutstandingWithdrawals.selector);
            main.withdrawIdleToVault(1e18);

            main.claimWithdrawal(requestId, 0);
            uint256 before = usdt.balanceOf(address(this));
            assertEq(main.withdrawIdleToVault(100e18), 100e18);
            assertEq(usdt.balanceOf(address(this)) - before, 100e18);

            vm.prank(admin);
            main.enableOperations();
            _fund(100e18);
            _open(keccak256("open-sync-withdraw-block"));
            vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
            main.withdrawIdleToVault(1e18);
        }

        function testZeroHintRequestStillBlocksEnableAndDuplicateClaim() public {
            _fund(1_000e18);
            bytes32 requestId = keccak256("withdraw-zero-hint-block");
            main.requestWithdrawal(requestId, 0);

            vm.prank(admin);
            vm.expectPartialRevert(DedicatedVaultMainV2.OutstandingWithdrawals.selector);
            main.enableOperations();

            main.claimWithdrawal(requestId, 0);
            vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
            main.claimWithdrawal(requestId, 0);
        }

        function testCanceledUncommittedRequestClearsCountsWithoutChangingMode() public {
            _fund(1_000e18);
            bytes32 requestId = keccak256("withdraw-cancel");
            main.requestWithdrawal(requestId, 600e18);
            main.cancelWithdrawal(requestId);

            assertEq(main.queuedWithdrawalAssets(), 0);
            assertEq(main.queuedWithdrawalCount(), 0);
            (, DedicatedVaultMainV2.WithdrawalStatus status) = main.withdrawals(requestId);
            assertEq(uint256(status), uint256(DedicatedVaultMainV2.WithdrawalStatus.CANCELED));
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));

            vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
            main.cancelWithdrawal(requestId);
        }

        function testRewardInventoryDoesNotBlockCloseButBlocksWithdrawalClaim() public {
            _fund(2_000e18);
            _open(keccak256("open-with-reward"));
            venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
            _mintCloseInventory(1_000e18, 0);
            bytes32 requestId = keccak256("withdraw-with-reward");
            main.requestWithdrawal(requestId, 600e18);
            cake.mint(address(main), 1e18);

            vm.prank(keeper);
            main.closeToInventory(keccak256("close-with-reward"), block.timestamp + 60, false);
            assertEq(main.activePositionId(), 0, "CAKE must not block LP close");

            vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
            main.claimWithdrawal(requestId, 600e18);
            assertEq(main.rewardInventory(), 1e18);
            assertEq(main.queuedWithdrawalAssets(), 600e18);
        }

        function testRewardInventoryBlocksNewOperatingCycle() public {
            vm.prank(guardian);
            main.halt();
            cake.mint(address(main), 1e18);

            vm.prank(admin);
            vm.expectPartialRevert(DedicatedVaultMainV2.RewardInventoryPresent.selector);
            main.enableOperations();
            assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED));
        }

        function testRewardInventoryBlocksOpenEvenIfDonatedAfterEnable() public {
            _fund(2_000e18);
            cake.mint(address(main), 1e18);

            vm.expectPartialRevert(DedicatedVaultMainV2.RewardInventoryPresent.selector);
            _open(keccak256("open-with-donated-reward"));
            assertEq(main.activePositionId(), 0);
        }

        function testRewardInventoryHasExecutableNavAndLiquidatesThroughDurableJob() public {
            _fund(1_000e18);
            cake.mint(address(main), 100e18);
            assertEq(main.totalAssetsUsdt(), 1_099e18, "CAKE uses executable 99% floor");

            uint256 before = usdt.balanceOf(address(main));
            bytes32 jobId = keccak256("sell-cake");
            vm.prank(keeper);
            uint256 out = main.liquidateAllReward(jobId, 0, 1, block.timestamp + 60, true, false);

            assertEq(out, 100e18);
            assertEq(usdt.balanceOf(address(main)) - before, 100e18);
            assertEq(cake.balanceOf(address(main)), 0);
            assertEq(cake.allowance(address(main), address(rewardExecutor)), 0);
            assertEq(rewardExecutor.lastEffectiveMinOut(), 99e18, "keeper min=1 cannot weaken reward guard");

            (DedicatedVaultMainV2.JobKind kind, DedicatedVaultMainV2.JobStatus status,,,,,,) = main.jobs(jobId);
            assertEq(uint256(kind), uint256(DedicatedVaultMainV2.JobKind.LIQUIDATE_REWARD));
            assertEq(uint256(status), uint256(DedicatedVaultMainV2.JobStatus.COMPLETED));
        }

        function testDuplicateRewardJobAndTemporalSlicingAreRejected() public {
            cake.mint(address(main), 100e18);
            bytes32 jobId = keccak256("sell-cake-dupe");
            vm.prank(keeper);
            main.liquidateAllReward(jobId, 0, 1, block.timestamp + 60, true, false);

            cake.mint(address(main), 100e18);
            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.JobAlreadyCompleted.selector);
            main.liquidateAllReward(jobId, 0, 1, block.timestamp + 60, true, false);

            vm.prank(keeper);
            vm.expectRevert(DedicatedVaultMainV2.SlicingDisabled.selector);
            main.liquidateAllReward(keccak256("sell-cake-slice"), 1, 1, block.timestamp + 60, false, false);
        }

        function testNormalRewardCapCannotBlockBoundedGuardianLiquidation() public {
            cake.mint(address(main), 1_500e18);
            vm.prank(keeper);
            vm.expectPartialRevert(DedicatedVaultMainV2.SwapCapExceeded.selector);
            main.liquidateAllReward(keccak256("normal-cake-over-cap"), 0, 1, block.timestamp + 60, true, false);

            vm.prank(guardian);
            main.liquidateAllReward(keccak256("guardian-cake-exit"), 0, 1, block.timestamp + 60, true, true);
            assertTrue(rewardExecutor.lastEmergency());
            assertEq(cake.balanceOf(address(main)), 0);
        }

        function testRewardOracleFailureBlocksRewardNavAndSellButNotLpClose() public {
            _fund(2_000e18);
            _open(keccak256("open-before-reward-oracle-failure"));
            venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
            _mintCloseInventory(1_000e18, 0);
            cake.mint(address(main), 100e18);
            rewardGuard.setFail(true);

            vm.expectRevert(bytes("guard unavailable"));
            main.totalAssetsUsdt();

            vm.prank(keeper);
            vm.expectRevert(bytes("guard unavailable"));
            main.liquidateAllReward(keccak256("cake-guard-down"), 0, 1, block.timestamp + 60, true, false);

            vm.prank(keeper);
            main.closeToInventory(keccak256("lp-close-with-cake-guard-down"), block.timestamp + 60, false);
            assertEq(main.activePositionId(), 0, "reward oracle must not block LP close");
            assertEq(cake.balanceOf(address(main)), 100e18, "failed reward job preserves inventory");
        }

        function testIdleWbnbHasConservativeExecutableNavInsteadOfZero() public {
            _fund(1_000e18);
            wbnb.mint(address(main), 10e18);
            assertEq(main.totalAssetsUsdt(), 1_009.9e18);
        }

        function testActiveLpNavUsesTwapGeometryAndExecutableWbnbFloor() public {
            _fund(2_000e18);
            _open(keccak256("open-nav"));
            venue.configureClose(0, 0, 600e18, 400e18, 0, 0);

            // 1,000 idle + 600 USDT leg + 400 WBNB valued at the normal
            // executable 99% floor. Uncollected fees are deliberately excluded.
            assertEq(main.totalAssetsUsdt(), 1_996e18);
        }

        function testUnavailableInventoryOracleFailsClosedInsteadOfPricingWbnbAtZero() public {
            _fund(1_000e18);
            wbnb.mint(address(main), 10e18);
            guard.setFail(true);
            vm.expectRevert(bytes("guard unavailable"));
            main.totalAssetsUsdt();
        }

        function testHardActiveAssetCapIsOnChain() public {
            vm.expectPartialRevert(DedicatedVaultMainV2.CapitalCapExceeded.selector);
            _fund(50_001e18);
        }

        function testOnlyAdminCanRaiseCapsAndNeverAboveHardCaps() public {
            vm.prank(outsider);
            vm.expectRevert();
            main.setOperationalCaps(2_000e18, 2_000e18, 3_000e18);

            vm.prank(admin);
            main.setOperationalCaps(2_000e18, 2_000e18, 3_000e18);
            assertEq(main.canaryOpenCap(), 2_000e18);

            vm.prank(admin);
            vm.expectRevert(DedicatedVaultMainV2.InvalidConfiguration.selector);
            main.setOperationalCaps(50_001e18, 2_000e18, 3_000e18);
        }
    }
