// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployVaultBV2} from "../script/DeployVaultBV2.s.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {DedicatedVaultStrategyAdapterV2} from "../src/DedicatedVaultStrategyAdapterV2.sol";
import {BoundedPancakeExecutionAdapterV2} from "../src/BoundedPancakeExecutionAdapterV2.sol";
import {BoundedPancakeRewardAdapterV2} from "../src/BoundedPancakeRewardAdapterV2.sol";
import {PancakeV3MasterchefVenue} from "../src/PancakeV3MasterchefVenue.sol";
import {PartnerRegistry} from "../src/partners/PartnerRegistry.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";

contract DeployVaultBV2DryRunTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    DeployVaultBV2 internal script;
    DeployVaultBV2.Config internal cfg;
    DeployVaultBV2.Addresses internal deployed;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        script = new DeployVaultBV2();
        cfg = DeployVaultBV2.Config({
            admin: address(script),
            manager: makeAddr("manager"),
            keeper: makeAddr("keeper"),
            guardian: makeAddr("guardian"),
            projectTreasury: makeAddr("projectTreasury"),
            vaultTreasury: makeAddr("vaultTreasury"),
            partnerShareBps: 2_500,
            vaultDepositCap: 50_000e18,
            vaultName: "DeepYield Vault B V2",
            vaultSymbol: "dyBV2",
            performanceFeeBps: 2_000,
            normalSwapLossBps: 100,
            maxEmergencySwapLossBps: 1_000,
            maxOracleDeviationBps: 500,
            maxEmergencyOracleDeviationBps: 1_000,
            mintLossBps: 100,
            normalCloseLossBps: 100,
            emergencyCloseLossBps: 1_000,
            twapWindow: 1_800,
            maxBnbFeedAge: 3_600,
            maxUsdtFeedAge: 90_000,
            maxEmergencyDuration: 600,
            maxSwapDeadlineDelay: 120,
            maxNormalCakeNotional: 5_100e18,
            maxEmergencyCakeNotional: 50_000e18,
            hardMaxActiveAssets: 50_000e18,
            hardMaxSwapPerJob: 50_000e18,
            hardDailySwapLimit: 100_000e18,
            initialCanaryOpenCap: 500e18,
            initialSwapPerJobCap: 1_000e18,
            initialDailySwapLimit: 2_000e18
        });
        deployed = script._deploy(cfg, address(script));
    }

    function testFullGraphIsCanonicalWiredAndStartsHalted() public view {
        DeepYieldVaultB vault = DeepYieldVaultB(deployed.vault);
        DedicatedVaultMainV2 main = DedicatedVaultMainV2(deployed.main);
        DedicatedVaultStrategyAdapterV2 adapter = DedicatedVaultStrategyAdapterV2(deployed.adapter);
        BoundedPancakeExecutionAdapterV2 wbnbExecutor = BoundedPancakeExecutionAdapterV2(deployed.wbnbExecutor);
        BoundedPancakeRewardAdapterV2 cakeExecutor = BoundedPancakeRewardAdapterV2(deployed.cakeExecutor);
        PancakeV3MasterchefVenue venue = PancakeV3MasterchefVenue(deployed.venue);

        assertEq(vault.asset(), USDT);
        assertEq(address(vault.strategy()), address(adapter));
        assertEq(address(adapter.asset()), USDT);
        assertEq(adapter.vault(), address(vault));
        assertEq(address(adapter.main()), address(main));
        assertEq(main.vault(), address(adapter));
        assertEq(address(main.venue()), address(venue));
        assertEq(venue.controller(), address(main));
        assertEq(wbnbExecutor.main(), address(main));
        assertEq(cakeExecutor.main(), address(main));
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED));
        assertEq(vault.maxDeposit(address(this)), 0, "halted deployment cannot accept capital");
        assertEq(main.canaryOpenCap(), 500e18);
        assertEq(main.hardMaxActiveAssets(), 50_000e18);
        assertTrue(main.hasRole(main.GUARDIAN_ROLE(), address(adapter)));
    }

    function testPartnerAndFeeWiringHasNoArbitraryRecipient() public view {
        PartnerRegistry registry = PartnerRegistry(deployed.registry);
        PartnerAttributedSplitter splitter = PartnerAttributedSplitter(deployed.splitter);
        DedicatedVaultStrategyAdapterV2 adapter = DedicatedVaultStrategyAdapterV2(deployed.adapter);

        assertEq(registry.vault(), deployed.vault);
        assertEq(splitter.registry(), deployed.registry);
        assertEq(splitter.vault(), deployed.vault);
        assertEq(adapter.feeRecipient(), deployed.splitter);
        assertEq(adapter.performanceFeeBps(), 2_000);
    }

    function testExplicitAdminEnableIsTheOnlyTransitionThatAdmitsDeposits() public {
        DeepYieldVaultB vault = DeepYieldVaultB(deployed.vault);
        DedicatedVaultMainV2 main = DedicatedVaultMainV2(deployed.main);
        address user = makeAddr("user");
        deal(USDT, user, 10e18);
        vm.startPrank(user);
        IERC20(USDT).approve(address(vault), 10e18);
        vm.expectRevert(DeepYieldVaultB.DepositCapExceeded.selector);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vm.prank(address(script));
        main.enableOperations();
        assertEq(vault.maxDeposit(user), 50_000e18);
        vm.prank(user);
        vault.deposit(10e18, user);
        assertGt(vault.balanceOf(user), 0);
    }

    function testWrongCreatorAdminPairFailsBeforeAnyDeployment() public {
        DeployVaultBV2.Config memory bad = cfg;
        bad.admin = makeAddr("notScript");
        vm.expectRevert(bytes("deployer must be initial admin"));
        script._deploy(bad, address(script));
    }
}
