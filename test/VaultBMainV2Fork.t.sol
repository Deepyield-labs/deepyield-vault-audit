// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BoundedPancakeExecutionAdapterV2} from "../src/BoundedPancakeExecutionAdapterV2.sol";
import {BoundedPancakeRewardAdapterV2} from "../src/BoundedPancakeRewardAdapterV2.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {
    IMasterchefVenue,
    INfpmVenue,
    IV3PoolVenue,
    PancakeV3MasterchefVenue
} from "../src/PancakeV3MasterchefVenue.sol";
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {VaultBCakePriceGuard} from "../src/VaultBCakePriceGuard.sol";
import {IVaultBPriceGuard, IVaultBRewardPriceGuard} from "../src/interfaces/IVaultBExecutionV2.sol";

interface IVaultBPoolForkV2 {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint32, bool);
    function tickSpacing() external view returns (int24);
}

contract VaultBMainV2ForkTest is Test {
    address internal constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");

    VaultBPriceGuard internal guard;
    VaultBCakePriceGuard internal rewardGuard;
    BoundedPancakeExecutionAdapterV2 internal executor;
    BoundedPancakeRewardAdapterV2 internal rewardExecutor;
    PancakeV3MasterchefVenue internal venue;
    DedicatedVaultMainV2 internal main;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        guard = new VaultBPriceGuard(100, 1_000, 500, 1_000, 1_800, 3_600, 90_000, 600, admin, guardian);
        executor = new BoundedPancakeExecutionAdapterV2(address(this), IVaultBPriceGuard(address(guard)), 120);
        rewardGuard =
            new VaultBCakePriceGuard(100, 1_000, 500, 1_000, 5_100e18, 50_000e18, 1_800, 3_600, 90_000, 600, admin, guardian);
        rewardExecutor =
            new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(rewardGuard)), 120);

        uint256 base = vm.getNonce(address(this));
        address predictedMain = vm.computeCreateAddress(address(this), base + 1);
        venue = new PancakeV3MasterchefVenue(
            predictedMain,
            IERC20(USDT),
            IERC20(WBNB),
            100,
            IV3PoolVenue(POOL),
            INfpmVenue(NFPM),
            IMasterchefVenue(MASTERCHEF),
            IERC20(CAKE)
        );
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
            initialSwapPerJobCap_: 2_000e18,
            initialDailySwapLimit_: 4_000e18,
            admin_: admin,
            keeper_: keeper,
            guardian_: guardian
        });
        assertEq(address(main), predictedMain, "predicted venue controller");
        executor.bindMain(address(main));
        rewardExecutor.bindMain(address(main));
        vm.prank(admin);
        main.enableOperations();
    }

    function testForkFullMainV2LifecycleStaysWbnbNativeFreeAndRestartSafe() public {
        uint256 positionId = _fundAndOpen(keccak256("fork-main-v2-open"));

        assertEq(address(main).balance, 0, "Main never holds native BNB");
        assertGt(main.totalAssetsUsdt(), 950e18, "conservative NAV remains coherent");

        bytes32 withdrawalId = keccak256("fork-main-v2-withdrawal");
        main.requestWithdrawal(withdrawalId, 900e18);
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.OPERATING));
        assertFalse(main.withdrawalCycleCommitted());

        bytes32 closeJob = keccak256("fork-main-v2-close");
        vm.prank(keeper);
        main.closeToInventory(closeJob, block.timestamp + 60, false);
        assertTrue(main.withdrawalCycleCommitted(), "LP close atomically commits the queued batch");
        assertEq(main.activePositionId(), 0);
        assertGt(IERC20(WBNB).balanceOf(address(main)), 0, "LP close returns canonical WBNB inventory");

        bytes32 sellJob = keccak256("fork-main-v2-sell-wbnb");
        vm.prank(keeper);
        main.liquidateAllWbnb(sellJob, 0, 1, block.timestamp + 60, true, false);
        assertEq(IERC20(WBNB).balanceOf(address(main)), 0);
        assertEq(address(main).balance, 0, "WBNB is not unwrapped");

        uint256 rewardBalance = IERC20(CAKE).balanceOf(address(main));
        if (rewardBalance != 0) {
            vm.prank(keeper);
            main.liquidateAllReward(keccak256("fork-main-v2-sell-cake"), 0, 1, block.timestamp + 60, true, false);
            assertEq(IERC20(CAKE).balanceOf(address(main)), 0);
        }

        uint256 before = IERC20(USDT).balanceOf(address(this));
        assertEq(main.claimWithdrawal(withdrawalId, 900e18), 900e18);
        assertEq(IERC20(USDT).balanceOf(address(this)) - before, 900e18);
        assertFalse(main.withdrawalCycleCommitted());

        (, DedicatedVaultMainV2.JobStatus openStatus,,,,,,) = main.jobs(keccak256("fork-main-v2-open"));
        (, DedicatedVaultMainV2.JobStatus closeStatus,,,,,,) = main.jobs(closeJob);
        (, DedicatedVaultMainV2.JobStatus sellStatus,,,,,,) = main.jobs(sellJob);
        assertEq(uint256(openStatus), uint256(DedicatedVaultMainV2.JobStatus.COMPLETED));
        assertEq(uint256(closeStatus), uint256(DedicatedVaultMainV2.JobStatus.COMPLETED));
        assertEq(uint256(sellStatus), uint256(DedicatedVaultMainV2.JobStatus.COMPLETED));

        assertGt(positionId, 0);
    }

    function testForkCakeLiquidationUsesTypedRouteAndOnChainFloor() public {
        deal(CAKE, address(main), 100e18);
        uint256 before = IERC20(USDT).balanceOf(address(main));

        vm.prank(keeper);
        uint256 out = main.liquidateAllReward(keccak256("fork-main-v2-cake"), 0, 1, block.timestamp + 60, true, false);

        assertGt(out, 100e18, "100 CAKE has executable USDT value");
        assertEq(IERC20(USDT).balanceOf(address(main)) - before, out);
        assertEq(IERC20(CAKE).balanceOf(address(main)), 0);
        assertEq(IERC20(CAKE).allowance(address(main), address(rewardExecutor)), 0);
        assertEq(address(main).balance, 0, "CAKE route never handles native BNB");
    }

    function testForkCakeNormalRouteClearsFiveHundredAndFiveThousandThenLargeInventoryNeedsEmergencyBudget() public {
        vm.prank(admin);
        main.setOperationalCaps(1_000e18, 50_000e18, 100_000e18);

        uint256 fairPerCake = rewardGuard.fairValue(1e18);
        uint256[2] memory targets = [uint256(500e18), uint256(5_000e18)];
        for (uint256 i; i < targets.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 amountIn = targets[i] * 1e18 / fairPerCake;
            uint256 guardMin = rewardGuard.minimumOut(amountIn, false);
            deal(CAKE, address(main), amountIn);

            vm.prank(keeper);
            uint256 out = main.liquidateAllReward(
                keccak256(abi.encode("fork-main-v2-cake-ladder", i)), 0, 1, block.timestamp + 60, true, false
            );

            assertGe(out, guardMin, "real route must clear immutable normal floor");
            assertEq(IERC20(CAKE).balanceOf(address(main)), 0);
            assertTrue(vm.revertToState(snapshot));
        }

        uint256 largeAmountIn = 49_999e18 * 1e18 / fairPerCake;
        deal(CAKE, address(main), largeAmountIn);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBCakePriceGuard.CapacityExceeded.selector);
        main.liquidateAllReward(keccak256("fork-main-v2-cake-large-normal"), 0, 1, block.timestamp + 60, true, false);

        vm.prank(guardian);
        rewardGuard.activateEmergencyBudget(300, uint64(block.timestamp + 300));
        uint256 emergencyMin = rewardGuard.minimumOut(largeAmountIn, true);
        vm.prank(guardian);
        uint256 emergencyOut = main.liquidateAllReward(
            keccak256("fork-main-v2-cake-large-emergency"), 0, 1, block.timestamp + 60, true, true
        );
        assertGe(emergencyOut, emergencyMin, "guardian budget is finite and on chain");
        assertEq(IERC20(CAKE).balanceOf(address(main)), 0);
    }

    function testForkGuardianForceUnstakeCanContinueThroughNormalBoundedClose() public {
        uint256 positionId = _fundAndOpen(keccak256("fork-main-v2-force-open"));
        assertTrue(venue.activeStaked());

        vm.prank(guardian);
        main.forceUnstakeSkipHarvest();
        assertFalse(venue.activeStaked());
        assertEq(main.activePositionId(), positionId, "recovery must not fake an LP close");

        vm.prank(keeper);
        main.closeToInventory(keccak256("fork-main-v2-force-close"), block.timestamp + 60, false);
        assertEq(main.activePositionId(), 0);
        assertEq(venue.activeTokenId(), 0);
        assertGt(IERC20(WBNB).balanceOf(address(main)), 0);
        assertEq(address(main).balance, 0, "recovery path must remain WBNB-only");
    }

    function _fundAndOpen(bytes32 openJob) internal returns (uint256 positionId) {
        deal(USDT, address(this), 1_000e18);
        IERC20(USDT).approve(address(main), 1_000e18);
        main.fundFromVault(1_000e18);

        (, int24 tick,,,,,) = IVaultBPoolForkV2(POOL).slot0();
        int24 spacing = IVaultBPoolForkV2(POOL).tickSpacing();
        int24 center = (tick / spacing) * spacing;
        vm.prank(keeper);
        positionId = main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: openJob,
                tickLower: center - 70 * spacing,
                tickUpper: center + 70 * spacing,
                assetBudget: 1_000e18,
                swapAssetIn: 500e18,
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
        assertGt(positionId, 0);
        assertEq(main.activePositionId(), positionId);
    }
}
