// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ForkBlock} from "./ForkBlock.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DedicatedVaultMain} from "../src/DedicatedVaultMain.sol";
import {DedicatedVaultStrategyAdapter} from "../src/DedicatedVaultStrategyAdapter.sol";
import {PancakeV3MasterchefVenue, INfpmVenue, IMasterchefVenue, IV3PoolVenue} from "../src/PancakeV3MasterchefVenue.sol";
import {PancakeV3SwapAdapter, ISmartRouterV3} from "../src/PancakeV3SwapAdapter.sol";
import {MockAssetQuoter} from "./mocks/MockDedicatedVenue.sol";

interface IPoolTS {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint32, bool);
    function tickSpacing() external view returns (int24);
}

/// @notice FULL WIRED Vault B lifecycle on a live BSC fork: the real
/// DedicatedVaultMain + PancakeV3MasterchefVenue + PancakeV3SwapAdapter driving the
/// real NFPM / MasterchefV3 (pid 137) / USDT-WBNB 0.01% pool / V3 SwapRouter.
/// Proves: deploy → open (bounded pre-swap + two-sided in-range mint + STAKE) →
/// active NAV → harvest → closeAndRealize (unstake → WBNB→USDT + CAKE→USDT, non-zero
/// mins) → redeem-ready idle USDT → withdrawToVault. Head fork, deal-funded.
contract VaultBWiredLifecycleForkTest is Test {
    address constant POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant MASTERCHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    uint24 constant FEE = 100;
    uint24 constant CAKE_FEE = 500; // configured near-optimal static tier (see VaultBSwapAdapterFork)

    address erc4626vault = makeAddr("erc4626vault");
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address manager = makeAddr("manager");
    address feeRecipient = makeAddr("feeRecipient");

    DedicatedVaultMain main;
    DedicatedVaultStrategyAdapter strat;
    PancakeV3MasterchefVenue venue;
    PancakeV3SwapAdapter adapter;
    bool forkAvailable;

    function setUp() public {
        if (!ForkBlock.selectBscFork(vm)) return;
        forkAvailable = NFPM.code.length > 0 && MASTERCHEF.code.length > 0 && SWAP_ROUTER.code.length > 0;
        if (!forkAvailable) return;

        // predict Main + strategy-adapter addresses (venue needs controller==Main;
        // Main needs vault==strategyAdapter). Deploy order below is fixed (no other
        // contract creations interleaved) so nonces are base..base+4.
        uint256 base = vm.getNonce(address(this));
        address predictedMain = vm.computeCreateAddress(address(this), base + 3);
        address predictedStrat = vm.computeCreateAddress(address(this), base + 4);

        MockAssetQuoter quoter = new MockAssetQuoter(590e18);                       // base+0
        adapter = new PancakeV3SwapAdapter(                                          // base+1
            IERC20(USDT), IERC20(WBNB), IERC20(CAKE), ISmartRouterV3(SWAP_ROUTER), FEE, CAKE_FEE
        );
        venue = new PancakeV3MasterchefVenue(                                        // base+2
            predictedMain, IERC20(USDT), IERC20(WBNB), FEE,
            IV3PoolVenue(POOL), INfpmVenue(NFPM), IMasterchefVenue(MASTERCHEF), IERC20(CAKE)
        );
        main = new DedicatedVaultMain(                                               // base+3
            IERC20(USDT), IERC20(WBNB), predictedStrat, venue, quoter,
            adapter, adapter, IERC20(CAKE), adapter, 6 hours, admin, keeper, guardian
        );
        strat = new DedicatedVaultStrategyAdapter(                                   // base+4
            IERC20(USDT), erc4626vault, main, admin, manager, guardian, feeRecipient, 2000
        );
        assertEq(address(main), predictedMain, "main address prediction");
        assertEq(address(strat), predictedStrat, "strat address prediction");

        bytes32 gr = main.GUARDIAN_ROLE();
        vm.prank(admin); main.grantRole(gr, address(strat));
    }
    modifier whenFork() { if (!forkAvailable) { emit log("skip: no fork"); return; } _; }

    function test_FullWiredLifecycle() public whenFork {
        // 1) fund Main with 1000 USDT via the strategy adapter (ERC-4626 path)
        uint256 funded = 1000e18;
        deal(USDT, erc4626vault, funded);
        vm.prank(erc4626vault); IERC20(USDT).approve(address(strat), funded);
        vm.prank(manager); strat.deploy(funded);
        assertEq(main.idleAsset(), funded, "Main funded");
        assertEq(main.totalAssetsUsdt(), funded, "NAV == funded idle");

        // 2) open: pre-swap ~half USDT->WBNB, two-sided in-range mint + stake.
        (, int24 tick, , , , , ) = IPoolTS(POOL).slot0();
        int24 sp = IPoolTS(POOL).tickSpacing();
        int24 tl = (tick / sp) * sp - 70 * sp;
        int24 tu = (tick / sp) * sp + 70 * sp;
        vm.prank(keeper);
        main.openPosition(DedicatedVaultMain.OpenParams({
            tickLower: tl, tickUpper: tu,
            swapAssetIn: 500e18, pairedMinOut: 0.3e18,   // 500 USDT -> >=0.3 WBNB (real router)
            amount0Min: 1e18, amount1Min: 1e15,          // non-zero bounds, below expected consumption
            deadline: block.timestamp
        }));
        assertTrue(main.hasActivePosition(), "position opened + staked");
        assertGt(main.positionValue(), 0, "on-chain NAV of staked position > 0");
        // NAV after open: position + leftover idle (returned by venue) + quoted dust.
        // Conservative valuer + swap/LP costs → within a tolerance band of funded.
        uint256 navOpen = main.totalAssetsUsdt();
        emit log_named_uint("NAV after open", navOpen);
        assertGt(navOpen, funded * 90 / 100, "NAV after open within 10% of funded (costs/conservative)");
        assertLe(navOpen, funded + 1e18, "NAV not overstated");

        // staked NFT lives in MasterchefV3
        assertEq(IERC721Bal(MASTERCHEF).balanceOf(address(venue)), 1, "venue NFT staked in masterchef");

        // 3) harvest (fees ~0 right after open; must not revert, proceeds stay in Main)
        vm.prank(keeper); main.harvest();

        // 4) close-and-realize with NON-ZERO mins. Seed CAKE to Main to exercise the
        // wired CAKE->USDT reward leg too (simulates swept/harvested CAKE).
        deal(CAKE, address(main), 10e18);
        vm.prank(keeper);
        main.closePositionAndRealize(
            1, 1, block.timestamp,        // close mins (decreaseLiquidity) — non-zero
            300e18,                       // pairedMinOut: WBNB->USDT floor
            10e18,                        // rewardMinOut: 10 CAKE -> >=10 USDT (fee 500)
            block.timestamp
        );
        assertFalse(main.hasActivePosition(), "closed");
        assertEq(IERC20(WBNB).balanceOf(address(main)), 0, "WBNB fully realized to USDT");
        assertEq(IERC20(CAKE).balanceOf(address(main)), 0, "CAKE fully realized to USDT");
        uint256 idleUsdt = main.idleAsset();
        emit log_named_uint("redeem-ready idle USDT", idleUsdt);
        assertGt(idleUsdt, funded * 90 / 100, "idle USDT redeem-ready (~funded minus swap/LP costs)");

        // 5) crystallize the 20% performance fee on realized profit, then withdraw the
        // remaining (net) idle USDT to the ERC-4626 vault. idle 1013 > basis 1000 → fee on ~13.
        vm.prank(manager);
        (uint256 profit, uint256 fee) = strat.harvest();
        emit log_named_uint("realized profit", profit);
        emit log_named_uint("perf fee (20%)", fee);
        assertGt(fee, 0, "perf fee crystallized to recipient");
        assertEq(IERC20(USDT).balanceOf(feeRecipient), fee, "fee to recipient only");
        uint256 redeemable = main.idleAsset(); // net of fee
        vm.prank(erc4626vault);
        uint256 got = strat.withdrawToVault(redeemable);
        assertEq(got, redeemable, "withdraw satisfiable in USDT");
        assertEq(IERC20(USDT).balanceOf(erc4626vault), redeemable, "net USDT delivered to vault");
        assertEq(main.idleAsset(), 0, "Main drained");
    }
}

interface IERC721Bal { function balanceOf(address) external view returns (uint256); }
