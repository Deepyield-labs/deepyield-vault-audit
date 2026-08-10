// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BoundedPancakeExecutionAdapterV2} from "../src/BoundedPancakeExecutionAdapterV2.sol";
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeSwapV3.sol";
import {
    IChainlinkAggregatorV3,
    IPancakeV3SwapRouterWithDeadline,
    IVaultBPriceGuard
} from "../src/interfaces/IVaultBExecutionV2.sol";

contract MockCanonicalToken is ERC20 {
    constructor() ERC20("Mock Canonical", "MC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVaultBFeed is IChainlinkAggregatorV3 {
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
}

contract MockCanonicalVaultBPool is IPancakeV3Pool {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint24 internal constant POOL_FEE = 100;

    int24 public twapTick;
    bool public failObserve;
    bool public invalidToken0;

    function setTwapTick(int24 tick_) external {
        twapTick = tick_;
    }

    function setFailObserve(bool fail_) external {
        failObserve = fail_;
    }

    function setInvalidToken0(bool invalid_) external {
        invalidToken0 = invalid_;
    }

    function token0() external view returns (address) {
        return invalidToken0 ? address(0xdead) : USDT;
    }

    function token1() external pure returns (address) {
        return WBNB;
    }

    function fee() external pure returns (uint24) {
        return POOL_FEE;
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

contract MockPinnedPancakeRouter is IPancakeV3SwapRouterWithDeadline {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) public rateWad;
    uint256 public returnBias;
    address public lastRecipient;
    uint256 public lastMinOut;
    uint256 public lastValue;

    error TooLittle(uint256 amountOut, uint256 minOut);

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateWad[keccak256(abi.encode(tokenIn, tokenOut))] = rate;
    }

    function setReturnBias(uint256 bias) external {
        returnBias = bias;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(block.timestamp <= p.deadline, "deadline");
        require(p.fee == 100, "fee");
        lastRecipient = p.recipient;
        lastMinOut = p.amountOutMinimum;
        lastValue = msg.value;

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        uint256 observedOut = p.amountIn * rateWad[keccak256(abi.encode(p.tokenIn, p.tokenOut))] / 1e18;
        if (observedOut < p.amountOutMinimum) revert TooLittle(observedOut, p.amountOutMinimum);
        IERC20(p.tokenOut).safeTransfer(p.recipient, observedOut);
        return observedOut + returnBias;
    }
}

contract VaultBExecutionV2Test is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant BNB_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant USDT_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address internal constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");

    VaultBPriceGuard internal guard;
    BoundedPancakeExecutionAdapterV2 internal adapter;

    MockCanonicalToken internal usdt;
    MockCanonicalToken internal wbnb;
    MockVaultBFeed internal bnbFeed;
    MockVaultBFeed internal usdtFeed;
    MockCanonicalVaultBPool internal pool;
    MockPinnedPancakeRouter internal router;

    function setUp() public {
        vm.chainId(56);
        vm.warp(10_000);

        _etchToken(USDT);
        _etchToken(WBNB);
        usdt = MockCanonicalToken(USDT);
        wbnb = MockCanonicalToken(WBNB);

        MockVaultBFeed feedTemplate = new MockVaultBFeed();
        vm.etch(BNB_FEED, address(feedTemplate).code);
        vm.etch(USDT_FEED, address(feedTemplate).code);
        bnbFeed = MockVaultBFeed(BNB_FEED);
        usdtFeed = MockVaultBFeed(USDT_FEED);
        _setHealthyFeeds(1e8, 1e8);

        MockCanonicalVaultBPool poolTemplate = new MockCanonicalVaultBPool();
        vm.etch(POOL, address(poolTemplate).code);
        pool = MockCanonicalVaultBPool(POOL);
        pool.setTwapTick(0);

        MockPinnedPancakeRouter routerTemplate = new MockPinnedPancakeRouter();
        vm.etch(ROUTER, address(routerTemplate).code);
        router = MockPinnedPancakeRouter(ROUTER);
        router.setRate(USDT, WBNB, 1e18);
        router.setRate(WBNB, USDT, 1e18);

        guard = _deployGuard();
        adapter = new BoundedPancakeExecutionAdapterV2(address(this), IVaultBPriceGuard(address(guard)), 120);
        adapter.bindMain(address(this));

        usdt.mint(ROUTER, 1_000_000e18);
        wbnb.mint(ROUTER, 1_000_000e18);
        usdt.mint(address(this), 10_000e18);
        wbnb.mint(address(this), 10_000e18);
        IERC20(USDT).approve(address(adapter), type(uint256).max);
        IERC20(WBNB).approve(address(adapter), type(uint256).max);
    }

    function _etchToken(address target) internal {
        MockCanonicalToken template = new MockCanonicalToken();
        vm.etch(target, address(template).code);
    }

    function _setHealthyFeeds(int256 bnbAnswer, int256 usdtAnswer) internal {
        bnbFeed.set(8, 7, bnbAnswer, block.timestamp, 7);
        usdtFeed.set(8, 11, usdtAnswer, block.timestamp, 11);
    }

    function _deployGuard() internal returns (VaultBPriceGuard) {
        return new VaultBPriceGuard({
            normalLossBps_: 100,
            maxEmergencyLossBps_: 1_000,
            maxOracleDeviationBps_: 500,
            twapWindow_: 1_800,
            maxBnbFeedAge_: 3_600,
            maxUsdtFeedAge_: 90_000,
            maxEmergencyDuration_: 600,
            admin_: admin,
            guardian_: guardian
        });
    }

    function testPriceGuardNormalFloorUsesLowerOracleAtOnePercentBudget() public view {
        VaultBPriceGuard.Quote memory q = guard.quote(USDT, WBNB, 1_000e18, false);
        assertEq(q.chainlinkOut, 1_000e18);
        assertEq(q.twapOut, 1_000e18);
        assertEq(q.fairOut, 1_000e18);
        assertEq(q.minOut, 990e18);
        assertEq(q.lossBps, 100);
    }

    function testPriceGuardReverseDirection() public view {
        assertEq(guard.minimumOut(WBNB, USDT, 2e18, false), 1.98e18);
    }

    function testPriceGuardRejectsUnsupportedPair() public {
        vm.expectPartialRevert(VaultBPriceGuard.UnsupportedPair.selector);
        guard.minimumOut(USDT, address(0xdead), 1e18, false);
    }

    function testPriceGuardRejectsStaleFeed() public {
        bnbFeed.set(8, 7, 1e8, block.timestamp - 3_601, 7);
        vm.expectPartialRevert(VaultBPriceGuard.StaleOracle.selector);
        guard.minimumOut(USDT, WBNB, 1e18, false);
    }

    function testPriceGuardRejectsFutureFeed() public {
        bnbFeed.set(8, 7, 1e8, block.timestamp + 1, 7);
        vm.expectPartialRevert(VaultBPriceGuard.FutureOracleTimestamp.selector);
        guard.minimumOut(USDT, WBNB, 1e18, false);
    }

    function testPriceGuardRejectsIncompleteRound() public {
        bnbFeed.set(8, 7, 1e8, block.timestamp, 6);
        vm.expectPartialRevert(VaultBPriceGuard.IncompleteOracleRound.selector);
        guard.minimumOut(USDT, WBNB, 1e18, false);
    }

    function testPriceGuardRejectsOracleTwapDeviation() public {
        _setHealthyFeeds(2e8, 1e8);
        vm.expectPartialRevert(VaultBPriceGuard.OracleDeviation.selector);
        guard.minimumOut(USDT, WBNB, 1e18, false);
    }

    function testPriceGuardRejectsUnavailableTwap() public {
        pool.setFailObserve(true);
        vm.expectRevert(VaultBPriceGuard.TwapUnavailable.selector);
        guard.minimumOut(USDT, WBNB, 1e18, false);
    }

    function testEmergencyBudgetIsGuardianBoundedAndExpires() public {
        vm.expectRevert(VaultBPriceGuard.EmergencyBudgetInactive.selector);
        guard.minimumOut(USDT, WBNB, 1e18, true);

        uint64 expiresAt = uint64(block.timestamp + 300);
        vm.prank(guardian);
        guard.activateEmergencyBudget(1_000, expiresAt);
        assertEq(guard.minimumOut(USDT, WBNB, 1e18, true), 0.9e18);

        vm.warp(expiresAt);
        _setHealthyFeeds(1e8, 1e8);
        vm.expectRevert(VaultBPriceGuard.EmergencyBudgetInactive.selector);
        guard.minimumOut(USDT, WBNB, 1e18, true);
    }

    function testEmergencyBudgetRejectsOutsiderAndOverCap() public {
        vm.prank(outsider);
        vm.expectRevert();
        guard.activateEmergencyBudget(500, uint64(block.timestamp + 100));

        vm.prank(guardian);
        vm.expectRevert(VaultBPriceGuard.InvalidEmergencyBudget.selector);
        guard.activateEmergencyBudget(1_001, uint64(block.timestamp + 100));
    }

    function testKeeperMinOutOneCannotDisableOnChainFloor() public {
        uint256 out = adapter.swapAssetToPaired(1_000e18, 1, block.timestamp + 60, false);
        assertEq(out, 1_000e18);
        assertEq(router.lastMinOut(), 990e18, "on-chain floor must replace minOut=1");
        assertEq(router.lastRecipient(), address(this));
        assertEq(router.lastValue(), 0, "native BNB must never be sent");
        assertEq(IERC20(USDT).allowance(address(adapter), ROUTER), 0, "approval reset");
    }

    function testKeeperCanOnlyMakeMinOutStricter() public {
        adapter.swapAssetToPaired(1_000e18, 995e18, block.timestamp + 60, false);
        assertEq(router.lastMinOut(), 995e18);
    }

    function testRouterCannotExecuteBelowGuardFloor() public {
        router.setRate(USDT, WBNB, 0.98e18);
        vm.expectPartialRevert(MockPinnedPancakeRouter.TooLittle.selector);
        adapter.swapAssetToPaired(1_000e18, 1, block.timestamp + 60, false);
    }

    function testObservedBalanceDeltaMustMatchRouterReturn() public {
        router.setReturnBias(1);
        vm.expectPartialRevert(BoundedPancakeExecutionAdapterV2.RouterOutputMismatch.selector);
        adapter.swapAssetToPaired(1_000e18, 1, block.timestamp + 60, false);
    }

    function testOnlyMainCanExecute() public {
        vm.prank(outsider);
        vm.expectRevert(BoundedPancakeExecutionAdapterV2.NotMain.selector);
        adapter.swapAssetToPaired(1e18, 1, block.timestamp + 60, false);
    }

    function testDeadlineIsBounded() public {
        vm.expectRevert(BoundedPancakeExecutionAdapterV2.InvalidDeadline.selector);
        adapter.swapAssetToPaired(1e18, 1, block.timestamp + 121, false);
    }

    function testAdapterRejectsNativeBnb() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(adapter).call{value: 1}(
            abi.encodeCall(adapter.swapAssetToPaired, (1e18, 1, block.timestamp + 60, false))
        );
        assertFalse(ok);
        assertEq(address(adapter).balance, 0);
    }

    function testWrongChainCannotDeploy() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(VaultBPriceGuard.WrongChain.selector, 1));
        _deployGuard();
    }

    function testInvalidPoolCannotDeploy() public {
        pool.setInvalidToken0(true);
        vm.expectRevert(VaultBPriceGuard.InvalidPool.selector);
        _deployGuard();
    }

    function testFuzzKeeperMinimumCannotLowerGuardFloor(uint128 keeperMin) public {
        uint256 bounded = bound(uint256(keeperMin), 0, 1_000e18);
        adapter.swapAssetToPaired(1_000e18, bounded, block.timestamp + 60, false);
        uint256 expected = bounded > 990e18 ? bounded : 990e18;
        assertEq(router.lastMinOut(), expected);
    }
}
