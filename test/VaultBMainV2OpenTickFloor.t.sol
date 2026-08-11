// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {IDedicatedVenue, IDedicatedVenueV2} from "../src/interfaces/IDedicatedVenue.sol";
import {
    MockMainV2Token,
    MockMainV2PriceGuard,
    MockMainV2ExecutionAdapter,
    MockMainV2RewardAdapter
} from "./VaultBMainV2.t.sol";

/// @notice B1-T4 — openPosition must validate the tick range against the TWAP,
/// anchor its mint minimums to the TWAP (not the tautological same-block spot),
/// and enforce an aggregate mint-value floor so a spot pushed to the range edge
/// cannot mint a skewed, lower-value position.

/// @dev Venue mock whose open() consumes a configurable amount (modelling a
/// spot-driven mint) and leaves the rest with the controller, so Main's post-mint
/// aggregate floor can be exercised. It does NOT enforce the passed minima — the
/// point is to reach Main's floor, not the venue's own slippage guard.
contract ConfigurableVenue is IDedicatedVenueV2 {
    using SafeERC20 for IERC20;

    address public controller;
    IERC20 public asset;
    IERC20 public paired;
    uint24 public constant fee = 100;
    uint256 public activeId;
    uint256 public nextId = 1;
    uint256 public consumeAsset;
    uint256 public consumePaired;
    bool public consumeConfigured;

    constructor(IERC20 asset_, IERC20 paired_) {
        asset = asset_;
        paired = paired_;
    }

    function bindController(address c) external {
        controller = c;
    }

    function setConsumption(uint256 a, uint256 p) external {
        consumeAsset = a;
        consumePaired = p;
        consumeConfigured = true;
    }

    function poolAddress() external pure returns (address) {
        return 0x172fcD41E0913e95784454622d1c3724f546f849;
    }

    function open(OpenArgs calldata a) external returns (uint256 positionId) {
        require(msg.sender == controller, "controller");
        uint256 ca = consumeConfigured ? consumeAsset : a.assetAmount;
        uint256 cp = consumeConfigured ? consumePaired : a.pairedAmount;
        if (ca > 0) asset.safeTransferFrom(msg.sender, address(this), ca);
        if (cp > 0) paired.safeTransferFrom(msg.sender, address(this), cp);
        positionId = nextId++;
        activeId = positionId;
    }

    function previewOpenAmounts(uint256 assetDesired, uint256 pairedDesired, int24, int24)
        external
        pure
        returns (uint256, uint256)
    {
        return (assetDesired, pairedDesired); // unused by the fixed Main (kept for the interface)
    }

    function close(uint256, uint256, uint256, uint256) external {
        activeId = 0;
    }

    function harvest(uint256) external pure returns (uint256) {
        return 0;
    }

    function forceUnstakeSkipHarvest(uint256) external {}

    function positionValueAsset(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewCloseAmounts(uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function previewCloseAmountsAtSqrtPrice(uint256, uint160) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract VaultBMainV2OpenTickFloorTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");

    MockMainV2Token internal usdt;
    MockMainV2Token internal wbnb;
    MockMainV2Token internal cake;
    MockMainV2PriceGuard internal guard;
    MockMainV2PriceGuard internal rewardGuard;
    MockMainV2ExecutionAdapter internal executor;
    MockMainV2RewardAdapter internal rewardExecutor;
    ConfigurableVenue internal venue;
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
        venue = new ConfigurableVenue(IERC20(USDT), IERC20(WBNB));
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
        wbnb.mint(address(executor), 100_000e18);
        IERC20(USDT).approve(address(main), type(uint256).max);

        vm.prank(admin);
        main.enableOperations();
        main.fundFromVault(1_000e18);
    }

    function _etchToken(address target) internal {
        MockMainV2Token template = new MockMainV2Token();
        vm.etch(target, address(template).code);
    }

    function _open(int24 tickLower, int24 tickUpper, uint256 keeperMinOut) internal returns (uint256) {
        vm.prank(keeper);
        return main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: keccak256(abi.encode("OPEN", tickLower, tickUpper, keeperMinOut)),
                tickLower: tickLower,
                tickUpper: tickUpper,
                assetBudget: 1_000e18,
                swapAssetIn: 500e18,
                keeperPairedMinOut: keeperMinOut,
                deadline: block.timestamp + 60
            })
        );
    }

    // ── п.1: tick width bounds ───────────────────────────────────────────────
    function test_RejectsTooNarrowTickRange() public {
        vm.expectRevert(abi.encodeWithSelector(DedicatedVaultMainV2.InvalidTickRange.selector, int24(0), int24(1)));
        _open(0, 1, 1); // width 1 < minTickWidth 2
    }

    // ── п.2: range must straddle the TWAP, not just spot ─────────────────────
    function test_RejectsRangeNotCoveringTwap() public {
        // TWAP is tick 0 (mock returns sqrt price 1); a [100,300] range excludes it.
        vm.expectRevert(DedicatedVaultMainV2.TwapOutsideTickRange.selector);
        _open(100, 300, 1);
    }

    // ── п.3: a 1-wei leg is no longer accepted as two-sided ──────────────────
    function test_RejectsOneWeiPairedLeg() public {
        executor.setForcedOut(1); // swap yields 1 wei of paired
        vm.expectRevert(DedicatedVaultMainV2.OpenNotTwoSided.selector);
        _open(-100, 100, 0);
    }

    // ── п.4: front-run skew trips the aggregate mint floor (CENTRAL) ─────────
    function test_FrontRunSkewedMintRevertsByAggregateFloor() public {
        // A spot pushed to the range edge makes the mint consume a tiny, low-value
        // ratio; Main's floor requires deployed value >= TWAP-fair value - budget.
        venue.setConsumption(1e18, 1e18);
        vm.expectPartialRevert(DedicatedVaultMainV2.MintValueBelowFloor.selector);
        _open(-100, 100, 0);
    }

    // ── п.5: honest calm-market open still works (regression) ────────────────
    function test_HonestOpenSucceeds() public {
        uint256 id = _open(-100, 100, 1);
        assertGt(id, 0);
        assertEq(main.activePositionId(), id);
    }

    // ── п.6: pre-swap is protected by the executor even with keeperMinOut=0 ───
    function test_PreSwapProtectedByExecutorFloorWithZeroKeeperMinOut() public {
        _open(-100, 100, 0);
        // executor floored the swap at the guard minimum (500 * (1-1%) = 495e18),
        // not at the keeper's 0 — no second floor in Main is needed.
        assertEq(executor.lastEffectiveMinOut(), 495e18, "guard floor applied despite keeperMinOut=0");
    }
}
