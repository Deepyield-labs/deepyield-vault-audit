// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DeepYieldVaultB} from "../src/DeepYieldVaultB.sol";
import {IVaultBAsyncStrategy} from "../src/interfaces/IVaultBAsyncStrategy.sol";

contract QLToken is ERC20 {
    constructor() ERC20("USD Test", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Healthy strategy mock for B11-T4. It mirrors the two Main behaviours the
/// vault relies on here: `requestWithdrawal` reverts on a DUPLICATE requestId (so an
/// aggregation top-up must NOT re-register the handle), and the commit flag clears once
/// the last queued withdrawal is claimed/cancelled. Everything the vault deposits stays
/// idle in the vault, so claims settle from idle (`needed == 0`).
contract QLStrategy is IVaultBAsyncStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    address public immutable override vault;
    bool public committed;
    uint256 public pendingCount;
    mapping(bytes32 => bool) public seen;

    error DuplicateHandle();
    error UnknownHandle();

    constructor(IERC20 a, address v) {
        asset = a;
        vault = v;
    }

    function depositAssetSource() external view returns (address) {
        return address(this);
    }

    function deploy(uint256) external {}

    function withdrawToVault(uint256) external pure returns (uint256) {
        return 0;
    }

    function managerWithdrawAll() external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (uint256, uint256) {
        return (0, 0);
    }
    function panic() external {}

    function estimatedTotalAssets() external pure returns (uint256) {
        return 0;
    }

    function estimatedTotalAssetsUpper() external pure returns (uint256) {
        return 0;
    }

    function requestWithdrawal(bytes32 id, uint256) external {
        if (seen[id]) revert DuplicateHandle(); // Main: WithdrawalExists
        seen[id] = true;
        pendingCount += 1;
    }

    function commitWithdrawalCycle() external {
        committed = true;
    }

    function claimWithdrawal(bytes32 id, uint256 needed) external returns (uint256) {
        if (!seen[id]) revert UnknownHandle();
        seen[id] = false;
        pendingCount -= 1;
        if (pendingCount == 0) committed = false;
        if (needed != 0) asset.safeTransfer(vault, needed);
        return needed;
    }

    function cancelWithdrawal(bytes32 id) external {
        if (!seen[id]) return;
        seen[id] = false;
        pendingCount -= 1;
        if (pendingCount == 0) committed = false;
    }

    function withdrawalReady(bytes32) external pure returns (bool) {
        return true;
    }

    function withdrawalCycleCommitted() external view returns (bool) {
        return committed;
    }

    function withdrawalCycleBatchCommitted() external view returns (bool) {
        return committed;
    }

    function withdrawalCycleExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function withdrawalCycleChargeableExecutionLoss() external pure returns (uint256) {
        return 0;
    }

    function availableWithdrawLimit() external pure returns (uint256) {
        return type(uint256).max;
    }

    function depositsAllowed() external pure returns (bool) {
        return true;
    }
}

    contract VaultBQueueLivenessTest is Test {
        QLToken internal token;
        DeepYieldVaultB internal vault;
        QLStrategy internal strat;

        address internal admin = makeAddr("admin");
        address internal guardian = makeAddr("guardian");
        address internal treasury = makeAddr("treasury");
        address internal whale = makeAddr("whale");
        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");
        address internal carol = makeAddr("carol");
        address internal dave = makeAddr("dave");

        uint256 internal min;

        function setUp() public {
            token = new QLToken();
            vault = new DeepYieldVaultB(IERC20(address(token)), "DeepYield B", "dyB", admin, guardian, treasury, 0);
            strat = new QLStrategy(IERC20(address(token)), address(vault));
            vm.prank(admin);
            vault.setStrategy(address(strat)); // pristine vault → immediate (B11-T2)
            min = vault.MIN_REDEEM_SHARES();
        }

        function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
            token.mint(who, assets);
            vm.startPrank(who);
            token.approve(address(vault), assets);
            shares = vault.deposit(assets, who);
            vm.stopPrank();
        }

        function _key(address owner, address receiver) internal pure returns (bytes32) {
            return keccak256(abi.encode(owner, receiver));
        }

        function _reqShares(uint256 requestId) internal view returns (uint256) {
            (,, uint128 shares,,,) = vault.redeemRequests(requestId);
            return shares;
        }

        // ── (1) full queue is a second commit trigger; honest exits without admin. ──
        function test_FullQueueCommitsAndHonestExits() public {
            vm.prank(admin);
            vault.setMaxPendingRedeems(3); // small cap = readable "full queue"
            _deposit(whale, 100 ether); // huge supply so dust never reaches the 5% threshold
            address[3] memory sybils = [makeAddr("s0"), makeAddr("s1"), alice];

            // First two dust requests: queue not full AND below 5% → commit must revert.
            for (uint256 i = 0; i < 2; i++) {
                _deposit(sybils[i], 1 ether);
                vm.prank(sybils[i]);
                vault.requestRedeem(min, sybils[i], sybils[i]);
            }
            vm.expectRevert(); // RedeemCycleNotReady — dust < 5%, queue not full: the DoS state
            vault.commitRedeemCycle();

            // The third fills the queue → the cycle commits on FILL, not on the threshold.
            _deposit(sybils[2], 1 ether);
            vm.prank(sybils[2]);
            uint256 honestId = vault.requestRedeem(min, sybils[2], sybils[2]);
            assertEq(vault.outstandingRedeemCount(), 3, "queue full");
            assertTrue(vault.redeemCycleCommitted(), "final request commits atomically");

            // The honest filler exits with no admin action.
            uint256 before = token.balanceOf(alice);
            vm.prank(alice);
            uint256 got = vault.claimRedeem(honestId);
            assertGt(got, 0, "honest exits");
            assertEq(token.balanceOf(alice) - before, got, "honest paid");
        }

        // ── (2) a filler cannot free-cancel after the fill commits; shares are burned. ──
        function test_FillerActuallyExitsNotFreeCancel() public {
            vm.prank(admin);
            vault.setMaxPendingRedeems(2);
            _deposit(whale, 100 ether);
            _deposit(alice, 1 ether);
            _deposit(bob, 1 ether);
            vm.prank(alice);
            uint256 aId = vault.requestRedeem(min, alice, alice);
            vm.prank(bob);
            vault.requestRedeem(min, bob, bob); // fills the queue
            assertTrue(vault.redeemCycleCommitted(), "full queue already committed on return");

            // Cancel is barred once committed — no free unwind.
            vm.prank(alice);
            vm.expectRevert(DeepYieldVaultB.RedeemCycleLocked.selector);
            vault.cancelRedeem(aId);

            uint256 supplyBefore = vault.totalSupply();
            vm.prank(alice);
            vault.claimRedeem(aId); // shares burn at the cycle price
            assertEq(vault.totalSupply(), supplyBefore - min, "filler's shares burned, not returned");
        }

        function test_HardCeilingCommitsOnFinalRequest() public {
            uint256 ceiling = vault.MAX_PENDING_REDEEMS_CEILING();
            vm.prank(admin);
            vault.setMaxPendingRedeems(ceiling);
            _deposit(whale, 6_000 ether);

            for (uint256 i; i < ceiling; ++i) {
                address user = address(uint160(0x1000 + i));
                _deposit(user, 1 ether);
                vm.prank(user);
                vault.requestRedeem(min, user, user);
            }

            assertEq(vault.outstandingRedeemCount(), ceiling);
            assertTrue(vault.redeemCycleCommitted(), "hard ceiling is committed before the final request returns");
        }

        // ── (3) the 5% threshold still commits when the queue is NOT full. ──
        function test_ThresholdStillCommitsWhenNotFull() public {
            uint256 shares = _deposit(whale, 100 ether); // sole holder
            uint256 fivePct = Math.mulDiv(shares, 500, 10_000, Math.Rounding.Ceil);
            vm.prank(whale);
            uint256 id = vault.requestRedeem(fivePct + min, whale, whale); // one request over 5%
            assertLt(vault.outstandingRedeemCount(), vault.maxPendingRedeems(), "queue not full");
            vault.commitRedeemCycle(); // commits on the threshold, as before
            assertTrue(vault.redeemCycleCommitted(), "threshold path intact");
            vm.prank(whale);
            assertGt(vault.claimRedeem(id), 0);
        }

        // ── (4) finding-8: a deposit before commit does NOT move the threshold base. ──
        function test_FindingEightBaseSnapshotUnmoved() public {
            _deposit(whale, 100 ether);
            vm.prank(whale);
            vault.requestRedeem(min, whale, whale); // opens the queue → base snapshot frozen
            uint256 thresholdBefore = vault.commitThresholdShares();
            _deposit(bob, 100 ether); // supply doubles AFTER queue-open
            assertEq(vault.commitThresholdShares(), thresholdBefore, "threshold base frozen at queue-open");
        }

        // ── (5) aggregation: same (owner,receiver) = one slot summed; diff receiver = new slot. ──
        function test_AggregationSlotMath() public {
            _deposit(alice, 3 ether); // 3 * min shares
            vm.startPrank(alice); // requestRedeem(shares, receiver, owner)
            uint256 toBob = vault.requestRedeem(min, bob, alice);
            uint256 again = vault.requestRedeem(min, bob, alice); // same pair → aggregates
            uint256 toCarol = vault.requestRedeem(min, carol, alice); // diff receiver → new slot
            vm.stopPrank();

            assertEq(again, toBob, "same pair reuses slot id");
            assertEq(vault.outstandingRedeemCount(), 2, "two slots: (alice,bob) and (alice,carol)");
            assertEq(_reqShares(toBob), 2 * min, "bob-slot shares summed");
            assertEq(_reqShares(toCarol), min, "carol-slot separate");
            assertEq(vault.pendingRedeemKeyPlusOne(_key(alice, bob)), toBob + 1);
            assertEq(vault.pendingRedeemKeyPlusOne(_key(alice, carol)), toCarol + 1);
        }

        // ── (6) cancelling an aggregated position returns the WHOLE accumulated share. ──
        function test_CancelAggregatedReturnsFull() public {
            uint256 shares = _deposit(alice, 2 ether); // 2 * min
            vm.startPrank(alice); // requestRedeem(shares, receiver, owner)
            uint256 id = vault.requestRedeem(min, bob, alice);
            vault.requestRedeem(min, bob, alice); // aggregate → slot holds 2*min
            vm.stopPrank();
            assertEq(vault.balanceOf(alice), shares - 2 * min, "both escrowed");

            vm.prank(alice);
            vault.cancelRedeem(id);
            assertEq(vault.balanceOf(alice), shares, "full accumulated position returned");
            assertEq(vault.pendingRedeemKeyPlusOne(_key(alice, bob)), 0, "slot cleared");
            assertEq(vault.outstandingRedeemCount(), 0);
        }

        // ── (7) updateRedeemReceiver moves the slot key and refuses a collision. ──
        function test_UpdateReceiverMovesKeyAndRefusesCollision() public {
            _deposit(alice, 2 ether);
            vm.startPrank(alice); // requestRedeem(shares, receiver, owner)
            uint256 toBob = vault.requestRedeem(min, bob, alice);
            vault.requestRedeem(min, carol, alice); // alice already holds an (alice,carol) slot
            // Moving the bob-slot onto carol would merge two live slots → refused.
            vm.expectRevert(abi.encodeWithSelector(DeepYieldVaultB.PendingRequestExists.selector, toBob + 1));
            vault.updateRedeemReceiver(toBob, carol);
            // Moving to a free receiver relocates the key cleanly.
            vault.updateRedeemReceiver(toBob, dave);
            vm.stopPrank();
            assertEq(vault.pendingRedeemKeyPlusOne(_key(alice, bob)), 0, "old key freed");
            assertEq(vault.pendingRedeemKeyPlusOne(_key(alice, dave)), toBob + 1, "new key set");
        }

        // ── (8) regression: a normal, sub-full, over-threshold cycle is unaffected. ──
        function test_NormalCycleUnaffected() public {
            uint256 shares = _deposit(whale, 100 ether);
            uint256 fivePct = Math.mulDiv(shares, 500, 10_000, Math.Rounding.Ceil);
            vm.prank(whale);
            uint256 id = vault.requestRedeem(fivePct + min, whale, whale);
            vault.commitRedeemCycle();
            vm.prank(whale);
            uint256 got = vault.claimRedeem(id);
            assertGt(got, 0, "normal cycle settles");
            assertFalse(vault.redeemCycleForceSettled(), "no force path");
            assertEq(vault.outstandingRedeemCount(), 0, "cycle cleared");
        }
    }
