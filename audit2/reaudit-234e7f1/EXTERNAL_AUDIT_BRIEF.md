# External Audit Brief — DeepYield Vault B, candidate `234e7f1`

**Prepared for:** external security auditor.
**Date:** 2026-08-19.
**Chain / compiler:** BSC (BNB Chain), Solidity 0.8.24, `via_ir=true`, optimizer 200 runs.

## 1. What to audit

Repository: `github.com/Deepyield-labs/deepyield-vault-audit`
Branch: **`audit2/reaudit-234e7f1-20260819`** (commit `eb88aa3`).

Self-contained flattened sources (compile standalone, no remappings needed):

| File | sha256 |
|---|---|
| `audit2/reaudit-234e7f1/flat/DeepYieldVaultB.reaudit.flat.sol` | `c2d7cea263b1adc25aca41226fbc508c70d491f8be0e91d6bf1cf6a61a19d61d` |
| `audit2/reaudit-234e7f1/flat/VaultBDepositLib.reaudit.flat.sol` | `6c3b3c7d477b0a08425842dcb57e028f171502187686d02b8ac29c96a1663bd2` |
| `audit2/reaudit-234e7f1/flat/PancakeV3MasterchefVenue.reaudit.flat.sol` | `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d` |

This is a **delta** re-audit over the previously reviewed candidate `95b4b88`. Only
`DeepYieldVaultB` and its library `VaultBDepositLib` changed; `PancakeV3MasterchefVenue` is
byte-identical to `95b4b88` (hash above unchanged) and was already confirmed donation-immune.

## 2. System context (what the contract is)

`DeepYieldVaultB` is an ERC-4626 vault with an **asynchronous redeem cycle**:
`requestRedeem` (escrow shares) → cycle commit (either a 5%-of-supply economic threshold, or a
full pending-redeem queue) → settlement → `claimRedeem`. Deployed capital lives in an external
strategy (adapter → `DedicatedVaultMainV2` → PancakeV3 venue). A full-but-sub-economic queue is
settled **from idle only** (no strategy unwind) to prevent a queue-fill DoS; a timeout
`forceSettleStuckCycle` recovers a cycle whose strategy readiness source is unavailable.
`strategyAssetSource` is `DedicatedVaultMainV2` (the root custody address).

## 3. Scope — verify these remediations (fail-before / pass-after)

Confirm each fix is correct, complete, and non-bypassable, and preserves the invariant it touches.

1. **Settlement underpayment (was Critical).** Healthy full-queue settlement must pay
   `min(fairNavShare, availableIdle)` — the full fair NAV share, capped by idle — NOT a
   pari-passu re-scaled slice. The pari-passu slice must remain only on the timeout
   force-settle path (a genuinely unavailable strategy). Check the idle-poor case
   (`availableIdle < fairNavShare`).
2. **Same-transaction threshold manipulation (was Critical).** The economic-vs-sub-economic
   routing decision must key off the queue-open **frozen** threshold base, so a deposit made in
   the queue-filling transaction cannot inflate the live threshold to misroute a genuinely-large
   batch into the idle-only (no-unwind) path. Confirm the growth-tracking public view is
   unchanged and the dust anti-DoS still holds.
3. **Admin cap retune (was High).** `setMaxPendingRedeems` must reject lowering below a live open
   queue; the full-queue commit triggers must read the open-time frozen cap. Confirm an admin
   parameter change can no longer arm the permissionless full-queue commit bypass.
4. **Force-settled claim liveness (was High).** A force-settled `claimRedeem` must release the
   canonical strategy/Main handle **tolerantly** (never revert), with an admin escape hatch to
   retry an orphaned handle. Verify: no single un-releasable handle can freeze the whole vault;
   the idle-backed payout means a later-honored handle returns assets to vault idle (shareholder
   value), never a double payment to the already-paid receiver; NAV is not overstated.
5. **Exit-gate asymmetry (was High + Low).** `cancelRedeem`, `updateRedeemReceiver`, and
   `maxDepositStrict` must gate on the combined committed view (local flag OR strategy
   auto-commit). The variant used for owner-exit must be outage-tolerant: an owner can still
   cancel an UNCOMMITTED request during a strategy outage, but a Main-committed batch on a
   responsive strategy is locked.
6. **Full-queue auto-commit coupling (was Medium).** The full-queue trigger's strategy commit
   must be attempted under try/catch so a strategy revert cannot brick the marginal (Nth)
   request's escrow/slot; verify no reentrancy is introduced by the self-call trampoline.
7. **100%-exit loss-cap bypass (was Medium).** The full-exit loss-cap bypass must use a
   near-100% band (remainder ≤ one minimum redeemable unit) consistently in both the
   settlement-init and preview paths, so a sub-redeemable dust holder cannot force the loss cap
   on a de-facto full exit. Verify underflow-safety and no over-claim.

## 4. Known-open finding — please re-characterize, do NOT assume fixed

**Strategy-migration griefing (High).** `_activateStrategy` blocks migration while
`balanceOf(strategyAssetSource) != 0`; anyone can donate 1 wei to the public `strategyAssetSource`
to block `applyStrategy()` indefinitely (and the strategy attestation also reads raw idle). This is
**intentionally not fixed** in this candidate — the robust fix is a cross-contract atomic
migration-sweep and is under owner review. Please confirm/refute severity and assess the proposed
fix (a vault-triggered `withdrawIdleToVault` sweep inside `_activateStrategy` before the drain
gate) for correctness and for whether it preserves the "do not migrate over un-swept real funds"
safety property. Note the interim mitigation: the operational drain (`managerWithdrawAll`) already
sweeps any donation into the vault as shareholder value, so no funds are lost — it is a liveness
nuisance on a rare admin-gated operation.

## 5. General asks

- Full independent review of the async redeem-cycle state machine (commit/settle/claim/cancel,
  force-settle, deposit/mint gating during a cycle), accounting/NAV, and the min(raw,accounted)
  inventory recognition — beyond the specific deltas above.
- Report Critical/High/Medium/Low with concrete exploit traces and recommended fixes.
- EIP-170: note the Vault runtime margin is tight (~777 B) after this delta — flag any fix that
  would breach the 24,576 B limit.
