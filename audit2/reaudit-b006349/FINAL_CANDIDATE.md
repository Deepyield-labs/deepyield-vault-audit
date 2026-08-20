# Audit 2 — Re-Audit Candidate `b006349`

Successor to `234e7f1`. Applies the one confirmed correctness fix (H3) from the
onedollaraudit re-audit of `234e7f1`; all other `234e7f1` remediations stand.

## Flats (solc 0.8.24, via_ir)
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `234dd3bebe08d2f4833f8a3ff6678546bc6f0683ac6fca8f2a86a422ebb14975` |
| VaultBDepositLib.reaudit.flat.sol | `6c3b3c7d477b0a08425842dcb57e028f171502187686d02b8ac29c96a1663bd2` (unchanged) |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged) |

## Change vs `234e7f1`
- **H3 (High) — FIXED.** The 100%-exit loss-cap bypass band used `<= MIN_REDEEM_SHARES`,
  capturing a remainder of exactly `MIN_REDEEM_SHARES` (a legitimate minimum-size holder, not
  sub-redeemable dust) and diluting them to ~0 on low-supply vaults. Changed to strict `<` in
  BOTH `_initializeRedeemCycleSettlement` and `_previewRedeemCycleSettlement`, matching the
  documented "strictly less than" intent.

## Known-open (deploy-blocking; specified, not yet coded — see adjudication 033)
These are genuine design-level items with tested-invariant / anti-DoS tensions, deferred for an
owner-reviewed pass rather than a unilateral change to the settlement/recovery core:
- **H1 (High)** — a sub-economic full-queue batch idle-settles even when `idle < batchShare`,
  permanently underpaying. Fix = treasury deficit top-up (no strategy unwind, preserving the
  C-1/H-2 anti-DoS). Conflicts with the "dust must not force an unwind" property if fixed naively.
- **H2 (High)** — `forceSettleStuckCycle` recovery gate (`withdrawalCycleCommitted`) mismatches the
  claim gate (`withdrawalReady`); a responsive-but-never-ready strategy can freeze the vault. Fix =
  timeout-only recovery, but this **reverses the deliberately-tested invariant** in
  `test_C2_ResponsiveCanonicalStrategyCannotBeForceSettled` (never force-settle a responsive
  strategy) — an owner design tradeoff (post-timeout liveness vs. price protection).
- **M1 (Medium)** — exit-gate fail-open window (Main auto-commits, then view outage). Fix = a
  monotonic "Main committed" latch.
- **M2 (Medium)** — `_activateStrategy` probe not `try/catch`-wrapped; a reverting strategy blocks
  migration. Fix = try/catch + timelocked admin drained-attestation.
- **H-02 (Medium, re-characterized down from High)** — 1-wei donation blocks migration; fix =
  atomic migration-sweep (Main `withdrawIdleToVault` ↔ adapter ↔ vault). Liveness-only, swept to NAV.

## QA
Full non-fork suite green at `234e7f1` (zero regressions). H3 is a strict-inequality change in two
lines; the existing 100%-exit suite (zero remainder) is unaffected.
