// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {
    IVaultBPriceGuard, IVaultBRewardPriceGuard
} from "../src/interfaces/IVaultBExecutionV2.sol";
import {
    MockMainV2Token,
    MockMainV2ExecutionAdapter,
    MockMainV2RewardAdapter,
    MockMainV2Venue
} from "./VaultBMainV2.t.sol";

/// @notice B1-T5 — the close floor must measure execution slippage on ONE basis,
/// a spot-vs-oracle gate must catch manipulation (which an honest TWAP lag does
/// not trip), and NAV must not inflate on TWAP/spot divergence.

/// @dev Price guard with a settable oracle price (USDT per WBNB) and TWAP sqrt.
contract RichGuard is IVaultBPriceGuard, IVaultBRewardPriceGuard {
    uint256 public oracleUsdtPerWbnb = 1e18; // USDT (18dec) per 1 WBNB
    uint160 public twapSqrt = uint160(0x1000000000000000000000000); // 2^96 = price 1
    uint16 public lossBps = 100;

    function setOracle(uint256 p) external {
        oracleUsdtPerWbnb = p;
    }

    function setTwapSqrt(uint160 s) external {
        twapSqrt = s;
    }

    function _quote(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        // WBNB -> USDT uses the oracle price; USDT -> WBNB (or reward) echoes.
        if (tokenIn == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            return amountIn * oracleUsdtPerWbnb / 1e18;
        }
        return amountIn;
    }

    function minimumOut(address tokenIn, address, uint256 amountIn, bool) external view returns (uint256) {
        return _quote(tokenIn, amountIn) * (10_000 - lossBps) / 10_000;
    }

    function fairValue(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        return _quote(tokenIn, amountIn);
    }

    function twapSqrtPriceX96() external view returns (uint160) {
        return twapSqrt;
    }

    function minimumOut(uint256 amountIn, bool) external view returns (uint256) {
        return amountIn * (10_000 - lossBps) / 10_000;
    }

    function fairValue(uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }
}

contract VaultBMainV2CloseFloorBasisTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    uint160 internal constant SQRT_P1 = uint160(0x1000000000000000000000000); // price 1

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");

    MockMainV2Token internal usdt;
    MockMainV2Token internal wbnb;
    MockMainV2Token internal cake;
    RichGuard internal guard;
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

        guard = new RichGuard();
        executor = new MockMainV2ExecutionAdapter(address(this), guard);
        rewardExecutor = new MockMainV2RewardAdapter(address(this), guard);
        venue = new MockMainV2Venue(IERC20(USDT), IERC20(WBNB));
        main = new DedicatedVaultMainV2({
            vault_: address(this),
            venue_: venue,
            executionAdapter_: executor,
            priceGuard_: guard,
            rewardExecutionAdapter_: rewardExecutor,
            rewardPriceGuard_: guard,
            rewardToken_: IERC20(CAKE),
            mintLossBps_: 100,
            normalCloseLossBps_: 100,
            emergencyCloseLossBps_: 1_000,
            hardMaxActiveAssets_: 50_000e18,
            hardMaxSwapPerJob_: 50_000e18,
            hardDailySwapLimit_: 100_000e18,
            initialCanaryOpenCap_: 2_000e18,
            initialSwapPerJobCap_: 2_000e18,
            initialDailySwapLimit_: 4_000e18,
            admin_: admin,
            keeper_: keeper,
            guardian_: guardian
        });
        executor.bindMain(address(main));
        rewardExecutor.bindMain(address(main));
        venue.bindController(address(main));
        _setSpotSqrt(SQRT_P1); // spot == oracle price 1 by default

        usdt.mint(address(this), 100_000e18);
        usdt.mint(address(executor), 100_000e18);
        wbnb.mint(address(executor), 100_000e18);
        IERC20(USDT).approve(address(main), type(uint256).max);

        vm.prank(admin);
        main.enableOperations();
    }

    function _etchToken(address t) internal {
        MockMainV2Token template = new MockMainV2Token();
        vm.etch(t, address(template).code);
    }

    function _setSpotSqrt(uint160 s) internal {
        vm.mockCall(
            POOL,
            abi.encodeWithSignature("slot0()"),
            abi.encode(s, int24(0), uint16(0), uint16(0), uint16(0), uint32(0), true)
        );
    }

    function _open() internal returns (uint256) {
        main.fundFromVault(2_000e18);
        vm.prank(keeper);
        return main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: keccak256("OPEN"),
                tickLower: -100,
                tickUpper: 100,
                assetBudget: 1_000e18,
                swapAssetIn: 500e18,
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
    }

    // ── п.1: manipulate spot to the lower edge -> revert (gate) ──────────────
    function test_ManipulatedSpotLowRevertsAtGate() public {
        _open();
        venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);
        _setSpotSqrt(uint160(2 * uint256(SQRT_P1))); // spot price 0.25 vs oracle 1

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SpotDivergedFromOracle.selector);
        main.closeToInventory(keccak256("close"), block.timestamp + 60, false);
    }

    // ── п.2: manipulate spot to the upper edge -> revert (gate) ──────────────
    function test_ManipulatedSpotHighRevertsAtGate() public {
        _open();
        venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);
        _setSpotSqrt(uint160(uint256(SQRT_P1) / 2)); // spot price 4 vs oracle 1

        vm.prank(keeper);
        vm.expectPartialRevert(DedicatedVaultMainV2.SpotDivergedFromOracle.selector);
        main.closeToInventory(keccak256("close"), block.timestamp + 60, false);
    }

    // ── п.3: honest TWAP lag (spot == oracle) closes successfully ────────────
    // The old TWAP-composition floor would block this at zero execution slippage;
    // the new spot-basis floor does not.
    function test_HonestTwapLagClosesSuccessfully() public {
        uint256 id = _open();
        // spot == oracle (gate passes); TWAP composition lags high (1300) but the
        // floor now uses the spot composition (1000), which the close realizes.
        venue.configureClose(1_000e18, 0, 1_300e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);

        vm.prank(keeper);
        main.closeToInventory(keccak256("close"), block.timestamp + 60, false);
        assertEq(main.activePositionId(), 0, "honest lagging-TWAP close is no longer blocked");
        assertEq(id, id);
    }

    // ── п.4: real execution slippage above budget still reverts ──────────────
    // Under the one-basis floor the per-leg LP minimum (amount0Min from the spot
    // composition) is the active execution-slippage guard and reverts first; the
    // aggregate CloseValueBelowFloor is a redundant backstop on the measured total
    // (see report). A 15%-short close is rejected, so protection survives the new
    // gate rather than being replaced by it.
    function test_RealExecutionSlippageStillReverts() public {
        _open();
        venue.configureClose(1_000e18, 0, 1_000e18, 0, 850e18, 0); // realizes 15% under min 990
        _mintCloseInventory(850e18, 0);

        vm.prank(keeper);
        vm.expectRevert(bytes("close min"));
        main.closeToInventory(keccak256("close"), block.timestamp + 60, false);
    }

    // ── п.5: NAV does not inflate on TWAP/spot divergence ────────────────────
    function test_NavTakesLowerOfTwapAndSpot() public {
        _open();
        // spot leg inflated (900) vs twap leg (600); NAV must take the lower.
        venue.configureClose(900e18, 0, 600e18, 0, 0, 0);
        // 1000 idle + min(spot 900, twap 600) = 1600.
        assertEq(main.totalAssetsUsdt(), 1_600e18);
    }

    // ── п.6: calm market (spot ~= oracle, twap ~= spot) closes as before ─────
    function test_CalmMarketCloseUnchanged() public {
        _open();
        venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);

        vm.prank(keeper);
        main.closeToInventory(keccak256("close"), block.timestamp + 60, false);
        assertEq(main.activePositionId(), 0);
    }

    function _mintCloseInventory(uint256 a, uint256 p) internal {
        if (a != 0) usdt.mint(address(venue), a);
        if (p != 0) wbnb.mint(address(venue), p);
    }
}
