// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "./FullMath.sol";
import {MainV2Geometry} from "./MainV2Geometry.sol";
import {Job, JobKind, JobStatus, MainV2Jobs} from "./MainV2Jobs.sol";
import {IDedicatedVenue, IDedicatedVenueV2} from "../interfaces/IDedicatedVenue.sol";
import {IVaultBExecutionAdapterV2, IVaultBPriceGuard} from "../interfaces/IVaultBExecutionV2.sol";

/// @notice Phase-1 swap-chunk inputs plus the caps Main reads. There is no
/// `finalChunk` flag: the mint (openPosition) is the sole finalizer, and a param
/// that reads like a control but is never enforced is an audit hazard (B8-T1).
struct SwapChunkCall {
    bytes32 jobId;
    uint32 chunkIndex;
    uint256 amountIn;
    uint256 keeperMinOut;
    uint256 deadline;
    uint256 activePositionId;
    uint256 swapBudget; // B11-T1: the reserved position budget (<= canaryOpenCap)
    uint256 swapPerJobCap;
    uint256 dailySwapLimit;
}

/// @notice Phase-2 mint inputs (from OpenParams) plus the Main config it reads.
/// The swap legs are NOT here — B8-T1 splits the swap into openSwapChunk, so
/// `openPosition` only mints from the inventory those chunks accumulated. Main's
/// external OpenParams signature is unchanged; `swapAssetIn`/`keeperPairedMinOut`
/// are simply unused in phase 2.
struct OpenCall {
    bytes32 jobId;
    int24 tickLower;
    int24 tickUpper;
    uint256 assetBudget;
    uint256 deadline;
    uint256 activePositionId;
    uint256 canaryOpenCap;
    int24 minTickWidth;
    int24 maxTickWidth;
    uint16 mintLossBps;
    uint256 pairedDustTolerance;
    uint256 rewardDustTolerance;
}

/// @title MainV2Open
/// @notice openPosition split into a chunkable swap phase (openSwapChunk) and a
/// single-tx mint phase (openPosition), extracted from `DedicatedVaultMainV2`
/// (EIP-170 / B8-T1). A linked library runs via `delegatecall`, so `address(this)`
/// is `Main`: approvals/balances act on `Main`'s inventory and the mapping
/// pointers address `Main`'s storage. `Main` keeps the role/mode gate, sets
/// `activePositionId` and emits. Error signatures match `Main`'s.
///
/// A job's swap chunks accumulate into `Job.cumulativeInput` (USDT spent) and
/// `Job.cumulativeOutput` (WBNB acquired) — reused verbatim, no new field. The
/// mint then verifies the actual paired balance does not exceed what THIS job
/// acquired beyond dust, so a donation or a second concurrent series is caught.
library MainV2Open {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    error AdapterNotBound();
    error PositionActive();
    error InventoryPresent(uint256 pairedBalance);
    error RewardInventoryPresent(uint256 rewardBalance);
    error InvalidAmount();
    error CapitalCapExceeded(uint256 requested, uint256 cap);
    error OpenNotTwoSided();
    error MintValueBelowFloor(uint256 expectedMinimum, uint256 actualValue);
    error InvalidPositionId();
    error JobKindMismatch(JobKind expected, JobKind actual);
    error JobAlreadyCompleted();

    /// @notice Phase 1: swap `amountIn` USDT to WBNB and accumulate it for the
    /// open series `jobId`. Chunkable so a swap leg larger than swapPerJobCap can
    /// be filled over several calls (price recovers between them). The executor
    /// enforces the guard's own minimum, so keeperMinOut is a further keeper-side
    /// bound. Job stays ACTIVE — the mint (openPosition) finalizes it.
    function openSwapChunk(
        mapping(bytes32 => Job) storage jobs,
        mapping(bytes32 => mapping(uint32 => bool)) storage usedChunks,
        mapping(uint64 => uint256) storage dailySwapNotional,
        IVaultBExecutionAdapterV2 executionAdapter,
        IERC20 asset,
        SwapChunkCall memory c
    ) external returns (uint256 pairedOut) {
        if (c.activePositionId != 0) revert PositionActive();
        if (c.amountIn == 0) revert InvalidAmount();
        if (executionAdapter.main() != address(this)) revert AdapterNotBound();

        Job storage job = MainV2Jobs.beginChunk(jobs, usedChunks, c.jobId, JobKind.OPEN, c.chunkIndex);

        // Aggregate series bound, checked AFTER chunk sequencing (beginChunk) but
        // BEFORE the swap moves any USDT: the total swapped across the series (this
        // chunk included) may not exceed the reserved SWAP LEG (B11-T1), which is
        // strictly below the position budget, so the mint leg (budget - swapped) is
        // always positive and the inventory can never be stranded with the mint
        // unreachable. Enforced per-chunk so an over-swap is caught when it occurs.
        if (job.cumulativeInput + c.amountIn > c.swapBudget) {
            revert CapitalCapExceeded(job.cumulativeInput + c.amountIn, c.swapBudget);
        }
        // Per-CHUNK swap cap (not per-job): a leg larger than swapPerJobCap is
        // filled as a series of capped chunks; the day's turnover still accumulates
        // across all of them. Liquidations keep the per-job `reserveSwapNotional`.
        MainV2Jobs.reserveSwapChunk(dailySwapNotional, job, c.amountIn, c.swapPerJobCap, c.dailySwapLimit);

        asset.forceApprove(address(executionAdapter), c.amountIn);
        pairedOut = executionAdapter.swapAssetToPaired(c.amountIn, c.keeperMinOut, c.deadline, false);
        asset.forceApprove(address(executionAdapter), 0);

        job.cumulativeInput += c.amountIn;
        job.cumulativeOutput += pairedOut;
    }

    /// @notice Phase 2: mint from the inventory the swap chunks accumulated for
    /// `jobId`. No swap here. `assetForMint = assetBudget - USDT already swapped`;
    /// the cap and two-sidedness are judged on the FINAL budget/legs, not a chunk.
    function openPosition(
        mapping(bytes32 => Job) storage jobs,
        IVaultBPriceGuard priceGuard,
        IDedicatedVenueV2 venue,
        IERC20 asset,
        IERC20 pairedToken,
        IERC20 rewardToken,
        OpenCall memory c
    ) external returns (uint256 positionId, uint256 pairedAcquired) {
        if (c.activePositionId != 0) revert PositionActive();
        Job storage job = jobs[c.jobId];
        // The swap phase must have created an OPEN series for this jobId (a NONE
        // job has kind NONE != OPEN, so an unknown jobId is rejected here too), and
        // it must not already be minted.
        if (job.kind != JobKind.OPEN) revert JobKindMismatch(JobKind.OPEN, job.kind);
        if (job.status == JobStatus.COMPLETED) revert JobAlreadyCompleted();

        pairedAcquired = job.cumulativeOutput;
        uint256 assetSwapped = job.cumulativeInput;
        if (c.assetBudget <= assetSwapped) revert InvalidAmount(); // budget must leave a USDT mint leg
        uint256 assetForMint = c.assetBudget - assetSwapped;
        if (assetForMint > asset.balanceOf(address(this))) revert InvalidAmount();
        if (c.assetBudget > c.canaryOpenCap) revert CapitalCapExceeded(c.assetBudget, c.canaryOpenCap);

        // Distinguish THIS job's accumulated paired leg from a stray remainder /
        // donation / a second concurrent series: the actual paired balance must not
        // exceed what this job acquired by more than dust (B8-T1). Same dust
        // threshold and semantics as P1-T1.
        uint256 actualPaired = pairedToken.balanceOf(address(this));
        if (actualPaired > pairedAcquired + c.pairedDustTolerance) revert InventoryPresent(actualPaired);
        if (address(rewardToken) != address(0)) {
            uint256 rewards = rewardToken.balanceOf(address(this));
            if (rewards > c.rewardDustTolerance) revert RewardInventoryPresent(rewards);
        }

        uint160 twapSqrt = priceGuard.twapSqrtPriceX96();
        MainV2Geometry.validateOpenTicks(c.tickLower, c.tickUpper, c.minTickWidth, c.maxTickWidth, twapSqrt);

        // Expected mint geometry at TWAP from the FINAL legs (assetForMint USDT +
        // pairedAcquired WBNB). A leg that rounds to zero at TWAP is not two-sided.
        (uint256 assetExpected, uint256 pairedExpected) =
            MainV2Geometry.expectedMintAmountsAtTwap(assetForMint, pairedAcquired, c.tickLower, c.tickUpper, twapSqrt);
        if (assetExpected == 0 || pairedExpected == 0) revert OpenNotTwoSided();
        uint256 amount0Min = MainV2Geometry.boundedLpMinimum(assetExpected, c.mintLossBps);
        uint256 amount1Min = MainV2Geometry.boundedLpMinimum(pairedExpected, c.mintLossBps);

        uint256 expectedFair =
            assetExpected + (pairedExpected != 0 ? priceGuard.fairValue(WBNB, USDT, pairedExpected) : 0);
        uint256 mintFloor = FullMath.mulDiv(expectedFair, BPS - c.mintLossBps, BPS);
        uint256 assetBeforeMint = asset.balanceOf(address(this));
        uint256 pairedBeforeMint = pairedToken.balanceOf(address(this));

        asset.forceApprove(address(venue), assetForMint);
        pairedToken.forceApprove(address(venue), pairedAcquired);
        positionId = venue.open(
            IDedicatedVenue.OpenArgs({
                assetAmount: assetForMint,
                pairedAmount: pairedAcquired,
                tickLower: c.tickLower,
                tickUpper: c.tickUpper,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: c.deadline
            })
        );
        asset.forceApprove(address(venue), 0);
        pairedToken.forceApprove(address(venue), 0);
        if (positionId == 0) revert InvalidPositionId();

        uint256 assetConsumed = assetBeforeMint - asset.balanceOf(address(this));
        uint256 pairedConsumed = pairedBeforeMint - pairedToken.balanceOf(address(this));
        uint256 deployedValue =
            assetConsumed + (pairedConsumed != 0 ? priceGuard.fairValue(WBNB, USDT, pairedConsumed) : 0);
        if (deployedValue < mintFloor) revert MintValueBelowFloor(mintFloor, deployedValue);

        MainV2Jobs.completeJob(job);
    }
}
