// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {BoundedPancakeExecutionAdapterV2} from "../src/BoundedPancakeExecutionAdapterV2.sol";
import {BoundedPancakeRewardAdapterV2} from "../src/BoundedPancakeRewardAdapterV2.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {DedicatedVaultStrategyAdapterV2} from "../src/DedicatedVaultStrategyAdapterV2.sol";
import {
    IMasterchefVenue,
    INfpmVenue,
    IV3PoolVenue,
    PancakeV3MasterchefVenue
} from "../src/PancakeV3MasterchefVenue.sol";
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {VaultBCakePriceGuard} from "../src/VaultBCakePriceGuard.sol";
import {IVaultBPriceGuard, IVaultBRewardPriceGuard} from "../src/interfaces/IVaultBExecutionV2.sol";
import {IFeeSink} from "../src/interfaces/IFeeSink.sol";

interface IVaultBAsyncPoolFork {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint32, bool);
    function tickSpacing() external view returns (int24);
}

contract MockVaultBFeeSinkFork is IFeeSink {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function recordFee(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }
}

contract VaultBAsyncRedeemV2ForkTest is Test {
    address internal constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal user = makeAddr("user");

    DeepYieldVaultB internal vault;
    VaultBPriceGuard internal guard;
    VaultBCakePriceGuard internal rewardGuard;
    BoundedPancakeExecutionAdapterV2 internal executor;
    BoundedPancakeRewardAdapterV2 internal rewardExecutor;
    PancakeV3MasterchefVenue internal venue;
    DedicatedVaultMainV2 internal main;
    DedicatedVaultStrategyAdapterV2 internal adapter;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        feeRecipient = address(new MockVaultBFeeSinkFork(IERC20(USDT)));
        vault = new DeepYieldVaultB(
            IERC20(USDT), "DeepYield Vault B V2", "dyBV2", admin, guardian, feeRecipient, 50_000e18
        );
        guard = new VaultBPriceGuard(100, 1_000, 500, 1_800, 3_600, 90_000, 600, admin, guardian);
        executor = new BoundedPancakeExecutionAdapterV2(address(this), IVaultBPriceGuard(address(guard)), 120);
        rewardGuard =
            new VaultBCakePriceGuard(100, 1_000, 500, 5_100e18, 50_000e18, 1_800, 3_600, 90_000, 600, admin, guardian);
        rewardExecutor =
            new BoundedPancakeRewardAdapterV2(address(this), IVaultBRewardPriceGuard(address(rewardGuard)), 120);

        uint64 base = vm.getNonce(address(this));
        address predictedVenue = vm.computeCreateAddress(address(this), base);
        address predictedMain = vm.computeCreateAddress(address(this), base + 1);
        address predictedAdapter = vm.computeCreateAddress(address(this), base + 2);
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
        assertEq(address(venue), predictedVenue);
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
            initialSwapPerJobCap_: 2_000e18,
            initialDailySwapLimit_: 4_000e18,
            admin_: admin,
            keeper_: keeper,
            guardian_: guardian
        });
        assertEq(address(main), predictedMain);
        adapter = new DedicatedVaultStrategyAdapterV2(
            IERC20(USDT), address(vault), main, admin, manager, guardian, feeRecipient, 2_000
        );
        assertEq(address(adapter), predictedAdapter);

        executor.bindMain(address(main));
        rewardExecutor.bindMain(address(main));
        bytes32 mainGuardianRole = main.GUARDIAN_ROLE();
        vm.prank(admin);
        main.grantRole(mainGuardianRole, address(adapter));
        vm.prank(admin);
        vault.setStrategy(address(adapter));
        vm.prank(admin);
        main.enableOperations();
    }

    function testForkQueuedRedeemTraversesRealLpWbnbCakeAndClaimTimeNav() public {
        deal(USDT, user, 1_000e18);
        vm.startPrank(user);
        IERC20(USDT).approve(address(vault), 1_000e18);
        uint256 shares = vault.deposit(1_000e18, user);
        vm.stopPrank();
        uint256 deployable = adapter.maxDeployableAssets();
        vm.prank(manager);
        adapter.deploy(deployable);

        (, int24 tick,,,,,) = IVaultBAsyncPoolFork(POOL).slot0();
        int24 spacing = IVaultBAsyncPoolFork(POOL).tickSpacing();
        int24 center = tick / spacing * spacing;
        vm.prank(keeper);
        main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: keccak256("async-fork-open"),
                tickLower: center - 70 * spacing,
                tickUpper: center + 70 * spacing,
                assetBudget: deployable,
                swapAssetIn: deployable / 2,
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
        assertGt(vault.maxRedeem(user), 0, "the enforced idle reserve remains synchronously redeemable");

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);
        vault.commitRedeemCycle();
        assertEq(requestId, 0);
        assertEq(main.queuedWithdrawalCount(), 1);

        vm.prank(keeper);
        main.closeToInventory(keccak256("async-fork-close"), block.timestamp + 60, false);
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("async-fork-wbnb"), 0, 1, block.timestamp + 60, true, false);
        uint256 rewardBalance = IERC20(CAKE).balanceOf(address(main));
        if (rewardBalance != 0) {
            vm.prank(keeper);
            main.liquidateAllReward(keccak256("async-fork-cake"), 0, 1, block.timestamp + 60, true, false);
        }

        uint256 claimable = vault.claimableRedeemRequest(requestId);
        assertGt(claimable, 900e18, "real round trip remains economically coherent");
        uint256 received = vault.claimRedeem(requestId);

        assertEq(received, claimable);
        assertEq(IERC20(USDT).balanceOf(user), received);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.outstandingRedeemShares(), 0);
        assertEq(main.queuedWithdrawalCount(), 0);
        assertEq(IERC20(WBNB).balanceOf(address(main)), 0);
        assertEq(IERC20(CAKE).balanceOf(address(main)), 0);
        assertEq(address(vault).balance, 0);
        assertEq(address(adapter).balance, 0);
        assertEq(address(main).balance, 0);
        assertEq(vault.maxDeposit(user), 0, "closed mode blocks deposits after settlement");

        vm.prank(admin);
        main.enableOperations();
        assertGt(vault.maxDeposit(user), 0, "admin explicitly starts the next capital cycle");
    }
}
