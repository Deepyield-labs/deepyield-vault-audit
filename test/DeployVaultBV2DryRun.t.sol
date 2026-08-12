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
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {VaultBCakePriceGuard} from "../src/VaultBCakePriceGuard.sol";
import {PancakeV3MasterchefVenue} from "../src/PancakeV3MasterchefVenue.sol";
import {PartnerRegistry} from "../src/partners/PartnerRegistry.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";

contract DeployVaultBV2DryRunTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    DeployVaultBV2 internal script;
    DeployVaultBV2.Config internal cfg;
    DeployVaultBV2.Addresses internal deployed;

    function setUp() public {
        // INTENTIONALLY UNPINNED by default (T-T1): this suite asserts the LIVE V2
        // deploy wiring (asset/strategy/adapter), not block-sensitive arithmetic, and
        // it runs in the default (non-archive) suite — a pinned historical block would
        // fail there with `missing trie node`. Wiring asserts are block-invariant, so
        // latest is deterministic. Override BSC_FORK_BLOCK (needs an archive
        // BSC_FORK_RPC) only to deliberately pin it.
        string memory rpc = vm.envOr("BSC_FORK_RPC", vm.rpcUrl("bsc"));
        uint256 pin = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
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
        VaultBPriceGuard wbnbGuard = VaultBPriceGuard(deployed.wbnbGuard);
        VaultBCakePriceGuard cakeGuard = VaultBCakePriceGuard(deployed.cakeGuard);
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
        assertTrue(wbnbGuard.hasRole(wbnbGuard.EMERGENCY_CONSUMER_ROLE(), address(wbnbExecutor)));
        assertTrue(cakeGuard.hasRole(cakeGuard.EMERGENCY_CONSUMER_ROLE(), address(cakeExecutor)));
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
        assertEq(registry.factory(), address(0), "wrapper factory is intentionally outside the V2 graph");
        assertEq(registry.activeWrapperCount(), 0, "no wrapper may be active in the audited V2 graph");
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
