# Audit 2 — Re-Audit Candidate `0e35f63`

Successor to `abc8e73`. Applies the REAL fix for the H1 cluster (both remaining Highs) plus
the value-based loss-cap band, from the onedollaraudit re-audit of `abc8e73`.

## Flats (solc 0.8.24, via_ir) — compile-verified standalone; Vault EIP-170 margin 581 B
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `ba3ea8bb546be22cfe3960d316303661b242ba0a88785541e78641dcc8e37729` |
| VaultBDepositLib.reaudit.flat.sol | `24da714f9bb0d76f8df548113204205c4ed37c136153af689372c13803c13d25` (unchanged) |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged) |

## Changes vs `abc8e73`
- **Finding 1 (High) — FIXED.** A sub-economic full-queue batch settles from idle ONLY when idle
  covers the batch's fair NAV share; otherwise `_commitRedeemCycle` routes it through the strategy
  unwind (`commitWithdrawalCycle`), so a real-value batch an attacker's dust merely pushed over the
  count trigger is no longer sealed at a permanent underpayment. Pure dust (batchShare <= available)
  still settles from idle (the C-1/H-2 anti-DoS holds for a well-funded idle).
- **Findings 2 & 5 (High/Medium) — FIXED.** `forceSettleStuckCycle` is now TIMEOUT-ONLY: after the
  7-day timeout it recovers a committed cycle regardless of the strategy view. Closes the
  responsive-but-never-ready freeze AND the >2%-execution-loss claim freeze; removes the
  OOG/transient-revert-gameable probe.
- **Finding 4 (Medium) — FIXED.** The 100%-exit loss-cap bypass is gated on the residual holders'
  ASSET VALUE (`< MIN_DEPOSIT`), not a share count, in both settlement-init and preview — so a
  growing price-per-share cannot confiscate ever-larger real value.

## Design note (owner review)
- Finding 1 deliberately reverses the C-1/H-2 idle-short behavior (previously a sub-economic full
  queue never unwound). Rationale: not robbing an honest redeemer outweighs the bounded, self-paid
  dust-triggered-unwind grief. `test_C1` covers the well-funded-idle path (still idle-settles).
- Findings 2/5 reverse the tested `test_C2` invariant (a responsive strategy was never
  force-settleable). Rationale: post-timeout liveness; pari-passu bounds the downside. `test_C2`
  updated to the timeout-only policy.

## Known-open (Medium/Low — specified, see adjudication 035)
- **Finding 3 (Medium)** — exit-gate fail-open window; the simple fix reverses the tested F5
  outage-tolerance (trap-vs-escape tradeoff), so it is left as an owner decision. A monotonic
  "Main committed" latch reconciles both but adds storage on a tight margin.
- Lows: deferred-handle strategy-pair snapshot (Finding 6), `_payOrEscrow` -> `trySafeTransfer`
  (Finding 7), tolerant-dispatch return-data cap (Finding 8), readiness-gate live-supply (Finding 9),
  ADMIN_ROLE centralization (10), pause scope (11).

## QA
Full non-fork suite green: **1582 passed / 0 failed / 2 skipped** (skips = F2/F3 harness witnesses).
Standalone flat compile-verified; Vault margin 581 B.
