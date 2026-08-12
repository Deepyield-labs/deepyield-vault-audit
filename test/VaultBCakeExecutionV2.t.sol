// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BoundedPancakeRewardAdapterV2} from "../src/BoundedPancakeRewardAdapterV2.sol";
import {VaultBCakePriceGuard} from "../src/VaultBCakePriceGuard.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeSwapV3.sol";
import {
    IChainlinkAggregatorV3,
    IPancakeV3SwapRouterWithDeadline,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "../src/interfaces/IVaultBExecutionV2.sol";
import {Job} from "../src/libraries/MainV2Jobs.sol";
import {LiqParams, MainV2Liquidation} from "../src/libraries/MainV2Liquidation.sol";

contract MockCakeCanonicalToken is ERC20 {
    constructor() ERC20("Mock Cake Execution Token", "MCET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCakeFeed is IChainlinkAggregatorV3 {
    uint8 public feedDecimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    function set(uint8 decimals_, uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        feedDecimals = decimals_;
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    int192 public boundMin = 1;
    int192 public boundMax = type(int192).max;

    function setBounds(int192 mn, int192 mx) external {
        boundMin = mn;
        boundMax = mx;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function minAnswer() external view returns (int192) {
        return boundMin;
    }

    function maxAnswer() external view returns (int192) {
        return boundMax;
    }
}

contract MockCakeOraclePool is IPancakeV3Pool {
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address public quoteToken;
    uint24 public poolFee;
    int24 public twapTick;
    bool public failObserve;

    function configure(address quoteToken_, uint24 fee_) external {
        quoteToken = quoteToken_;
        poolFee = fee_;
    }

    function setTwapTick(int24 tick_) external {
        twapTick = tick_;
    }

    function setFailObserve(bool value) external {
        failObserve = value;
    }

    function token0() external pure returns (address) {
        return CAKE;
    }

    function token1() external view returns (address) {
        return quoteToken;
    }

    function fee() external view returns (uint24) {
        return poolFee;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (uint160(1 << 96), twapTick, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        require(!failObserve, "observe unavailable");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidity = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            uint256 at = block.timestamp - secondsAgos[i];
            tickCumulatives[i] = int56(int256(at) * int256(twapTick));
        }
    }
}

contract MockCakePinnedRouter is IPancakeV3SwapRouterWithDeadline {
    using SafeERC20 for IERC20;

    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint256 public rateWad = 1e18;
    uint256 public returnBias;
    uint256 public lastMinOut;
    address public lastRecipient;
    uint256 public lastValue;

    error TooLittle(uint256 amountOut, uint256 minOut);

    function setRate(uint256 value) external {
        rateWad = value;
    }

    function setReturnBias(uint256 value) external {
        returnBias = value;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(p.tokenIn == CAKE && p.tokenOut == USDT, "tokens");
        require(p.fee == 2_500, "fee");
        require(p.recipient != address(0), "recipient");
        require(p.deadline >= block.timestamp, "deadline");
        lastMinOut = p.amountOutMinimum;
        lastRecipient = p.recipient;
        lastValue = msg.value;

        IERC20(CAKE).safeTransferFrom(msg.sender, address(this), p.amountIn);
        uint256 observedOut = p.amountIn * rateWad / 1e18;
        if (observedOut < p.amountOutMinimum) revert TooLittle(observedOut, p.amountOutMinimum);
        IERC20(USDT).safeTransfer(p.recipient, observedOut);
        return observedOut + returnBias;
    }
}

interface IRound8CakeDefaultAdminRules {
    function defaultAdminDelay() external view returns (uint48);
    function beginDefaultAdminTransfer(address newAdmin) external;
    function acceptDefaultAdminTransfer() external;
}

contract MockWrongFeeRewardGuard {
    function DIRECT_ORACLE_FEE() external pure returns (uint24) {
        return 500;
    }
}

contract Round8CakeLiquidationHarness {
    mapping(bytes32 => Job) internal jobs;
    mapping(bytes32 => mapping(uint32 => bool)) internal usedChunks;
    mapping(uint64 => uint256) internal dailySwapNotional;

    IERC20 internal immutable rewardToken;
    IVaultBRewardExecutionAdapterV2 internal immutable rewardExecutionAdapter;
    IVaultBRewardPriceGuard internal immutable rewardPriceGuard;

    constructor(
        IERC20 rewardToken_,
        IVaultBRewardExecutionAdapterV2 rewardExecutionAdapter_,
        IVaultBRewardPriceGuard rewardPriceGuard_
    ) {
        rewardToken = rewardToken_;
        rewardExecutionAdapter = rewardExecutionAdapter_;
        rewardPriceGuard = rewardPriceGuard_;
    }

    function liquidateEmergency(uint256 amount)
        external
        returns (uint256 amountOut, uint256 amountIn, uint256 notional)
    {
        return MainV2Liquidation.liquidateReward(
            jobs,
            usedChunks,
            dailySwapNotional,
            rewardToken,
            rewardExecutionAdapter,
            rewardPriceGuard,
            LiqParams({
                jobId: keccak256("round8-metered-cake"),
                chunkIndex: 0,
                keeperMinOut: 1,
                deadline: block.timestamp + 60,
                finalChunk: true,
                emergency: true,
                hardMaxActiveAssets: amount,
                swapPerJobCap: amount,
                dailySwapLimit: amount,
                dustTolerance: 0
            })
        );
    }
}

contract VaultBCakeExecutionV2Test is Test {
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant DIRECT_POOL = 0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1;
    address internal constant CROSS_POOL = 0xAfB2Da14056725E3BA3a30dD846B6BBbd7886c56;
    address internal constant BNB_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant USDT_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address internal constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");

    MockCakeCanonicalToken internal cake;
    MockCakeCanonicalToken internal usdt;
    MockCakeFeed internal bnbFeed;
    MockCakeFeed internal usdtFeed;
    MockCakeOraclePool internal directPool;
    MockCakeOraclePool internal crossPool;
    MockCakePinnedRouter internal router;
    VaultBCakePriceGuard internal guard;
    BoundedPancakeRewardAdapterV2 internal adapter;

    function setUp() public {
        vm.chainId(56);
        vm.warp(10_000);

        _etchToken(CAKE);
        _etchToken(USDT);
        cake = MockCakeCanonicalToken(CAKE);
        usdt = MockCakeCanonicalToken(USDT);

        MockCakeFeed feedTemplate = new MockCakeFeed();
        vm.etch(BNB_FEED, address(feedTemplate).code);
        vm.etch(USDT_FEED, address(feedTemplate).code);
        bnbFeed = MockCakeFeed(BNB_FEED);
        usdtFeed = MockCakeFeed(USDT_FEED);
        _setHealthyFeeds();

        MockCakeOraclePool poolTemplate = new MockCakeOraclePool();
        vm.etch(DIRECT_POOL, address(poolTemplate).code);
        vm.etch(CROSS_POOL, address(poolTemplate).code);
        directPool = MockCakeOraclePool(DIRECT_POOL);
        crossPool = MockCakeOraclePool(CROSS_POOL);
        directPool.configure(USDT, 2_500);
        crossPool.configure(WBNB, 500);

        MockCakePinnedRouter routerTemplate = new MockCakePinnedRouter();
        vm.etch(ROUTER, address(routerTemplate).code);
        router = MockCakePinnedRouter(ROUTER);
        router.setRate(1e18);

        guard = _deployGuard();
        adapter = new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(guard)), 120);
        adapter.bindMain(address(this));
        vm.prank(admin);
        guard.grantRole(keccak256("EMERGENCY_CONSUMER_ROLE"), address(adapter));

        cake.mint(address(this), 10_000e18);
        usdt.mint(ROUTER, 10_000e18);
        IERC20(CAKE).approve(address(adapter), type(uint256).max);
    }

    function _etchToken(address target) internal {
        MockCakeCanonicalToken template = new MockCakeCanonicalToken();
        vm.etch(target, address(template).code);
    }

    function _setHealthyFeeds() internal {
        bnbFeed.set(8, 7, 1e8, block.timestamp, 7);
        usdtFeed.set(8, 11, 1e8, block.timestamp, 11);
    }

    function _deployGuard() internal returns (VaultBCakePriceGuard) {
        return new VaultBCakePriceGuard(
            100, 1_000, 500, 1_000, 5_100e18, 50_000e18, 1_800, 3_600, 90_000, 600, admin, guardian
        );
    }

    function testQuoteUsesLowerIndependentSourceAndOnePercentFloor() public view {
        VaultBCakePriceGuard.Quote memory q = guard.quote(1_000e18, false);
        assertEq(q.directTwapOut, 1_000e18);
        assertEq(q.compositeTwapOut, 1_000e18);
        assertEq(q.fairOut, 1_000e18);
        assertEq(q.minOut, 990e18);
        assertEq(q.lossBps, 100);
    }

    function testRejectsCrossSourceDeviation() public {
        crossPool.setTwapTick(1_000);
        vm.expectPartialRevert(VaultBCakePriceGuard.OracleDeviation.selector);
        guard.minimumOut(1e18, false);
    }

    function testRejectsStaleChainlinkFeed() public {
        bnbFeed.set(8, 7, 1e8, block.timestamp - 3_601, 7);
        vm.expectPartialRevert(VaultBCakePriceGuard.StaleOracle.selector);
        guard.minimumOut(1e18, false);
    }

    function testRejectsFutureAndAcceptsFreshCrossPhaseRound() public {
        bnbFeed.set(8, 7, 1e8, block.timestamp + 1, 7);
        vm.expectPartialRevert(VaultBCakePriceGuard.FutureOracleTimestamp.selector);
        guard.minimumOut(1e18, false);

        bnbFeed.set(8, 7, 1e8, block.timestamp, 6);
        assertEq(guard.minimumOut(1e18, false), 0.99e18);
    }

    function testRejectsUnavailableDirectOrCrossTwap() public {
        directPool.setFailObserve(true);
        vm.expectPartialRevert(VaultBCakePriceGuard.TwapUnavailable.selector);
        guard.minimumOut(1e18, false);
        directPool.setFailObserve(false);

        crossPool.setFailObserve(true);
        vm.expectPartialRevert(VaultBCakePriceGuard.TwapUnavailable.selector);
        guard.minimumOut(1e18, false);
    }

    function testEmergencyBudgetIsBoundedAndExpires() public {
        vm.expectRevert(VaultBCakePriceGuard.EmergencyBudgetInactive.selector);
        guard.minimumOut(1e18, true);

        uint64 expiresAt = uint64(block.timestamp + 300);
        vm.prank(guardian);
        guard.activateEmergencyBudget(1_000, expiresAt, 50_000e18);
        assertEq(guard.minimumOut(1e18, true), 0.9e18);

        vm.warp(expiresAt);
        _setHealthyFeeds();
        vm.expectRevert(VaultBCakePriceGuard.EmergencyBudgetInactive.selector);
        guard.minimumOut(1e18, true);
    }

    // ── B5-T1 (CAKE mirror) ───────────────────────────────────────────────
    function test_EmergencyDeviationWiderThanNormalPasses() public {
        crossPool.setTwapTick(650); // ~670 bps: > normal 500, < emergency 1000
        vm.expectPartialRevert(VaultBCakePriceGuard.OracleDeviation.selector);
        guard.quote(1e18, false);

        vm.prank(guardian);
        guard.activateEmergencyBudget(1_000, uint64(block.timestamp + 300), 50_000e18);
        VaultBCakePriceGuard.Quote memory q = guard.quote(1e18, true);
        assertGt(q.minOut, 0, "CAKE emergency exit quotes through the wider band");
    }

    function test_DeviationAboveEmergencyCeilingStillReverts() public {
        crossPool.setTwapTick(1_200); // ~1270 bps > emergency 1000
        vm.prank(guardian);
        guard.activateEmergencyBudget(1_000, uint64(block.timestamp + 300), 50_000e18);
        vm.expectPartialRevert(VaultBCakePriceGuard.OracleDeviation.selector);
        guard.quote(1e18, true);
    }

    function test_FeedPinnedAtAggregatorBoundReverts() public {
        bnbFeed.setBounds(1e8, 1e12); // healthy answer sits on minAnswer
        vm.expectPartialRevert(VaultBCakePriceGuard.OracleAtBound.selector);
        guard.quote(1e18, false);
    }

    function test_ConfigRejectsAbsurdNormalLoss() public {
        vm.expectRevert(VaultBCakePriceGuard.InvalidConfiguration.selector);
        new VaultBCakePriceGuard(
            2_000, 2_000, 500, 1_000, 5_100e18, 50_000e18, 1_800, 3_600, 90_000, 600, admin, guardian
        );
    }

    function testEmergencyBudgetRejectsOutsiderAndOverCap() public {
        vm.prank(outsider);
        vm.expectRevert();
        guard.activateEmergencyBudget(500, uint64(block.timestamp + 100), 1e18);

        vm.prank(guardian);
        vm.expectRevert(VaultBCakePriceGuard.InvalidEmergencyBudget.selector);
        guard.activateEmergencyBudget(1_001, uint64(block.timestamp + 100), 1e18);

        vm.startPrank(guardian);
        vm.expectRevert(VaultBCakePriceGuard.InvalidEmergencyBudget.selector);
        guard.activateEmergencyBudget(500, uint64(block.timestamp + 100), 0);
        vm.expectRevert(VaultBCakePriceGuard.InvalidEmergencyBudget.selector);
        guard.activateEmergencyBudget(500, uint64(block.timestamp + 100), 50_000e18 + 1);
        vm.stopPrank();
    }

    function testZeroAmountIsRejectedByGuardAndAdapter() public {
        vm.expectRevert(VaultBCakePriceGuard.InvalidAmount.selector);
        guard.minimumOut(0, false);

        vm.expectRevert(BoundedPancakeRewardAdapterV2.InvalidAmount.selector);
        adapter.swapRewardToAsset(0, 1, block.timestamp + 60, false);
    }

    function testNormalAndEmergencyCapacityAreSeparateOnChain() public {
        vm.expectPartialRevert(VaultBCakePriceGuard.CapacityExceeded.selector);
        guard.minimumOut(5_101e18, false);
        assertEq(guard.fairValue(5_101e18), 5_101e18, "fair value remains available for capital accounting");

        vm.prank(guardian);
        guard.activateEmergencyBudget(300, uint64(block.timestamp + 300), 50_000e18);
        assertEq(guard.minimumOut(5_101e18, true), 4_947.97e18);

        vm.expectPartialRevert(VaultBCakePriceGuard.CapacityExceeded.selector);
        guard.minimumOut(50_001e18, true);
    }

    function testKeeperMinOutOneCannotDisableGuardFloor() public {
        uint256 out = adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, false);
        assertEq(out, 1_000e18);
        assertEq(router.lastMinOut(), 990e18);
        assertEq(router.lastRecipient(), address(this));
        assertEq(router.lastValue(), 0);
        assertEq(IERC20(CAKE).allowance(address(adapter), ROUTER), 0);
        assertEq(IERC20(CAKE).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDT).balanceOf(address(adapter)), 0);
    }

    function testKeeperCanOnlyMakeFloorStricter() public {
        adapter.swapRewardToAsset(1_000e18, 995e18, block.timestamp + 60, false);
        assertEq(router.lastMinOut(), 995e18);
    }

    function testRouterCannotExecuteBelowGuardFloor() public {
        router.setRate(0.98e18);
        vm.expectPartialRevert(MockCakePinnedRouter.TooLittle.selector);
        adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, false);
    }

    function testObservedBalanceDeltaMustMatchRouterReturn() public {
        router.setReturnBias(1);
        vm.expectPartialRevert(BoundedPancakeRewardAdapterV2.RouterOutputMismatch.selector);
        adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, false);
    }

    function testOnlyBoundMainCanExecuteAndDeadlineIsBounded() public {
        vm.prank(outsider);
        vm.expectRevert(BoundedPancakeRewardAdapterV2.NotMain.selector);
        adapter.swapRewardToAsset(1e18, 1, block.timestamp + 60, false);

        vm.expectRevert(BoundedPancakeRewardAdapterV2.InvalidDeadline.selector);
        adapter.swapRewardToAsset(1e18, 1, block.timestamp + 121, false);
    }

    function testMainBindingIsAuthorizedAndOneShot() public {
        BoundedPancakeRewardAdapterV2 fresh =
            new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(guard)), 120);

        vm.prank(outsider);
        vm.expectRevert(BoundedPancakeRewardAdapterV2.NotBinder.selector);
        fresh.bindMain(address(this));

        fresh.bindMain(address(this));
        vm.expectRevert(BoundedPancakeRewardAdapterV2.AlreadyBound.selector);
        fresh.bindMain(address(this));
    }

    function testAdapterRejectsNativeBnb() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(adapter).call{value: 1}(
            abi.encodeCall(adapter.swapRewardToAsset, (1e18, 1, block.timestamp + 60, false))
        );
        assertFalse(ok);
        assertEq(address(adapter).balance, 0);
    }

    function testWrongChainAndInvalidPoolCannotDeploy() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(VaultBCakePriceGuard.WrongChain.selector, 1));
        _deployGuard();
        vm.chainId(56);

        directPool.configure(WBNB, 2_500);
        vm.expectPartialRevert(VaultBCakePriceGuard.InvalidPool.selector);
        _deployGuard();
    }

    function testFuzzKeeperMinimumCannotLowerGuardFloor(uint128 keeperMin) public {
        uint256 bounded = bound(uint256(keeperMin), 0, 1_000e18);
        adapter.swapRewardToAsset(1_000e18, bounded, block.timestamp + 60, false);
        uint256 expected = bounded > 990e18 ? bounded : 990e18;
        assertEq(router.lastMinOut(), expected);
    }

    function testRound8EmergencyBudgetIsCumulativeAndDegradesToNormal() public {
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1_500e18);

        adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, true);
        assertEq(_emergencyConsumed(), 1_000e18);
        assertEq(router.lastMinOut(), 900e18);

        adapter.swapRewardToAsset(600e18, 1, block.timestamp + 60, true);
        assertEq(_emergencyConsumed(), 1_000e18);
        assertEq(router.lastMinOut(), 594e18);

        adapter.swapRewardToAsset(500e18, 1, block.timestamp + 60, true);
        assertEq(_emergencyConsumed(), 1_500e18);
        assertEq(guard.minimumOut(100e18, true), 99e18);
    }

    function testRound8FailedRewardSwapDoesNotConsumeEmergencyBudget() public {
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1_000e18);
        router.setRate(0.89e18);

        vm.expectPartialRevert(MockCakePinnedRouter.TooLittle.selector);
        adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, true);

        assertEq(_emergencyConsumed(), 0);
    }

    function testRound8PostSwapAccountingFailureDoesNotConsumeEmergencyBudget() public {
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1_000e18);
        router.setReturnBias(1);

        vm.expectPartialRevert(BoundedPancakeRewardAdapterV2.RouterOutputMismatch.selector);
        adapter.swapRewardToAsset(1_000e18, 1, block.timestamp + 60, true);

        assertEq(_emergencyConsumed(), 0);
    }

    function testRound8InsufficientBudgetRestoresNormalDeviationCeiling() public {
        crossPool.setTwapTick(650);
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1e18);

        vm.expectPartialRevert(VaultBCakePriceGuard.OracleDeviation.selector);
        guard.quote(2e18, true);
        assertEq(_emergencyConsumed(), 0);
    }

    function testRound8OnlyRewardAdapterCanConsumeEmergencyBudget() public {
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1e18);

        vm.prank(outsider);
        vm.expectRevert();
        guard.consumeEmergencyNotional(1);
        assertEq(_emergencyConsumed(), 0);
    }

    function testRound8RewardPostCheckUsesTheSamePreConsumptionEmergencyFloor() public {
        BoundedPancakeRewardAdapterV2 meteredAdapter =
            new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(guard)), 120);
        Round8CakeLiquidationHarness harness = new Round8CakeLiquidationHarness(
            IERC20(CAKE),
            IVaultBRewardExecutionAdapterV2(address(meteredAdapter)),
            IVaultBRewardPriceGuard(address(guard))
        );
        meteredAdapter.bindMain(address(harness));
        bytes32 consumerRole = guard.EMERGENCY_CONSUMER_ROLE();
        vm.prank(admin);
        guard.grantRole(consumerRole, address(meteredAdapter));

        cake.mint(address(harness), 1e18);
        router.setRate(0.95e18);
        _activateMeteredBudget(1_000, uint64(block.timestamp + 300), 1e18);

        (uint256 amountOut,,) = harness.liquidateEmergency(1e18);
        assertEq(amountOut, 0.95e18);
        assertEq(_emergencyConsumed(), 1e18);
    }

    function testRound8RewardFloorUsesStrongerIndependentSource() public view {
        // Filled by a dedicated source-weakening test after setup mutates crossPool.
        assertEq(guard.minimumOut(1_000e18, false), 990e18);
    }

    function testRound8RewardFloorDoesNotFollowWeakerCrossPool() public {
        crossPool.setTwapTick(-400);
        VaultBCakePriceGuard.Quote memory q = guard.quote(1_000e18, false);
        assertLt(q.fairOut, 1_000e18, "accounting value remains conservative");
        assertEq(q.minOut, 990e18, "execution floor must use the stronger source inside the deviation band");
    }

    function testRound8RewardMinOutRoundsAgainstCaller() public view {
        assertEq(guard.minimumOut(1, false), 1);
    }

    function testRound8RewardAdapterRejectsGuardWithDifferentPoolFee() public {
        MockWrongFeeRewardGuard wrong = new MockWrongFeeRewardGuard();
        vm.expectRevert();
        new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(wrong)), 120);
    }

    function testRound8CakeGuardDefaultAdminTransferIsDelayedAndTwoStep() public {
        IRound8CakeDefaultAdminRules rules = IRound8CakeDefaultAdminRules(address(guard));
        address nextAdmin = makeAddr("nextCakeAdmin");
        assertEq(rules.defaultAdminDelay(), 2 days);

        vm.prank(admin);
        rules.beginDefaultAdminTransfer(nextAdmin);
        assertTrue(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), nextAdmin));

        vm.warp(block.timestamp + 2 days);
        vm.prank(nextAdmin);
        vm.expectRevert();
        rules.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1);
        vm.prank(nextAdmin);
        rules.acceptDefaultAdminTransfer();
        assertFalse(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), nextAdmin));
    }

    function _activateMeteredBudget(uint16 lossBps, uint64 expiresAt, uint256 notionalLimit) internal {
        vm.prank(guardian);
        (bool ok,) = address(guard)
            .call(
                abi.encodeWithSignature(
                    "activateEmergencyBudget(uint16,uint64,uint256)", lossBps, expiresAt, notionalLimit
                )
            );
        assertTrue(ok, "metered emergency activation must succeed");
    }

    function _emergencyConsumed() internal view returns (uint256 value) {
        (bool ok, bytes memory data) = address(guard).staticcall(abi.encodeWithSignature("emergencyNotionalConsumed()"));
        assertTrue(ok, "metered emergency getter missing");
        value = abi.decode(data, (uint256));
    }
}
