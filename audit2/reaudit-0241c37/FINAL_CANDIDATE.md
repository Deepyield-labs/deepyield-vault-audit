# Vault B — Final Re-Audit Candidate 0241c37

Date: 2026-08-20

Source commit:
`0241c37ae56192936c6074d7944bcae1a95cf880`

Audited parent:
`234e7f1d6948a1dee8ed2ce8090e90a380db2b97`

External report SHA256:
`64fcf9b511b18ee60d35175544a169ba63fe6070847850cb7eccaf94429ace03`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`via_ir=true`, optimizer 200 runs. Pre-deployment.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- canonical `DedicatedVaultStrategyAdapterV2` migration counterpart.

The Vault flat already embeds the linked library source, but the standalone
library flat is included to make the deployed link target explicit. The Adapter
flat is mandatory because strategy migration is now an atomic Vault → Adapter →
Main custody handshake; auditing Vault alone would miss that boundary.

## Remediation summary

- H-1: underfunded healthy full queues unwind instead of burning at idle cap;
- H-2: responsive-never-ready timeout recovery requires guardian pause, while
  genuinely unavailable strategy recovery stays permissionless;
- H-3: exactly-minimum residual holders no longer enter the full-exit bypass;
- M-1: rejected in the canonical callback graph and covered by an ordering test;
- M-2/M-4: canonical atomic migration attestation and idle/donation sweep;
- M-3: fixed-gas static probe with a separate recovery gas reserve;
- L-1/L-2: persisted deferred-handle membership and coherent frozen queue cap;
- L-3/L-4/L-5/L-6/L-7: corrected or explicitly documented policy boundaries.

## QA

- Directed finding/queue/B10 matrix: 78 PASS / 0 FAIL / 2 existing SKIP.
- Full source regression: 1,642 PASS / 0 FAIL / 13 existing SKIP, 101 suites.
- Changed-source format, high/medium lint and diff-check: PASS.
- All three flattened files compile standalone for ABI/type checking.
- Re-flatten equality and package checksums: required and recorded before publish.

## Runtime sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,540 B | 2,036 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,029 B | 11,547 B |
| `VaultBDepositLib` | 7,294 B | 17,282 B |

## Compatibility

- All 109 pre-existing Vault methods remain; three views/getters are additive.
- All 46 pre-existing Adapter methods remain; `prepareMigration()` is additive.
- All 40 pre-existing Vault storage rows retain label, slot and offset; one
  mapping is appended at slot 31.
- Adapter storage is unchanged.
- Main production source and runtime are unchanged by this remediation.

Production, deployment, roles, keys, balances, positions and prior public audit
branches were not changed. This package is review input, not release approval.
