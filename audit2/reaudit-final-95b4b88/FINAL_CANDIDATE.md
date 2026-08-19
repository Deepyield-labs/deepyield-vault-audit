# Audit 2 — Final remediation candidate (post-adjudication)

**Audited baseline:** source `27e1e617296dde8c0dc1ff621eeec3a3b10b409d`, package `4f33daed2a4def3ac1109ee8ce7a6d42d6500b96`.
**Final candidate (source):** `95b4b88`.
**Chain:** BNB Smart Chain, chain ID 56, pre-deployment.

All eight external component reviews have been adjudicated. The net material remediation
is TWO contracts changed vs the audited baseline; every other contract is byte-identical to
`27e1e617`. This package ships the two changed contracts re-flattened at the final
candidate for a final / integration review.

## Changed contracts

### DeepYieldVaultB (includes linked VaultBDepositLib)
`flat/DeepYieldVaultB.reaudit.flat.sol` — SHA-256 `1d92ed83020a4558e0cb87ba52d6d151c72016c806bec7747e158f6bfad70500`
Redeem-cycle remediation: full-queue commit trigger preserves the economic floor (a
sub-economic full queue cannot force Main's irreversible unwind); the commit threshold
tracks genuine supply growth. (Byte-identical to the earlier delta package already under
component re-audit.)

### PancakeV3MasterchefVenue
`flat/PancakeV3MasterchefVenue.reaudit.flat.sol` — SHA-256 `ee14c9757eba9ff85ccad19b35fbce1e439ff650f4e3bf3717bbba24a8e0f79d`
`open()` returns to the controller only the mint's unused approved legs instead of sweeping
the venue's whole balance, so a third-party donation to the fixed venue address cannot
corrupt Main's balance-delta consumption measure in `MainV2Open.openPosition`. (The M2 code
was already re-audit-confirmed at flat `d3dff0ad`; this flat differs from it only by a
corrected explanatory comment — no behavior change.)

## Adjudication outcome for the rest of the graph
Main M1/M3/M4, all CakeGuard, and all adapter findings were adjudicated as intended-design /
policy / trusted-role / bounded / rejected — no code change. `DedicatedVaultMainV2`, the
adapters and guards are byte-identical to `27e1e617`.

## Requested scope
Whole-graph / integration review at the final candidate, focusing on how the two changed
contracts interact with the unchanged Main / adapters / guards (redeem-cycle economics,
open/close/harvest accounting, donation handling, recovery, rollback). For every finding:
exact flat/source locations, preconditions, exploit/failure trace, severity, minimal
remediation. Compilation: solc 0.8.24, via_ir, optimizer 200, evm cancun.
