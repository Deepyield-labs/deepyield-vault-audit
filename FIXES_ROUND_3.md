# Vault B V2 — round 3 remediation

This branch is the code **after** the round-1 audit findings were addressed, plus two
further internal review rounds. It supersedes `fixes/round-2`.

Compare against the audited baseline: `main` (the exact code the seven round-1 reports
were written against).

```
git diff main...fixes/round-3
```

## What changed since `main`

### Round 1-2 — the seven audit reports (18 fixes)

| area | fix |
|---|---|
| `DedicatedVaultMainV2` | withdrawal freeze via a 1-wei donation; liquidation output floor on the price-guard basis; `FullMath.mulDiv` `unchecked` scope (a DoS above ~18.45 WBNB, not latent); open-tick validation and a non-tautological mint minimum; one pricing basis for the close floor and NAV; `halt` now gates money paths; daily/turnover caps; last-admin protection |
| `DedicatedVaultStrategyAdapterV2` | fee sink as a single point of failure — the obligation is deferred instead of freezing withdrawals; loss-path cost basis resynced to actual inventory |
| `DeepYieldVaultB` | one effective redeem-cycle commitment; claim jam; escrow instead of a push transfer on blacklist; timelocked strategy change; non-reverting `max*` views |
| `PancakeV3MasterchefVenue` | `close()` was all-or-nothing and could lock the venue permanently — now resumable stages plus a stranded-position write-off; harvest income measured as a balance delta; constructor validates the pool/token/fee wiring |
| `VaultBPriceGuard` / `VaultBCakePriceGuard` | mode-dependent oracle deviation so the emergency exit is not killed by the condition it exists for; aggregator bounds; hard configuration ceilings |
| `PartnerAttributedSplitter` / `PartnerRegistry` | wrapper-call failure isolation; anti-JIT weight checkpoint; measured token delta; timelocked treasuries |

### Round 3 — deployability and execution

| fix | why |
|---|---|
| **Five linked libraries** (`MainV2Geometry`, `MainV2Jobs`, `MainV2Valuation`, `MainV2Liquidation`, `MainV2Open`) | the contract had grown to 30,792 bytes — **over the EIP-170 limit** and undeployable. Bodies moved out; behaviour unchanged. Now 20,522 bytes, 4,054 to spare. They are `external` libraries: linked and reached by `delegatecall`, so `address(this)` inside them is the Main contract. |
| **Dust tolerance in the inventory gates** | a 1-wei donation of the paired or reward token permanently blocked `openPosition` and `enableOperations`. |
| **Fail-safe `max*` views** | `maxWithdraw`/`maxRedeem`/`maxDeposit`/`maxMint` no longer revert when the strategy is unavailable or returns a pathological value; they degrade to 0. `totalAssets` is **deliberately left reverting** — a silent zero there would zero the share price. |
| **Two-phase entry** | `openPosition` no longer swaps. `openSwapChunk(jobId, chunkIndex, amountIn, keeperMinOut, deadline)` fills the swap leg as a series of per-chunk-capped swaps; `openPosition` then mints from what that job accumulated. Large entries are filled across blocks so price impact does not compound. |
| **One global open series** | `activeOpenJobId`: exactly one accumulating series at a time. Without it, a fresh `jobId` reset the per-job accumulator and `canaryOpenCap` could be exceeded arbitrarily — five series of one cap each accumulated five times the cap before any mint. `cancelOpenSeries` releases the lock only when the paired inventory is at or below dust, so cancelling cannot be used as the same bypass. |
| **Sequential chunk indices** | `chunkIndex == job.chunks`. Sparse indices are rejected, so the next index is recoverable from on-chain state. |
| **Emergency recovery commits the redeem cycle** | `recoverCloseUnstake` and `writeOffStrandedPosition` now commit the queued withdrawal batch before the first irreversible venue action, as the normal close already did. Without it a queued request could be cancelled out of the batch after the position had already been closed. |
| **Full-supply exit no longer freezes the vault** | the loss cap was enforced unconditionally in the settlement path while the preview already short-circuited when the entire supply is exiting. A 100%-supply exit with >2% execution loss reverted every claim forever. The same short-circuit now applies in both paths. |
| **Insolvency guard** | at `totalAssets()==0` with `totalSupply()>0`, `maxDeposit`/`maxMint` return 0. This is distinct from a strategy outage, which the try/catch wrapper already handles. |
| **Commit threshold snapshot** | the 5% commit threshold is taken from the supply at queue-open, not recomputed against live supply the caller can move in the same block. |
| **Tunable redeem-queue cap** | `maxPendingRedeems` is admin-adjustable below an immutable ceiling, so a sybil-filled queue can be answered without a redeploy. |
| **Direction-aware NAV** | deposits price on an upper valuation (`max` of the TWAP/spot close geometry, same oracle-priced legs), redemptions keep the lower (`min`). One number cannot be conservative for both: an under-valued NAV over-mints on deposit, an over-valued one over-pays on redeem. `convertToShares`/`convertToAssets` deliberately stay on the lower basis and diverge from `previewDeposit` — ERC-4626 permits that, and it is asserted by a test so it is not "fixed" later. |

### Round 4-6 — findings from two further independent reviews

| fix | why |
|---|---|
| **One global open series** | `canaryOpenCap` was per-`jobId`: five series of one cap each accumulated five times the cap before any mint. `activeOpenJobId` allows exactly one accumulating series; `cancelOpenSeries` releases the lock only when the paired inventory is at or below dust. Chunk indices must be sequential. |
| **Reserved series context** | the two-phase open measured different quantities against one cap, so a swap leg equal to the cap could strand inventory with an unmintable mint. `reserveOpenSeries` now pins the full budget, the swap leg (strictly below the budget), the ticks and a deadline ceiling **before the first swap**, and proves the reserved plan is two-sided so a dust remainder cannot round a CL leg to zero. |
| **Emergency recovery commits the redeem cycle** | `recoverCloseUnstake` and `writeOffStrandedPosition` commit the queued batch before the first irreversible venue action. |
| **Full-supply exit no longer freezes the vault** | the loss cap was enforced unconditionally in settlement while the preview already short-circuited; a 100%-supply exit above the cap reverted every claim forever. |
| **Insolvency guard** | at `totalAssets()==0` with `totalSupply()>0`, `maxDeposit`/`maxMint` return 0. Distinct from a strategy outage. |
| **Commit threshold snapshot** | the 5% threshold is taken from the supply at queue-open, not recomputed against live supply the caller can move in the same block. |
| **Redeem-queue liveness** | a full queue is now a second commit trigger alongside the 5% threshold. Filling the queue with dust used to deny redemption to everyone; now it triggers the cycle, and the filler exits with it. Slots aggregate per `(owner, receiver)`. |
| **Bounded recovery for a stuck cycle** | `forceSettleStuckCycle()` — permissionless after a 7-day timeout from commit. It never calls the strategy: the payout base is the commit-time snapshot capped by actual idle, so a permanently broken readiness source can no longer lock the vault. Funds that arrive later belong to the remaining holders. |
| **First strategy activation** | immediate activation is allowed only on a pristine vault (zero supply and zero assets); once deposits exist the first strategy goes through the same timelock as a change. |
| **Two-step `DEFAULT_ADMIN_ROLE`** | transfer requires acceptance by the recipient after a delay, and a direct `grantRole` of the root is blocked. Role separation is now a contract invariant rather than a property of the deploy procedure. |
| **Direction-aware NAV** | deposits price on an upper valuation, redemptions on the lower. Note the scope limit below. |

**Scope limit, stated rather than implied:** the canonical strategy adapter only permits deposits
while no LP position is open, and the upper/lower valuations differ only while one is open — so
the directional NAV is defence-in-depth, not a closure of the "no independent bound on
strategy-reported NAV" finding. That finding remains open.

### Round 7-8 — later review rounds

| fix | why |
|---|---|
| **Claimable liabilities excluded from deployable capital** | the adapter treated the vault's raw idle balance as deployable, including assets already escrowed for settled-but-unclaimed redeem requests. Those could be deployed into an LP position, leaving a claimer short. |
| **Vault snapshot precedes the Main commitment** | Main now calls back into the vault before its own irreversible close-side commit, so the vault's snapshot and recovery clock are always frozen first. Without it a Main-first commitment left the vault unable to record the cycle and therefore unable to recover it. |
| **Queue-fill commits atomically** | the request that fills the redeem queue performs the snapshot and commitment in the same transaction, so a cancellation cannot front-run the commit and restore the denial-of-service. |
| **First-strategy activation re-checked at apply time** | the empty-vault gate previously existed only on the immediate path; a proposal could mature while the vault was empty and then be applied after deposits arrived. |
| **Cumulative emergency budget** | the guardian's emergency loss budget was bounded only in time, so one activation authorised every emergency swap for the whole window at the loosened tolerance. It now carries a cumulative notional limit, consumed only after a swap succeeds; on exhaustion the floor degrades to the normal budget rather than blocking the emergency exit. |
| **Two-step admin on both price guards** | the same transfer-with-acceptance rule already applied to the vault. |
| **Rounding against the caller** | deviation and `minOut` now round against the caller instead of truncating toward zero. |
| **Legacy round-completeness check removed** | `answeredInRound < roundId` false-positives across aggregator phase transitions and reverted on genuinely fresh data, with no fallback. Freshness is still enforced by `updatedAt` and a positive answer. |
| **Fee-tier cross-check** | each execution adapter asserts its `POOL_FEE` matches the guard it is paired with, so an independent redeploy of one cannot silently price against a different pool than it swaps in. |

## Known open at the time of writing

**`DeepYieldVaultB` has one open liveness defect.** If a redeem request is queued, the cycle has
not yet been committed, and the strategy then fails on every call, the requester cannot cancel:
the commitment view reads the strategy, the commit path reverts, and the timeout-based force
settlement requires a local commitment that was never recorded. The escrowed shares have no exit
in that state. A fix is in progress; it is disclosed here rather than left for you to find.

The unbounded strategy-reported NAV finding also remains open — the directional deposit/redeem
valuation is defence-in-depth, not a closure, because the canonical adapter only permits deposits
while no position is open, which is exactly when the two valuations coincide.

## Asymmetry worth knowing

The entry swap leg may reach `canaryOpenCap`, while liquidation is still capped per job.
An aborted entry series whose accumulated notional exceeds the per-job liquidation cap therefore
**cannot be drained by a single final chunk** — it reverts `SwapCapExceeded` and must be drained
by a series of separate liquidation jobs. This is enforced and tested behaviour, not a defect;
`testAbortedOpenSeriesDrainsViaSeparateJobs` pins it. Nothing is locked.

## Not addressed in this branch

- `PartnerAttributedSplitter` F-2/F-5 (recovering a broken current wrapper; blacklisting the
  splitter address) — they touch the factory and onboarding.

- `PancakeV3MasterchefVenue` High-3/High-5/Medium-8 and the two block-6 Medium findings.
- A spot-vs-oracle gate on **opening** a position.
- Calibration of the 1% normal swap loss budget. Note that the floor is derived from
  `min(Chainlink, TWAP)` and, at the time of writing, Chainlink diverged from spot by ~48 bps in
  a calm market — so most of that budget absorbs reference lag, not slippage.
- Partner attribution is being taken off-chain, so `PartnerWrapper` and `WrapperFactory` are
  **not part of this scope** and are not deployed. `PartnerAttributedSplitter` and
  `PartnerRegistry` remain in the tree because the round-1 report covered them.

## Reproduce

```
forge test --no-match-path 'test/*Fork*'     # 610 passed, 0 failed
forge build --sizes --skip test              # DedicatedVaultMainV2 22,262 bytes
```

Fork tests need a BSC archive RPC and are excluded here.

Flattened single-file copies for submission are in `audit/flat/`, checksums in
`audit/flat/SHA256SUMS.txt`.
