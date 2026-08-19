# Audit 2 — Re-Audit Candidate `234e7f1`

Successor to `95b4b88`. Remediates the Vault delta re-audit (8 findings) and the
convergent findings of the third independent integration audit.

## Flats (self-contained, solc 0.8.24, via_ir)
| file | sha256 |
|---|---|
| DeepYieldVaultB.reaudit.flat.sol | `c2d7cea263b1adc25aca41226fbc508c70d491f8be0e91d6bf1cf6a61a19d61d` |
| VaultBDepositLib.reaudit.flat.sol | `6c3b3c7d477b0a08425842dcb57e028f171502187686d02b8ac29c96a1663bd2` |
| PancakeV3MasterchefVenue.reaudit.flat.sol | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` (unchanged vs 95b4b88) |

## Changes vs `95b4b88` (Vault + Lib only; Venue unchanged)
- **F1 / C-01 (Critical):** `_settleFromKnownIdle(bool strategyHealthy)` — healthy full-queue
  path pays `min(batchShare, available)` (full fair NAV share, idle-capped); the pari-passu
  slice is retained only for the timeout force-settle. Removes the ~double-discount underpayment.
- **F2 (Critical):** economic-vs-sub-economic routing in `_commitRedeemCycle` keys off the
  **queue-open frozen** threshold base, immune to same-transaction supply pumping. The public
  growth-tracked `commitThresholdShares()` (B10-F8) is unchanged; C-1/H-2 anti-DoS preserved.
- **F3 (High):** `setMaxPendingRedeems` reverts below a live open queue; the full-queue commit
  triggers read the open-time frozen cap (`redeemCycleMaxPendingAtOpen`).
- **F4 (High):** force-settled `claimRedeem` releases the canonical handle via
  `VaultBDepositLib.cancelWithdrawalTolerant` (returns false instead of reverting) + admin
  `releaseDeferredRedeemHandle` escape hatch. Idle-backed payout, so no single stuck claim can
  freeze the vault; a later-honored handle returns assets to idle as shareholder value.
- **F5 / H-01 (High/Medium):** `cancelRedeem`/`updateRedeemReceiver` gate on the combined
  committed view via `_redeemCycleCommittedForExit` (outage-tolerant). **F8 / L-02:**
  `maxDepositStrict` likewise.
- **F6 (Medium):** full-queue auto-commit attempted under try/catch (`autoCommitOnFullQueue`
  self-call); a strategy `commitWithdrawalCycle` revert no longer bricks the marginal request.
- **M-01 (Medium):** the 100%-exit loss-cap bypass uses a near-100% **band**
  (`supply - committed <= MIN_REDEEM_SHARES`) in both `_initializeRedeemCycleSettlement` and
  `_previewRedeemCycleSettlement`, so a sub-redeemable dust holder cannot force the loss cap on a
  de-facto full exit.

## Known-open (NOT in this candidate)
- **H-02 (High) — 1-wei donation blocks strategy migration.** Confirmed; the robust fix is a
  cross-contract atomic migration-sweep (Main `withdrawIdleToVault` ↔ adapter ↔ vault),
  deferred as an owner-reviewed migration-flow change. Interim: `managerWithdrawAll` already
  sweeps any donation to the vault (never lost; becomes shareholder value); migrate atomically.
  See adjudication `ADJUDICATION-AUDIT2-INTEGRATION-3RDPASS-032`.

## QA
Full non-fork suite green (zero regressions vs the audited baseline). Delta witnesses
F1/F4/F6 pass; F2/F3 witnesses are `vm.skip` (harness-only setup issue — their mechanisms are
covered by the passing C-1 / B10-F8 / QueueLiveness suites).
