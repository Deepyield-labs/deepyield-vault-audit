# Audit 2 — Delta re-audit package (remediation of accepted findings)

**Already-audited baseline:** source commit `27e1e617296dde8c0dc1ff621eeec3a3b10b409d`,
frozen package `4f33daed2a4def3ac1109ee8ce7a6d42d6500b96`.
**Remediation head (source):** `832dee1`.
**Chain:** BNB Smart Chain, chain ID 56, pre-deployment.

Only two first-party contracts changed since the audited baseline. This package ships
their re-flattened sources for a focused delta review. Everything else is byte-identical
to the audited `27e1e617` package.

## Changed contracts

### 1. `DeepYieldVaultB` (includes linked `VaultBDepositLib`)
Flat: `flat/DeepYieldVaultB.reaudit.flat.sol`
SHA-256: `1d92ed83020a4558e0cb87ba52d6d151c72016c806bec7747e158f6bfad70500`

Changes vs `27e1e617` (async redeem cycle):
- Full-queue commit trigger preserves the economic floor and prevents a sub-economic
  full queue from forcing Main's irreversible unwind.
- The commit threshold tracks genuine supply growth (no stale queue-open base).
- Associated library/accounting adjustments in `VaultBDepositLib`.

### 2. `PancakeV3MasterchefVenue`
Flat: `flat/PancakeV3MasterchefVenue.reaudit.flat.sol`
SHA-256: `d3dff0aded4b19fccdacece7ee287112b3a0980b7e35d7180ca53be54fa9c78d`

Change vs `27e1e617`:
- `open()` now returns to the controller ONLY the mint's unused approved legs
  (`assetAmount - amount0Used`, `pairedAmount - amount1Used`) instead of sweeping the
  venue's entire balance. A third-party token donation to the fixed venue address is no
  longer swept into Main, so it cannot corrupt Main's balance-delta consumption measure in
  `MainV2Open.openPosition` (the prior open-path griefing/DoS surface).

## Requested scope

Review ONLY the delta vs `27e1e617` in these two files: correctness of the two
remediations, and any regression they introduce (redeem-cycle economics, open/close
accounting, donation handling, rollback). `DedicatedVaultMainV2`, adapters, guards and
strategy are canonical reachability context only. For every finding give exact
flat/source locations, preconditions, exploit/failure trace, severity rationale, and
minimal remediation.

Compilation: solc 0.8.24, via_ir, optimizer 200, evm cancun. Both flats compile
standalone.
