// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {PartnerRegistry} from "../src/partners/PartnerRegistry.sol";
import {PartnerAttributedSplitter} from "../src/partners/PartnerAttributedSplitter.sol";
import {VaultBPriceGuard} from "../src/VaultBPriceGuard.sol";
import {VaultBCakePriceGuard} from "../src/VaultBCakePriceGuard.sol";
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
import {IVaultBPriceGuard, IVaultBRewardPriceGuard} from "../src/interfaces/IVaultBExecutionV2.sol";

/// @notice Full standalone Vault B MainV2 deployment. The graph starts
/// HALTED; this script never enables operations or moves user capital.
contract DeployVaultBV2 is Script {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;

    struct Config {
        address admin;
        address manager;
        address keeper;
        address guardian;
        address projectTreasury;
        address vaultTreasury;
        uint256 partnerShareBps;
        uint256 vaultDepositCap;
        string vaultName;
        string vaultSymbol;
        uint16 performanceFeeBps;
        uint16 normalSwapLossBps;
        uint16 maxEmergencySwapLossBps;
        uint16 maxOracleDeviationBps;
        uint16 maxEmergencyOracleDeviationBps;
        uint16 mintLossBps;
        uint16 normalCloseLossBps;
        uint16 emergencyCloseLossBps;
        uint32 twapWindow;
        uint32 maxBnbFeedAge;
        uint32 maxUsdtFeedAge;
        uint32 maxEmergencyDuration;
        uint32 maxSwapDeadlineDelay;
        uint256 maxNormalCakeNotional;
        uint256 maxEmergencyCakeNotional;
        uint256 hardMaxActiveAssets;
        uint256 hardMaxSwapPerJob;
        uint256 hardDailySwapLimit;
        uint256 initialCanaryOpenCap;
        uint256 initialSwapPerJobCap;
        uint256 initialDailySwapLimit;
    }

    struct Addresses {
        address vault;
        address registry;
        address splitter;
        address wbnbGuard;
        address wbnbExecutor;
        address cakeGuard;
        address cakeExecutor;
        address venue;
        address main;
        address adapter;
    }

    error ZeroConfigAddress();
    error RoleSeparationRequired();
    error ConfigValueOverflow(string field, uint256 value, uint256 maximum);

    function run(string memory configPath) external {
        Config memory cfg = _loadConfig(configPath);
        address deployer = msg.sender;
        vm.startBroadcast();
        Addresses memory a = _deploy(cfg, deployer);
        vm.stopBroadcast();

        console.log("VAULT=%s", a.vault);
        console.log("REGISTRY=%s", a.registry);
        console.log("SPLITTER=%s", a.splitter);
        console.log("WBNB_GUARD=%s", a.wbnbGuard);
        console.log("WBNB_EXECUTOR=%s", a.wbnbExecutor);
        console.log("CAKE_GUARD=%s", a.cakeGuard);
        console.log("CAKE_EXECUTOR=%s", a.cakeExecutor);
        console.log("VENUE=%s", a.venue);
        console.log("MAIN=%s", a.main);
        console.log("ADAPTER=%s", a.adapter);
    }

    function _deploy(Config memory cfg, address deployer) public returns (Addresses memory a) {
        require(block.chainid == 56, "BSC only");
        require(deployer == cfg.admin, "deployer must be initial admin");
        _validateConfig(cfg);

        DeepYieldVaultB vault = new DeepYieldVaultB(
            IERC20(USDT),
            cfg.vaultName,
            cfg.vaultSymbol,
            cfg.admin,
            cfg.guardian,
            cfg.vaultTreasury,
            cfg.vaultDepositCap
        );
        PartnerRegistry registry = new PartnerRegistry(address(vault), cfg.admin);
        PartnerAttributedSplitter splitter =
            new PartnerAttributedSplitter(address(registry), cfg.projectTreasury, cfg.partnerShareBps, cfg.admin);

        VaultBPriceGuard wbnbGuard = new VaultBPriceGuard(
            cfg.normalSwapLossBps,
            cfg.maxEmergencySwapLossBps,
            cfg.maxOracleDeviationBps,
            cfg.maxEmergencyOracleDeviationBps,
            cfg.twapWindow,
            cfg.maxBnbFeedAge,
            cfg.maxUsdtFeedAge,
            cfg.maxEmergencyDuration,
            cfg.admin,
            cfg.guardian
        );
        BoundedPancakeExecutionAdapterV2 wbnbExecutor = new BoundedPancakeExecutionAdapterV2(
            deployer, IVaultBPriceGuard(address(wbnbGuard)), cfg.maxSwapDeadlineDelay
        );
        VaultBCakePriceGuard cakeGuard = new VaultBCakePriceGuard(
            cfg.normalSwapLossBps,
            cfg.maxEmergencySwapLossBps,
            cfg.maxOracleDeviationBps,
            cfg.maxEmergencyOracleDeviationBps,
            cfg.maxNormalCakeNotional,
            cfg.maxEmergencyCakeNotional,
            cfg.twapWindow,
            cfg.maxBnbFeedAge,
            cfg.maxUsdtFeedAge,
            cfg.maxEmergencyDuration,
            cfg.admin,
            cfg.guardian
        );
        BoundedPancakeRewardAdapterV2 cakeExecutor = new BoundedPancakeRewardAdapterV2(
            deployer, IVaultBRewardPriceGuard(address(cakeGuard)), cfg.maxSwapDeadlineDelay
        );

        uint64 base = vm.getNonce(deployer);
        address predictedVenue = vm.computeCreateAddress(deployer, base);
        address predictedMain = vm.computeCreateAddress(deployer, base + 1);
        address predictedAdapter = vm.computeCreateAddress(deployer, base + 2);
        PancakeV3MasterchefVenue venue = new PancakeV3MasterchefVenue(
            predictedMain,
            IERC20(USDT),
            IERC20(WBNB),
            100,
            IV3PoolVenue(POOL),
            INfpmVenue(NFPM),
            IMasterchefVenue(MASTERCHEF),
            IERC20(CAKE)
        );
        DedicatedVaultMainV2 main = new DedicatedVaultMainV2({
            vault_: predictedAdapter,
            venue_: venue,
            executionAdapter_: wbnbExecutor,
            priceGuard_: wbnbGuard,
            rewardExecutionAdapter_: cakeExecutor,
            rewardPriceGuard_: cakeGuard,
            rewardToken_: IERC20(CAKE),
            mintLossBps_: cfg.mintLossBps,
            normalCloseLossBps_: cfg.normalCloseLossBps,
            emergencyCloseLossBps_: cfg.emergencyCloseLossBps,
            hardMaxActiveAssets_: cfg.hardMaxActiveAssets,
            hardMaxSwapPerJob_: cfg.hardMaxSwapPerJob,
            hardDailySwapLimit_: cfg.hardDailySwapLimit,
            initialCanaryOpenCap_: cfg.initialCanaryOpenCap,
            initialSwapPerJobCap_: cfg.initialSwapPerJobCap,
            initialDailySwapLimit_: cfg.initialDailySwapLimit,
            admin_: cfg.admin,
            keeper_: cfg.keeper,
            guardian_: cfg.guardian
        });
        DedicatedVaultStrategyAdapterV2 adapter = new DedicatedVaultStrategyAdapterV2(
            IERC20(USDT),
            address(vault),
            main,
            cfg.admin,
            cfg.manager,
            cfg.guardian,
            address(splitter),
            cfg.performanceFeeBps
        );
        require(
            address(venue) == predictedVenue && address(main) == predictedMain && address(adapter) == predictedAdapter,
            "CREATE prediction mismatch"
        );

        wbnbExecutor.bindMain(address(main));
        cakeExecutor.bindMain(address(main));
        vault.setStrategy(address(adapter));
        main.grantRole(main.GUARDIAN_ROLE(), address(adapter));
        require(main.mode() == DedicatedVaultMainV2.Mode.HALTED, "must deploy halted");

        a = Addresses({
            vault: address(vault),
            registry: address(registry),
            splitter: address(splitter),
            wbnbGuard: address(wbnbGuard),
            wbnbExecutor: address(wbnbExecutor),
            cakeGuard: address(cakeGuard),
            cakeExecutor: address(cakeExecutor),
            venue: address(venue),
            main: address(main),
            adapter: address(adapter)
        });
    }

    function _loadConfig(string memory configPath) internal view returns (Config memory cfg) {
        string memory j = vm.readFile(configPath);
        cfg.admin = vm.parseJsonAddress(j, ".admin");
        cfg.manager = vm.parseJsonAddress(j, ".manager");
        cfg.keeper = vm.parseJsonAddress(j, ".keeper");
        cfg.guardian = vm.parseJsonAddress(j, ".guardian");
        cfg.projectTreasury = vm.parseJsonAddress(j, ".projectTreasury");
        cfg.vaultTreasury = vm.parseJsonAddress(j, ".vaultTreasury");
        cfg.partnerShareBps = vm.parseJsonUint(j, ".partnerShareBps");
        cfg.vaultDepositCap = vm.parseJsonUint(j, ".vaultDepositCap");
        cfg.vaultName = vm.parseJsonString(j, ".vaultName");
        cfg.vaultSymbol = vm.parseJsonString(j, ".vaultSymbol");
        cfg.performanceFeeBps = _checkedUint16(vm.parseJsonUint(j, ".performanceFeeBps"), ".performanceFeeBps");
        cfg.normalSwapLossBps = _checkedUint16(vm.parseJsonUint(j, ".normalSwapLossBps"), ".normalSwapLossBps");
        cfg.maxEmergencySwapLossBps =
            _checkedUint16(vm.parseJsonUint(j, ".maxEmergencySwapLossBps"), ".maxEmergencySwapLossBps");
        cfg.maxOracleDeviationBps =
            _checkedUint16(vm.parseJsonUint(j, ".maxOracleDeviationBps"), ".maxOracleDeviationBps");
        cfg.maxEmergencyOracleDeviationBps = _checkedUint16(
            vm.parseJsonUint(j, ".maxEmergencyOracleDeviationBps"), ".maxEmergencyOracleDeviationBps"
        );
        cfg.mintLossBps = _checkedUint16(vm.parseJsonUint(j, ".mintLossBps"), ".mintLossBps");
        cfg.normalCloseLossBps = _checkedUint16(vm.parseJsonUint(j, ".normalCloseLossBps"), ".normalCloseLossBps");
        cfg.emergencyCloseLossBps =
            _checkedUint16(vm.parseJsonUint(j, ".emergencyCloseLossBps"), ".emergencyCloseLossBps");
        cfg.twapWindow = _checkedUint32(vm.parseJsonUint(j, ".twapWindow"), ".twapWindow");
        cfg.maxBnbFeedAge = _checkedUint32(vm.parseJsonUint(j, ".maxBnbFeedAge"), ".maxBnbFeedAge");
        cfg.maxUsdtFeedAge = _checkedUint32(vm.parseJsonUint(j, ".maxUsdtFeedAge"), ".maxUsdtFeedAge");
        cfg.maxEmergencyDuration = _checkedUint32(vm.parseJsonUint(j, ".maxEmergencyDuration"), ".maxEmergencyDuration");
        cfg.maxSwapDeadlineDelay = _checkedUint32(vm.parseJsonUint(j, ".maxSwapDeadlineDelay"), ".maxSwapDeadlineDelay");
        cfg.maxNormalCakeNotional = vm.parseJsonUint(j, ".maxNormalCakeNotional");
        cfg.maxEmergencyCakeNotional = vm.parseJsonUint(j, ".maxEmergencyCakeNotional");
        cfg.hardMaxActiveAssets = vm.parseJsonUint(j, ".hardMaxActiveAssets");
        cfg.hardMaxSwapPerJob = vm.parseJsonUint(j, ".hardMaxSwapPerJob");
        cfg.hardDailySwapLimit = vm.parseJsonUint(j, ".hardDailySwapLimit");
        cfg.initialCanaryOpenCap = vm.parseJsonUint(j, ".initialCanaryOpenCap");
        cfg.initialSwapPerJobCap = vm.parseJsonUint(j, ".initialSwapPerJobCap");
        cfg.initialDailySwapLimit = vm.parseJsonUint(j, ".initialDailySwapLimit");
    }

    function _validateConfig(Config memory cfg) internal pure {
        if (
            cfg.admin == address(0) || cfg.manager == address(0) || cfg.keeper == address(0)
                || cfg.guardian == address(0) || cfg.projectTreasury == address(0) || cfg.vaultTreasury == address(0)
        ) revert ZeroConfigAddress();
        if (
            cfg.admin == cfg.manager || cfg.admin == cfg.keeper || cfg.admin == cfg.guardian
                || cfg.manager == cfg.keeper || cfg.manager == cfg.guardian || cfg.keeper == cfg.guardian
        ) revert RoleSeparationRequired();
    }

    function _checkedUint16(uint256 value, string memory field) internal pure returns (uint16 narrowed) {
        if (value > type(uint16).max) revert ConfigValueOverflow(field, value, type(uint16).max);
        // The explicit upper-bound check above makes this narrowing lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        narrowed = uint16(value);
    }

    function _checkedUint32(uint256 value, string memory field) internal pure returns (uint32 narrowed) {
        if (value > type(uint32).max) revert ConfigValueOverflow(field, value, type(uint32).max);
        // The explicit upper-bound check above makes this narrowing lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        narrowed = uint32(value);
    }
}
