# Round 2 — what changed since `main`

This branch (`fixes/round-2`) carries the remediation of every finding accepted from the
round-1 audits of this repository. `main` is unchanged and still holds the code the round-1
reports were written against, so the two are directly comparable.

**Compare:** `main...fixes/round-2`

## Test status on this branch

`forge test --no-match-path 'test/*Fork*'` → **450 passed, 0 failed** (27 suites).
Fork suites need a BSC archive RPC and are excluded here.

## Contracts changed

| contract | what changed |
|---|---|
| `DedicatedVaultMainV2` | dust tolerance on withdrawal-readiness + guardian dust sweep to vault only; resumable/chunked liquidation; oracle floor on liquidation output taken from the price guard's own budget; tick-range validation and TWAP-anchored mint minima with an aggregate mint floor; spot-vs-oracle coherence gate before close; single-basis close floor; NAV = min(TWAP, spot); funding ceiling on max-basis exposure; halt now gates keeper paths; emergency turnover recorded in the daily counter; last-admin protection; venue recovery wiring |
| `DeepYieldVaultB` | redeem-cycle commit read through the combined view with a lazy snapshot; claim tolerates strategy over-delivery; payout escrows instead of reverting on a blacklisted receiver, with the liability excluded from NAV; two-step timelocked strategy change; `max*` views fail safe while `totalAssets` deliberately still reverts |
| `DedicatedVaultStrategyAdapterV2` | fee remittance decoupled from withdrawal (deferred obligation + `remitFee`); cost basis resynced on loss-path withdrawals |
| `PancakeV3MasterchefVenue` | `close()` decomposed into independently retryable stages; stranded-position write-off; harvest income measured on the venue's own balance; constructor validates pool/token/fee wiring |
| `VaultBPriceGuard`, `VaultBCakePriceGuard` | oracle-deviation limit is now mode-aware so an emergency exit is not blocked by the condition it exists for; Chainlink aggregator min/max bound check; economic ceilings on configurable bps |
| `libraries/FullMath` | `unchecked` restored on the 512-bit path |

## Not changed

`PartnerAttributedSplitter` / `PartnerRegistry` — their audit arrived last and their findings
are not remediated yet. Out of scope for this round.
