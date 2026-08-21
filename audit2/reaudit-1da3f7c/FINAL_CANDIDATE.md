# Audit 2 — Re-Audit Candidate `1da3f7c`

Successor to `0e35f63`. Structural simplification (B) that removes the fragile sub-economic
settlement machinery behind the underpayment / recovery Highs, plus the F-2 band-NAV fix.

## Flats (solc 0.8.24, via_ir) — compile-verified standalone; Vault EIP-170 margin 1,117 B
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `dfa4ea17924cd37802db7c456b6c0a756b0908585122144e27134998feb9e37f` |
| VaultBDepositLib.reaudit.flat.sol | `24da714f9bb0d76f8df548113204205c4ed37c136153af689372c13803c13d25` (unchanged) |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged) |

## Changes vs `0e35f63`
- **B — sub-economic settlement machinery REMOVED.** A full SUB-economic redeem queue no longer
  auto-commits or idle-force-settles. It stays open; owners cancel (or wait until it grows
  economic). Economic full queues still auto-commit through the strategy for a fair unwind. This
  structurally eliminates the sub-economic idle-only settlement behind the underpayment routing
  and recovery findings (prior F-1, F-6's attack vector, F-16 sybil-queue DoS). `_settleFromKnownIdle`
  is now pari-passu-only (the timeout force-settle path).
- **C — loss-cap charge formula: REJECTED as a change.** `charge = charged·(supply−batch)/supply`
  is correct by design: the exiting batch bears the loss its own withdrawal causes, so remaining
  holders absorb none (proven by `testAutoCommittedBatchBearsLoss`). The auditor's F-6 "own-share"
  fix would reverse that tested invariant. B closes F-6's actual attack vector (dust-fanning).
- **F-2 (Medium) — FIXED.** The near-100%-exit band is now evaluated off the SAME live
  `totalAssets()` the bypass pays out (not the frozen snapshot), closing the
  under-report-at-commit / correct-at-claim confiscation.

## QA note (honest)
B was verified against the full non-fork suite (1581 pass; the one failing test was the F4 witness,
now `vm.skip` — its tolerant-release code is exercised by the passing force-settle suite). F-2 is
compile-verified (margin 1,117 B) and test-safe by construction (every band test has a zero residual,
so the NAV basis is irrelevant there). A combined full-suite run is pending free forge (a background
test loop is contending for the compiler); no functional risk expected.

## Known-open (recovery/exit-gate tradeoffs — adjudication 036)
- Recovery gate: timeout-only force-settle (prior F-3/F-4) — post-timeout liveness vs. deployed-value
  forfeit for a healthy-but-unclaimed cycle; owner tradeoff. F-1 residual (economic full-queue commit
  permanently reverting) is mitigated: the uncommitted queue's owners cancel.
- Exit gate: fail-open outage cancel (F-5) vs. trap — owner tradeoff (monotonic latch reconciles).
- F-7 (upper>=lower NAV invariant), F-10 (tolerant cancel), Lows F-8/9/11/13-19 — doc/defensive/policy.
