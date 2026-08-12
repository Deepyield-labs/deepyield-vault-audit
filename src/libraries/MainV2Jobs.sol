// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Job/chunk types shared by `DedicatedVaultMainV2` and `MainV2Jobs`.
/// File-level so both refer to the SAME declaration — the mapping value type in
/// `Main` must match the storage-pointer parameter type of the library.
enum JobKind {
    NONE,
    OPEN,
    CLOSE_TO_INVENTORY,
    LIQUIDATE_WBNB,
    LIQUIDATE_REWARD
}

enum JobStatus {
    NONE,
    ACTIVE,
    COMPLETED
}

struct Job {
    JobKind kind;
    JobStatus status;
    uint64 createdAt;
    uint64 completedAt;
    uint32 chunks;
    uint256 cumulativeInput;
    uint256 cumulativeOutput;
    uint256 cumulativeNotionalAsset;
}

/// @title MainV2Jobs
/// @notice Job lifecycle + chunk de-duplication + per-job/per-day swap-notional
/// accounting, extracted from `DedicatedVaultMainV2` so the code deploys once and
/// links (EIP-170). Moved verbatim; the storage the functions touch (the `jobs`,
/// `usedChunks` and `dailySwapNotional` mappings) is passed by reference — a
/// linked library runs via `delegatecall`, so the pointers address `Main`'s own
/// storage, and the caps that are configuration are passed by value. The error
/// signatures match `Main`'s, so their selectors are identical for existing
/// `expectRevert(DedicatedVaultMainV2.X.selector)` tests.
library MainV2Jobs {
    error InvalidJobId();
    error JobKindMismatch(JobKind expected, JobKind actual);
    error JobAlreadyCompleted();
    error DuplicateChunk(uint32 chunkIndex);
    error NonSequentialChunk(uint32 provided, uint32 expected);
    error SwapCapExceeded(uint256 requested, uint256 cap);
    error DailySwapCapExceeded(uint256 requested, uint256 cap);

    /// @notice Open or continue a chunked job and mark `chunkIndex` used exactly
    /// once. Returns the job storage slot so the caller can read/write its fields.
    function beginChunk(
        mapping(bytes32 => Job) storage jobs,
        mapping(bytes32 => mapping(uint32 => bool)) storage usedChunks,
        bytes32 jobId,
        JobKind kind,
        uint32 chunkIndex
    ) external returns (Job storage job) {
        if (jobId == bytes32(0)) revert InvalidJobId();
        job = jobs[jobId];
        if (job.status == JobStatus.NONE) {
            job.kind = kind;
            job.status = JobStatus.ACTIVE;
            job.createdAt = uint64(block.timestamp);
        } else {
            if (job.kind != kind) revert JobKindMismatch(job.kind, kind);
            if (job.status == JobStatus.COMPLETED) revert JobAlreadyCompleted();
        }
        if (usedChunks[jobId][chunkIndex]) revert DuplicateChunk(chunkIndex);
        // Chunks must be consecutive from zero (B9-T1): `job.chunks` is the count so
        // far, so the next index must equal it. This forbids sparse indices (which
        // hid how many chunks a series had) and makes the next index recoverable
        // from state — the keeper's restart fix (K-T3) reads `job.chunks`. Checked
        // AFTER the duplicate guard so replaying a used index still reverts
        // DuplicateChunk, not this.
        if (chunkIndex != job.chunks) revert NonSequentialChunk(chunkIndex, job.chunks);
        usedChunks[jobId][chunkIndex] = true;
        job.chunks += 1;
    }

    function completeJob(Job storage job) external {
        job.status = JobStatus.COMPLETED;
        job.completedAt = uint64(block.timestamp);
    }

    /// @notice Reserve `notional` against the job cap and the day's turnover.
    /// Emergency volume is still ACCOUNTED (so a later normal swap sees it), but
    /// only the daily-LIMIT check is skipped for emergencies — a deliberate relief.
    function reserveSwapNotional(
        mapping(uint64 => uint256) storage dailySwapNotional,
        Job storage job,
        uint256 notional,
        bool emergency,
        uint256 hardMaxActiveAssets,
        uint256 swapPerJobCap,
        uint256 dailySwapLimit
    ) external {
        uint256 jobTotal = job.cumulativeNotionalAsset + notional;
        uint256 jobCap = emergency ? hardMaxActiveAssets : swapPerJobCap;
        if (jobTotal > jobCap) revert SwapCapExceeded(jobTotal, jobCap);
        job.cumulativeNotionalAsset = jobTotal;

        uint64 day = uint64(block.timestamp / 1 days);
        uint256 dayTotal = dailySwapNotional[day] + notional;
        if (!emergency && dayTotal > dailySwapLimit) revert DailySwapCapExceeded(dayTotal, dailySwapLimit);
        dailySwapNotional[day] = dayTotal;
    }

    /// @notice Open-swap-chunk accounting (B8-T1). Unlike `reserveSwapNotional`
    /// (used by liquidations, unchanged), the per-transaction cap `swapPerJobCap`
    /// bounds THIS CHUNK, not the job's running total — a swap leg larger than the
    /// per-tx cap is filled as a series of chunks (each capped for slippage), while
    /// the day's turnover still accumulates across all chunks. The job total
    /// (`cumulativeNotionalAsset`) is tracked but NOT capped here; the aggregate
    /// bound is the caller's incremental `canaryOpenCap` check (position size).
    function reserveSwapChunk(
        mapping(uint64 => uint256) storage dailySwapNotional,
        Job storage job,
        uint256 notional,
        uint256 swapPerJobCap,
        uint256 dailySwapLimit
    ) external {
        if (notional > swapPerJobCap) revert SwapCapExceeded(notional, swapPerJobCap);
        job.cumulativeNotionalAsset += notional;

        uint64 day = uint64(block.timestamp / 1 days);
        uint256 dayTotal = dailySwapNotional[day] + notional;
        if (dayTotal > dailySwapLimit) revert DailySwapCapExceeded(dayTotal, dailySwapLimit);
        dailySwapNotional[day] = dayTotal;
    }
}
