# Audit 2 — Re-Audit Candidate `abc8e73`

Successor to `b006349`. Applies the two clear fixes (Finding 8, Finding 4) from the
onedollaraudit re-audit of `b006349`. The two remaining Highs (Finding 1/2, the H1
sub-economic-underpayment + routing-base cluster) and the Medium recovery items are
specified for a focused owner-reviewed pass (adjudication 034).

## Flats (solc 0.8.24, via_ir) — compile-verified standalone; Vault EIP-170 margin 609 B
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `de594ec7eca9d1f6b4b472ceaf7436b068958fb93613938c1c5d281215b18e78` |
| VaultBDepositLib.reaudit.flat.sol | `24da714f9bb0d76f8df548113204205c4ed37c136153af689372c13803c13d25` |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged) |

## Changes vs `b006349`
- **Finding 8 (Low, EIP-4626) — FIXED.** `VaultBDepositLib.maxDepositStrict` floors reported
  capacity to 0 when below `MIN_DEPOSIT`, so `deposit(maxDeposit(x))` no longer reverts.
- **Finding 4 (Medium) — FIXED.** `releaseDeferredRedeemHandle` now requires the handle to be a
  recorded deferred (orphaned) handle (`deferredRedeemHandle` mapping, set on a failed tolerant
  release), so the admin hatch can never cancel a live PENDING request.

## Known-open (deploy-blocking cluster — see adjudication 034)
- **Finding 1 + 2 (High) — the H1 cluster.** Sub-economic full-queue idle-settle underpays when
  `idle < batchShare`, and the frozen routing base can be inflated by a same-tx deposit at
  queue-open. Fix = treasury deficit top-up / trustless timeout fallback WITHOUT a strategy
  unwind (preserving the C-1/H-2 dust anti-DoS) + hardening the base snapshot. Three audits now
  converge here; this is the single focused remaining blocker.
- **Finding 3 (Medium)** — a >2% loss freezes claims, escapable only via manual treasury funding;
  same recovery cluster (trustless timeout fallback).
- **Finding 5 (Medium, was H2)** — force-settle recovery gate unreachable after a strategy-side-only
  commit; timeout-only recovery reverses the tested `test_C2` invariant (owner tradeoff).
- **Finding 6 (Medium, was H3)** — the 100%-exit band is share-count based; as price-per-share
  grows the confiscated dust value grows. Fix = gate on asset value, not share count.
- **Findings 7/10/11/12/13/14 (Low)** — M3 sustained-outage, M1 latch, escrow owner-withdraw,
  reverting-commit recovery, H-02 donation (Low), readiness-gate live-supply griefing.

## QA
Full non-fork suite green at `b006349` (zero regressions). Finding 8 lives in the library; Finding 4
adds a mapping-gated admin check. Standalone flat compile-verified; Vault margin 609 B.
