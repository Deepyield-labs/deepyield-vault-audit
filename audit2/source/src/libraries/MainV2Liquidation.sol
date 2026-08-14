// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "./FullMath.sol";
import {Job, JobKind, MainV2Jobs} from "./MainV2Jobs.sol";
import {
    IVaultBExecutionAdapterV2,
    IVaultBPriceGuard,
    IVaultBRewardExecutionAdapterV2,
    IVaultBRewardPriceGuard
} from "../interfaces/IVaultBExecutionV2.sol";

/// @notice Parameters for a liquidation chunk. Grouped in a struct to keep the
/// external call under the stack limit.
struct LiqParams {
    bytes32 jobId;
    uint32 chunkIndex;
    uint256 keeperMinOut;
    uint256 deadline;
    bool finalChunk;
    bool emergency;
    uint256 hardMaxActiveAssets;
    uint256 swapPerJobCap;
    uint256 dailySwapLimit;
    uint256 dustTolerance;
}

/// @title MainV2Liquidation
/// @notice Direct-Pancake chunked liquidation of paired-token (WBNB) and
/// reward-token (CAKE) inventory, extracted verbatim from `DedicatedVaultMainV2`
/// so the bodies deploy once and link (EIP-170). A linked library runs via
/// `delegatecall`, so inside these functions `address(this)` is `Main`, token
/// approvals/balances act on `Main`'s inventory, and the passed-in mapping
/// pointers address `Main`'s storage — the code is unchanged, only relocated.
/// `Main` keeps the role/halt gate and finishes with the execution-loss journal
/// and the event. Error signatures match `Main`'s for selector-stable tests.
library MainV2Liquidation {
    using SafeERC20 for IERC20;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    error InvalidAmount();
    error SwapCapExceeded(uint256 requested, uint256 cap);
    error SwapBelowFloor(uint256 floor, uint256 amountOut);
    error InventoryRemaining(uint256 pairedBalance);
    error RewardInventoryRemaining(uint256 rewardBalance);

    function liquidateWbnb(
        mapping(bytes32 => Job) storage jobs,
        mapping(bytes32 => mapping(uint32 => bool)) storage usedChunks,
        mapping(uint64 => uint256) storage dailySwapNotional,
        IERC20 pairedToken,
        IVaultBExecutionAdapterV2 executionAdapter,
        IVaultBPriceGuard priceGuard,
        LiqParams memory p
    ) external returns (uint256 amountOut, uint256 amountIn, uint256 notional) {
        Job storage job = MainV2Jobs.beginChunk(jobs, usedChunks, p.jobId, JobKind.LIQUIDATE_WBNB, p.chunkIndex);

        uint256 balance = pairedToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = p.emergency ? p.hardMaxActiveAssets : p.swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        notional = priceGuard.fairValue(WBNB, USDT, balance);
        amountIn = balance;
        // Slice down to per-job headroom only on a non-final chunk. A final chunk
        // whose notional exceeds the cap still reverts SwapCapExceeded in
        // reserveSwapNotional (single-call cap semantics unchanged); an oversized
        // residual is drained by issuing non-final chunks first.
        if (notional > headroom && !p.finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = priceGuard.fairValue(WBNB, USDT, amountIn);
        }
        MainV2Jobs.reserveSwapNotional(
            dailySwapNotional, job, notional, p.emergency, p.hardMaxActiveAssets, p.swapPerJobCap, p.dailySwapLimit
        );

        // Pin the same guard floor that the adapter will enforce before it
        // consumes emergency notional. Re-quoting after a successful swap can
        // observe an exhausted budget and incorrectly replace the emergency
        // floor with the normal floor.
        uint256 floor = priceGuard.minimumOut(WBNB, USDT, amountIn, p.emergency);
        pairedToken.forceApprove(address(executionAdapter), amountIn);
        amountOut = executionAdapter.swapPairedToAsset(amountIn, p.keeperMinOut, p.deadline, p.emergency);
        pairedToken.forceApprove(address(executionAdapter), 0);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (p.finalChunk) {
            uint256 remaining = pairedToken.balanceOf(address(this));
            if (remaining > p.dustTolerance) revert InventoryRemaining(remaining);
            MainV2Jobs.completeJob(job);
        }

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
    }

    function liquidateReward(
        mapping(bytes32 => Job) storage jobs,
        mapping(bytes32 => mapping(uint32 => bool)) storage usedChunks,
        mapping(uint64 => uint256) storage dailySwapNotional,
        IERC20 rewardToken,
        IVaultBRewardExecutionAdapterV2 rewardExecutionAdapter,
        IVaultBRewardPriceGuard rewardPriceGuard,
        LiqParams memory p
    ) external returns (uint256 amountOut, uint256 amountIn, uint256 notional) {
        Job storage job = MainV2Jobs.beginChunk(jobs, usedChunks, p.jobId, JobKind.LIQUIDATE_REWARD, p.chunkIndex);

        uint256 balance = rewardToken.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();

        uint256 jobCap = p.emergency ? p.hardMaxActiveAssets : p.swapPerJobCap;
        uint256 used = job.cumulativeNotionalAsset;
        uint256 headroom = used >= jobCap ? 0 : jobCap - used;
        notional = rewardPriceGuard.fairValue(balance);
        amountIn = balance;
        if (notional > headroom && !p.finalChunk) {
            if (headroom == 0) revert SwapCapExceeded(notional, jobCap);
            amountIn = FullMath.mulDiv(balance, headroom, notional);
            if (amountIn == 0) revert SwapCapExceeded(notional, jobCap);
            notional = rewardPriceGuard.fairValue(amountIn);
        }
        MainV2Jobs.reserveSwapNotional(
            dailySwapNotional, job, notional, p.emergency, p.hardMaxActiveAssets, p.swapPerJobCap, p.dailySwapLimit
        );

        uint256 floor = rewardPriceGuard.minimumOut(amountIn, p.emergency);
        rewardToken.forceApprove(address(rewardExecutionAdapter), amountIn);
        amountOut = rewardExecutionAdapter.swapRewardToAsset(amountIn, p.keeperMinOut, p.deadline, p.emergency);
        rewardToken.forceApprove(address(rewardExecutionAdapter), 0);
        if (amountOut < floor) revert SwapBelowFloor(floor, amountOut);

        if (p.finalChunk) {
            uint256 remaining = rewardToken.balanceOf(address(this));
            if (remaining > p.dustTolerance) revert RewardInventoryRemaining(remaining);
            MainV2Jobs.completeJob(job);
        }

        job.cumulativeInput += amountIn;
        job.cumulativeOutput += amountOut;
    }
}
