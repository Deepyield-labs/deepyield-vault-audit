// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DedicatedVaultMain} from "../src/DedicatedVaultMain.sol";
import {DedicatedVaultStrategyAdapter} from "../src/DedicatedVaultStrategyAdapter.sol";
import {PancakeV3MasterchefVenue, INfpmVenue, IMasterchefVenue, IV3PoolVenue} from "../src/PancakeV3MasterchefVenue.sol";
import {PancakeV3SwapAdapter, ISmartRouterV3} from "../src/PancakeV3SwapAdapter.sol";
import {ExcludeIdlePairedQuoter} from "../src/ExcludeIdlePairedQuoter.sol";

/// @notice Audit-readiness GUARD: constructs the production-intended Vault B graph
/// (the exact constructor pack in docs/audit/vault-b-production-wiring.md) wired to the
/// REAL PancakeV3SwapAdapter + real PancakeV3MasterchefVenue, and asserts the prod path
/// CANNOT fall back to a mock swapper / mock venue / `DepositPathUnsupported` stub:
///   - all three swap roles (swapper / swapperIn / rewardSwapper) ARE the one
///     PancakeV3SwapAdapter (not PancakeSwapV3RouterAdapter);
///   - adapter is bound to the real V3 SwapRouter with pairFee 100 / CAKE fee 500;
///   - all three legs (USDT->WBNB, WBNB->USDT, CAKE->USDT) actually clear via that adapter
///     against the live router;
///   - performance fee is 2000 bps;
///   - the NAV quoter is the real `ExcludeIdlePairedQuoter` (v1: idle WBNB → 0), not a mock.
/// NO mock swapper / mock venue / mock quoter / stub is on the graph. Vault A / Beefy
/// untouched.
contract VaultBProductionWiringTest is Test {
    // production-intended BSC config (see docs/audit/vault-b-production-wiring.md)
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    uint24 constant PAIR_FEE = 100;
    uint24 constant CAKE_FEE = 500;
    uint16 constant PERF_FEE_BPS = 2000;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeRecipient = makeAddr("feeRecipient");
    address vaultB = makeAddr("DeepYieldVault_B");
    address caller = makeAddr("caller");

    DedicatedVaultMain main;
    DedicatedVaultStrategyAdapter strat;
    PancakeV3MasterchefVenue venue;
    PancakeV3SwapAdapter adapter;
    bool forkAvailable;

    function setUp() public {
        try this._fork() {} catch { forkAvailable = false; emit log("VaultBProductionWiring: no BSC fork - skip"); return; }
        forkAvailable = NFPM.code.length > 0 && SWAP_ROUTER.code.length > 0 && MASTERCHEF.code.length > 0;
        if (!forkAvailable) return;
        _buildProdGraph();
    }
    function _fork() external {
        require(msg.sender == address(this), "internal");
        string memory rpc = vm.envOr("BSC_FORK_RPC", vm.rpcUrl("bsc"));
        uint256 pin = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pin);
    }
    modifier whenFork() { if (!forkAvailable) { emit log("skip: no fork"); return; } _; }

    /// @dev The production constructor pack. ONE PancakeV3SwapAdapter fills all three
    /// swap roles; the venue is the real Masterchef venue; no stub/mock on the money path.
    function _buildProdGraph() internal {
        uint256 base = vm.getNonce(address(this));
        address predictedMain = vm.computeCreateAddress(address(this), base + 3);
        address predictedStrat = vm.computeCreateAddress(address(this), base + 4);

        ExcludeIdlePairedQuoter quoter = new ExcludeIdlePairedQuoter();        // base+0 (v1 conservative NAV quoter: idle WBNB excluded)
        adapter = new PancakeV3SwapAdapter(                                    // base+1
            IERC20(USDT), IERC20(WBNB), IERC20(CAKE), ISmartRouterV3(SWAP_ROUTER), PAIR_FEE, CAKE_FEE
        );
        venue = new PancakeV3MasterchefVenue(                                  // base+2
            predictedMain, IERC20(USDT), IERC20(WBNB), PAIR_FEE,
            IV3PoolVenue(POOL), INfpmVenue(NFPM), IMasterchefVenue(MASTERCHEF), IERC20(CAKE)
        );
        main = new DedicatedVaultMain(                                         // base+3
            IERC20(USDT), IERC20(WBNB), predictedStrat, venue, quoter,
            adapter, adapter, IERC20(CAKE), adapter, 6 hours, admin, keeper, guardian
        );
        strat = new DedicatedVaultStrategyAdapter(                            // base+4
            IERC20(USDT), vaultB, main, admin, manager, guardian, feeRecipient, PERF_FEE_BPS
        );
        require(address(main) == predictedMain && address(strat) == predictedStrat, "prediction");
    }

    function test_AllSwapRolesAreThePancakeV3SwapAdapter() public whenFork {
        assertEq(address(main.swapperIn()), address(adapter), "swap-in is PancakeV3SwapAdapter");
        assertEq(address(main.swapper()), address(adapter), "WBNB->USDT is PancakeV3SwapAdapter");
        assertEq(address(main.rewardSwapper()), address(adapter), "CAKE->USDT is PancakeV3SwapAdapter");
    }

    function test_AdapterBoundToRealRouterAndFees() public whenFork {
        assertEq(address(adapter.router()), SWAP_ROUTER, "real V3 SwapRouter");
        assertEq(adapter.pairFee(), PAIR_FEE, "pair fee 100");
        assertEq(adapter.rewardFee(), CAKE_FEE, "CAKE fee 500");
        assertEq(address(adapter.asset()), USDT, "asset USDT");
        assertEq(address(adapter.paired()), WBNB, "paired WBNB");
        assertEq(address(adapter.reward()), CAKE, "reward CAKE");
    }

    function test_VenueIsRealFarmedAndConfig() public whenFork {
        assertEq(venue.controller(), address(main), "venue controller == Main");
        assertEq(venue.fee(), PAIR_FEE, "venue fee 100");
        assertTrue(venue.farmed(), "venue farmed (Masterchef)");
        assertEq(address(venue.masterchef()), MASTERCHEF, "real MasterchefV3");
        assertEq(address(venue.nfpm()), NFPM, "real NFPM");
    }

    function test_PerformanceFeeConfigured() public whenFork {
        assertEq(strat.performanceFeeBps(), PERF_FEE_BPS, "20% perf fee");
        assertEq(strat.feeRecipient(), feeRecipient, "fee recipient set");
        assertEq(address(strat.main()), address(main), "strat -> Main");
        assertEq(strat.vault(), vaultB, "strat vault == DeepYieldVault_B");
    }

    /// @notice NAV quoter is the real production v1 quoter (not a mock) and is provably
    /// conservative: idle WBNB values to zero (never overstates user-facing NAV).
    function test_QuoterIsRealProductionConservativeQuoter() public whenFork {
        assertEq(main.quoter().quotePairedToAsset(1e18), 0, "idle WBNB excluded from NAV (conservative v1)");
        assertEq(main.quoter().quotePairedToAsset(1_000_000e18), 0, "any amount -> 0");
    }

    /// @notice All three production swap legs clear through the wired adapter against the
    /// live router — proving the money path is the real adapter, never DepositPathUnsupported.
    function test_AllThreeLegsClearViaWiredAdapter() public whenFork {
        PancakeV3SwapAdapter a = adapter;
        // USDT -> WBNB (swap-in)
        deal(USDT, caller, 1000e18);
        vm.startPrank(caller);
        IERC20(USDT).approve(address(a), 1000e18);
        uint256 wbnbOut = a.swapAssetToPaired(1000e18, 0.5e18, block.timestamp);
        // WBNB -> USDT (close realization)
        deal(WBNB, caller, 1e18);
        IERC20(WBNB).approve(address(a), 1e18);
        uint256 usdtOut = a.swapPairedToAsset(1e18, 100e18, block.timestamp);
        // CAKE -> USDT (reward realization)
        deal(CAKE, caller, 100e18);
        IERC20(CAKE).approve(address(a), 100e18);
        uint256 cakeUsdtOut = a.swapRewardToAsset(100e18, 50e18, block.timestamp);
        vm.stopPrank();
        assertGt(wbnbOut, 0, "USDT->WBNB cleared");
        assertGt(usdtOut, 100e18, "WBNB->USDT cleared");
        assertGt(cakeUsdtOut, 50e18, "CAKE->USDT cleared");
    }
}
