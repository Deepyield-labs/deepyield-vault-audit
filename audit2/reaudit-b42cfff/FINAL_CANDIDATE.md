# Vault B — Job 703 Follow-up Re-Audit Candidate b42cfff

Date: 2026-08-21

Source commit:
`b42cfff1772b76b3980734fee398081d469240be`

Audited parent:
`8e383035da5052081685b0e432b0d827656dbb3c`

External report:
`https://bafkreibi4m6zb7xevzaai5ikmdtq5au7fzfxzxxpm4uwh7pk2lxhsco4wu.ipfs.community.bgipfs.com/`

External report SHA-256:
`28e33d90fee4ae4004750a60e70e829f2e4b7cdeef672963fdead2ee7909dcb5`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- unchanged canonical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main, the canonical Strategy Adapter,
and the async Strategy interface are source-identical to the audited parent.

## Remediation Summary

- unavailable-Strategy recovery retains the frozen full batch entitlement as
  the burn denominator, pays only available idle, burns only the covered share
  fraction, and returns the uncovered shares;
- the 5% economic commit threshold follows live supply in both directions, so
  departed transient capital cannot keep a queue permanently below threshold;
- an aggregated redeem top-up refreshes the slot expiry time;
- a missing local snapshot requires responsive full Strategy NAV and fails
  closed rather than permanently latching idle-only NAV as the loss-cap basis;
- a truthy `prepareMigration()` hook cannot override a contradictory responsive
  non-zero `estimatedTotalAssets()` observation; the pinned source must also
  remain empty.

## Finding Disposition

- C-1, H-4, H-5, M-4, M-5, and the C-1-dependent treasury-credit leakage are
  closed by code and directed fail-before/pass-after tests.
- H-1 is rejected for the canonical atomic Main/Vault callback graph; the 2%
  execution-loss cap remains deliberate policy and cannot be waived by a
  guardian pause.
- H-2 is rejected for the dedicated pinned Main source: its direct balance is
  canonical backing and the floor prevents dilution from under-reporting.
- H-3's extraction path is rejected by the canonical Main commitment and
  direct-cancellation gates; receiver updates do not clear the Main handle.
- H-6 remains a bounded product/economic residual. The sub-economic final slot
  reverts atomically at `max-1`, so the report's claimed full-cap deposit block
  is not reached.
- M-1, M-2, M-3, and M-6 retain their documented canonical or emergency-policy
  dispositions. Low/informational items remain bounded rounding, governance,
  deployment-token, or Strategy trust-boundary observations.

## QA

- New Job 703 directed scenarios: 14 PASS / 0 FAIL / 0 SKIP.
- Extended affected-component matrix: 267 PASS / 0 FAIL / 2 intentional SKIP.
- Full regression: 1,753 PASS / 0 FAIL / 13 existing RPC/fork SKIP, 110 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Main, Strategy Adapter, and async Strategy interface source parity against
  `8e38303`: PASS.
- Normalized Vault storage layout and method selectors: unchanged.
- Three independent re-flatten passes: 3/3 files byte-identical on every pass.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,565 B | 2,011 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,063 B | 11,513 B |
| `VaultBDepositLib` | 11,384 B | 13,192 B |

Vault and Main retain the mandatory 2,000-byte engineering margin, but only by
11 and 9 bytes respectively. Both runtimes are frozen; any later production
change must first move existing logic to a linked library.

Production, deployment, roles, keys, balances, positions, keeper, and prior
public audit branches were not changed. This package is review input, not
release approval.
