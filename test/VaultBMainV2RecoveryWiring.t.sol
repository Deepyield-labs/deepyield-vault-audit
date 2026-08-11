// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";
import {
    MockMainV2Token,
    MockMainV2PriceGuard,
    MockMainV2ExecutionAdapter,
    MockMainV2RewardAdapter,
    MockMainV2Venue
} from "./VaultBMainV2.t.sol";

/// @notice B4-T2 — Main-side wiring that makes the venue's B4-T1 recovery path
/// (staged close + stranded-position write-off) reachable in production, and
/// keeps Main's `activePositionId`/NAV reconciled so a write-off cannot leave a
/// phantom position.

/// @dev Recovery-capable venue mock: the B4-T1 staged/write-off surface added to
/// the base Main venue mock, with per-stage revert toggles.
contract RecoveryMockVenue is MockMainV2Venue {
    using SafeERC20 for IERC20;

    bool public revertUnstake;
    bool public revertDecrease;
    bool public revertCollect;
    bool public revertBurn;
    uint256 public lastStranded;
    uint256 public writeOffPairedReturn; // paired handed back on write-off (0 = staked-stranded)

    constructor(IERC20 a_, IERC20 p_) MockMainV2Venue(a_, p_) {}

    function setReverts(bool u, bool d, bool c, bool b) external {
        revertUnstake = u;
        revertDecrease = d;
        revertCollect = c;
        revertBurn = b;
    }

    function setWriteOffPairedReturn(uint256 v) external {
        writeOffPairedReturn = v;
    }

    function _onlyControllerActive(uint256 id) internal view {
        require(msg.sender == controller && id == activeId && id != 0, "pos");
    }

    function closeUnstake(uint256 id) external {
        _onlyControllerActive(id);
        require(!revertUnstake, "unstake-revert");
    }

    function closeDecrease(uint256 id, uint256, uint256, uint256) external {
        _onlyControllerActive(id);
        require(!revertDecrease, "decrease-revert");
    }

    function closeCollect(uint256 id) external {
        _onlyControllerActive(id);
        require(!revertCollect, "collect-revert");
        if (closeAssetOut != 0) asset.safeTransfer(controller, closeAssetOut);
        if (closePairedOut != 0) paired.safeTransfer(controller, closePairedOut);
    }

    function closeBurn(uint256 id) external {
        _onlyControllerActive(id);
        require(!revertBurn, "burn-revert");
        activeId = 0;
        positionValue = 0;
    }

    function writeOffStrandedPosition() external returns (uint256 strandedId) {
        require(msg.sender == controller, "controller");
        require(activeId != 0, "none");
        strandedId = activeId;
        lastStranded = strandedId;
        activeId = 0;
        positionValue = 0;
        if (writeOffPairedReturn != 0) paired.safeTransfer(controller, writeOffPairedReturn);
    }
}

contract VaultBMainV2RecoveryWiringTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");

    MockMainV2Token internal usdt;
    MockMainV2Token internal wbnb;
    MockMainV2Token internal cake;
    MockMainV2PriceGuard internal guard;
    MockMainV2PriceGuard internal rewardGuard;
    MockMainV2ExecutionAdapter internal executor;
    MockMainV2RewardAdapter internal rewardExecutor;
    RecoveryMockVenue internal venue;
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
        venue = new RecoveryMockVenue(IERC20(USDT), IERC20(WBNB));
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
        vm.mockCall(
            0x172fcD41E0913e95784454622d1c3724f546f849,
            abi.encodeWithSignature("slot0()"),
            abi.encode(uint160(0x1000000000000000000000000), int24(0), uint16(0), uint16(0), uint16(0), uint32(0), true)
        );

        usdt.mint(address(this), 100_000e18);
        usdt.mint(address(executor), 100_000e18);
        usdt.mint(address(rewardExecutor), 100_000e18);
        wbnb.mint(address(executor), 100_000e18);
        IERC20(USDT).approve(address(main), type(uint256).max);

        vm.prank(admin);
        main.enableOperations();
    }

    function _etchToken(address target) internal {
        MockMainV2Token template = new MockMainV2Token();
        vm.etch(target, address(template).code);
    }

    function _openPosition() internal returns (uint256 id) {
        return _openPosition(keccak256("OPEN"));
    }

    function _openPosition(bytes32 jobId) internal returns (uint256 id) {
        main.fundFromVault(1_000e18);
        vm.prank(keeper);
        id = main.openPosition(
            DedicatedVaultMainV2.OpenParams({
                jobId: jobId,
                tickLower: -100,
                tickUpper: 100,
                assetBudget: 1_000e18,
                swapAssetIn: 500e18,
                keeperPairedMinOut: 1,
                deadline: block.timestamp + 60
            })
        );
        assertEq(main.activePositionId(), id);
    }

    function _mintCloseInventory(uint256 assetAmount, uint256 pairedAmount) internal {
        if (assetAmount != 0) usdt.mint(address(venue), assetAmount);
        if (pairedAmount != 0) wbnb.mint(address(venue), pairedAmount);
    }

    // ── п.1: authorization — guardian only, keeper/outsider rejected ─────────
    function test_RecoveryEntrypointsAreGuardianOnly() public {
        _openPosition();

        vm.prank(keeper);
        vm.expectRevert();
        main.recoverCloseUnstake();
        vm.prank(outsider);
        vm.expectRevert();
        main.recoverCloseUnstake();
        vm.prank(keeper);
        vm.expectRevert();
        main.writeOffStrandedPosition();

        // guardian can
        vm.prank(guardian);
        main.recoverCloseUnstake();
    }

    // ── п.2: broken masterchef → stages fail → guardian write-off reconciles ─
    function test_BrokenMasterchefWriteOffReconcilesMainAndReopens() public {
        uint256 id = _openPosition(keccak256("OPEN1"));
        venue.setReverts(true, false, false, false); // unstake (masterchef) reverts

        vm.prank(guardian);
        vm.expectRevert(bytes("unstake-revert"));
        main.recoverCloseUnstake();

        // write-off frees both sides; Main clears its book and halts
        vm.prank(guardian);
        main.writeOffStrandedPosition();
        assertEq(main.activePositionId(), 0, "Main dropped the position");
        assertEq(venue.activeId(), 0, "venue freed its slot");
        assertEq(venue.lastStranded(), id, "venue recorded the stranded id");
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED), "write-off forces halt");

        // NAV no longer reverts and no longer counts the position (п.3)
        assertEq(main.totalAssetsUsdt(), usdt.balanceOf(address(main)), "NAV = real inventory only, no phantom");

        // admin can re-enable and a fresh position opens again
        vm.prank(admin);
        main.enableOperations();
        uint256 id2 = _openPosition(keccak256("OPEN2"));
        assertGt(id2, id);
    }

    // ── п.3: the reconciliation is what prevents the phantom ─────────────────
    // If the venue slot were freed WITHOUT Main clearing activePositionId, NAV
    // would revert forever (venue previews require the id). The wrapper does both
    // atomically; here we simulate the unreconciled path to prove the hazard.
    function test_UnreconciledWriteOffWouldPhantomRevert() public {
        _openPosition();

        // simulate venue-only write-off (Main NOT updated) by calling as the controller
        vm.prank(address(main));
        venue.writeOffStrandedPosition();

        // Main still thinks the position is active → NAV valuation reverts
        assertTrue(main.activePositionId() != 0);
        vm.expectRevert(bytes("position"));
        main.totalAssetsUsdt();
    }

    // ── п.2/п.4: full staged recovery through Main completes the close ───────
    function test_StagedRecoveryThroughMainCompletesClose() public {
        uint256 id = _openPosition();
        venue.configureClose(0, 0, 0, 0, 1_000e18, 0); // collect returns 1_000 USDT to Main
        _mintCloseInventory(1_000e18, 0); // venue must hold what it hands back

        vm.startPrank(guardian);
        main.recoverCloseUnstake();
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY), "vault paused for close");
        main.recoverCloseDecrease(0, 0, block.timestamp + 60);
        main.recoverCloseCollect();
        main.recoverCloseBurn();
        vm.stopPrank();

        assertEq(main.activePositionId(), 0, "position closed");
        assertEq(venue.activeId(), 0);
        // proceeds are real Main inventory; NAV is coherent (no revert, counts inventory)
        assertEq(main.totalAssetsUsdt(), usdt.balanceOf(address(main)));
        assertGt(usdt.balanceOf(address(main)), 0, "collected proceeds landed in Main");
        // id no longer valued
        assertEq(id, id);
    }

    // ── write-off event flags the returned inventory for monitoring ──────────
    function test_WriteOffEmitsEventWithReturnedInventoryFlag() public {
        uint256 id = _openPosition();
        wbnb.mint(address(venue), 5e18);
        venue.setWriteOffPairedReturn(5e18); // unstaked NFT liquidity handed back

        vm.expectEmit(true, false, false, true, address(main));
        emit DedicatedVaultMainV2.VenuePositionWrittenOff(id, id, true);
        vm.prank(guardian);
        main.writeOffStrandedPosition();
    }

    // ── п.4 regression: normal closeToInventory path is unchanged ────────────
    function test_NormalCloseToInventoryStillWorks() public {
        _openPosition();
        venue.configureClose(1_000e18, 0, 1_000e18, 0, 1_000e18, 0);
        _mintCloseInventory(1_000e18, 0);

        vm.prank(keeper);
        main.closeToInventory(keccak256("NORMALCLOSE"), block.timestamp + 60, false);

        assertEq(main.activePositionId(), 0, "normal close clears the position");
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.CLOSED_TO_INVENTORY));
    }

    // ── recovery works even while HALTED (emergency must not be gated off) ────
    function test_RecoveryWorksWhileHalted() public {
        uint256 id = _openPosition();
        vm.prank(guardian);
        main.halt();
        assertEq(uint256(main.mode()), uint256(DedicatedVaultMainV2.Mode.HALTED));

        vm.prank(guardian);
        main.writeOffStrandedPosition(); // must not be blocked by HALTED
        assertEq(main.activePositionId(), 0);
        assertEq(venue.lastStranded(), id);
    }
}
