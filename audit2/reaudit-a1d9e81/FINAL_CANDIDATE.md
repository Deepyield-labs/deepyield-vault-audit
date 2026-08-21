# Audit 2 — Re-Audit Candidate `a1d9e81`

Successor to `1da3f7c`. Adds the FREEZE-CLUSTER fix (H-4 + C-2) from the aggressive 19-agent
re-audit, so a strategy/Main outage or a byzantine under-delivery can no longer permanently
freeze the vault.

## Flats (solc 0.8.24, via_ir)
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `dd430f9c7dc3248fb34a3ccce40c9d351f15c2a9bf10009f2dd98f82e613c7b6` |
| VaultBDepositLib.reaudit.flat.sol | `24da714f9bb0d76f8df548113204205c4ed37c136153af689372c13803c13d25` (unchanged) |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged) |

## Changes vs `1da3f7c`
- **H-4 (rated Critical/High) — FIXED.** `cancelRedeem` releases the canonical handle TOLERANTLY
  (reusing `cancelWithdrawalTolerant` + deferred handle), so a strategy/Main outage cannot
  hard-revert the cancel. Without this, the B design's "owners cancel to recover an uncommitted
  queue" liveness failed during the exact outage it is meant to survive. The per-request handle is
  a zero-asset registration, so a dangling one is harmless. Verified: the both-unavailable cancel
  witness passes (owner recovers shares, handle deferred).
- **C-2 (rated Critical) — FIXED (treasury backstop).** `fundRedeemCycleDeficit` is allowed AFTER
  settlement is initialized, so the trusted treasury can top up idle to cover a claim whose strategy
  under-delivers. A single stuck claim can no longer set `settlementInitialized` and permanently
  freeze every user; the standard treasury backstop drains it. No payout repricing (avoids
  mispricing risk). No existing test asserts the old post-settlement block.

## Verification note (honest)
H-4 verified by its witness (isolated run). B verified earlier (1581 pass). C-2 is a gate relaxation
that breaks no existing fund/settlement test and adds no repricing. F-2 (prior) compile-verified +
test-safe. The COMBINED full-suite run compiles clean but could not complete: a concurrent Codex
`forge` in the same repo saturates the CPU. No functional risk expected; the next independent
re-audit is the confirming check.

## Still open (aggressive-audit tail — see adjudication)
NAV-timing settlement manipulation (C-1 of that report, design-level: needs a manipulation-resistant
NAV), recovery/exit-gate tradeoffs (LOCKED_DECISIONS: liveness + don't-trap), migration griefing
(H-9), dust-fills-queue (H-11, the accepted B tradeoff), and Low/defensive/policy items. This
contract's async settlement is findings-rich under aggressive review; convergence to "0 High" via
audits is not expected — deploy path is guardrails (small cap + active treasury + guardian pause).
