// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VaultBMainV2Test} from "./VaultBMainV2.t.sol";
import {DedicatedVaultMainV2} from "../src/DedicatedVaultMainV2.sol";

/// @notice Coverage for B1-T1: a sub-threshold residual paired/reward balance
/// must not freeze the withdrawal path, the residual can be swept (to `vault`
/// only, guardian-only, threshold-bounded), and an oversized residual can be
/// drained over several bounded calls without bypassing the per-day cap.
/// Inherits the existing harness (mocks, roles, helpers) from VaultBMainV2Test.
contract VaultBMainV2WithdrawalDustTest is VaultBMainV2Test {
    bytes32 internal constant REQ = keccak256("dust-req-1");

    function _matureRequest(uint256 fundAmount, uint256 reqAmount) internal {
        _fund(fundAmount);
        main.requestWithdrawal(REQ, reqAmount);
    }

    // 1. Outsider raises the paired balance by 1 wei -> readiness holds, claim settles.
    //    On pre-fix code (strict `!= 0`) this reverts WithdrawalNotReady.
    function testSubThresholdPairedResidualDoesNotFreezeClaim() public {
        _matureRequest(1_000e18, 500e18);
        wbnb.mint(address(main), 1); // arbitrary external donation
        assertTrue(main.isWithdrawalReady());
        uint256 before = usdt.balanceOf(address(this));
        main.claimWithdrawal(REQ, 500e18);
        assertEq(usdt.balanceOf(address(this)) - before, 500e18);
    }

    // 2. Same for the reward token.
    function testSubThresholdRewardResidualDoesNotFreezeClaim() public {
        _matureRequest(1_000e18, 500e18);
        cake.mint(address(main), 1);
        assertTrue(main.isWithdrawalReady());
        uint256 before = usdt.balanceOf(address(this));
        main.claimWithdrawal(REQ, 500e18);
        assertEq(usdt.balanceOf(address(this)) - before, 500e18);
    }

    // 3. A residual just above the threshold must still block: the tolerance
    //    cannot be wide enough to write off a real amount.
    function testResidualAboveToleranceStillBlocks() public {
        _matureRequest(1_000e18, 500e18);
        wbnb.mint(address(main), main.PAIRED_DUST_TOLERANCE() + 1);
        assertFalse(main.isWithdrawalReady());
        vm.expectRevert(DedicatedVaultMainV2.WithdrawalNotReady.selector);
        main.claimWithdrawal(REQ, 500e18);
    }

    // 4. Sweep: guardian-only, recipient is `vault` and nowhere else, and it
    //    reverts above the threshold so it can never route funds past the caps.
    function testDustSweepIsVaultOnlyGuardianOnlyAndThresholdBounded() public {
        uint256 dust = 1e13; // below PAIRED_DUST_TOLERANCE (1e14)
        wbnb.mint(address(main), dust);

        // non-guardian cannot sweep
        vm.prank(outsider);
        vm.expectRevert();
        main.sweepPairedDust();

        // guardian sweeps, funds land at vault (address(this)) and nowhere else
        uint256 vaultBefore = wbnb.balanceOf(address(this));
        vm.prank(guardian);
        uint256 swept = main.sweepPairedDust();
        assertEq(swept, dust);
        assertEq(wbnb.balanceOf(address(this)) - vaultBefore, dust);
        assertEq(wbnb.balanceOf(address(main)), 0);

        // above tolerance the sweep must revert (cannot double as a bypass)
        uint256 tol = main.PAIRED_DUST_TOLERANCE();
        wbnb.mint(address(main), tol + 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(DedicatedVaultMainV2.DustAboveTolerance.selector, tol + 1, tol));
        main.sweepPairedDust();

        // reward-token sweep obeys the same rules
        uint256 rewardTol = main.REWARD_DUST_TOLERANCE();
        cake.mint(address(main), rewardTol); // exactly at tolerance is allowed
        uint256 rewardVaultBefore = cake.balanceOf(address(this));
        vm.prank(guardian);
        main.sweepRewardDust();
        assertEq(cake.balanceOf(address(this)) - rewardVaultBefore, rewardTol);
    }

    // 5. A residual whose notional exceeds the per-job cap is drained to zero
    //    over several bounded calls. On pre-fix code the first (non-final) call
    //    reverts SlicingDisabled.
    function testOversizedPairedResidualDrainsToZeroOverSeveralCalls() public {
        wbnb.mint(address(main), 1_500e18); // notional 1_500 > swapPerJobCap 1_000

        vm.prank(keeper); // job A: bounded to the per-job cap headroom (1_000)
        main.liquidateAllWbnb(keccak256("liq-A"), 0, 0, block.timestamp + 60, false, false);
        assertEq(wbnb.balanceOf(address(main)), 500e18);

        vm.prank(keeper); // job B: drains the remainder, finalChunk asserts <= tolerance
        main.liquidateAllWbnb(keccak256("liq-B"), 0, 0, block.timestamp + 60, true, false);
        assertEq(wbnb.balanceOf(address(main)), 0);
    }

    // 6. A chunk/job series cannot exceed the per-day cap: after the day's limit
    //    is used up, the next bounded call reverts DailySwapCapExceeded.
    function testChunkSeriesCannotBypassDailyCap() public {
        wbnb.mint(address(main), 2_500e18); // notional 2_500 > dailySwapLimit 2_000

        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("day-1"), 0, 0, block.timestamp + 60, false, false); // +1_000, day=1_000
        vm.prank(keeper);
        main.liquidateAllWbnb(keccak256("day-2"), 0, 0, block.timestamp + 60, false, false); // +1_000, day=2_000

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(DedicatedVaultMainV2.DailySwapCapExceeded.selector, 2_500e18, 2_000e18)
        );
        main.liquidateAllWbnb(keccak256("day-3"), 0, 0, block.timestamp + 60, true, false);

        assertEq(wbnb.balanceOf(address(main)), 500e18); // remainder genuinely held by the cap, not lost
    }
}
