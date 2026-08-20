# Vault B — Follow-up Re-Audit Candidate 896b855

Date: 2026-08-21

Source commit:
`896b85511a4296ce63f452b2412b8b37681274e7`

Audited parent:
`a7cac3f790a7a803124f5033942d17fe65a6b390`

External report SHA256:
`f4e3325a75bcccba638da4a6a6400fa50ddf190d262b86d5012c0cfd17f7cf66`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- canonical `DedicatedVaultStrategyAdapterV2` boundary.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main is canonical reachability context
only and is source-identical to the audited parent.

## Remediation Summary

- expired requests have bounded, permissionless release and a separately gated
  unresolved-handle abandonment path;
- migration from an unavailable strategy is pause- and timelock-gated and
  rejects direct old-source assets or unresolved requests;
- commit economics use the maximum of queue-open and live-supply bases;
- a full queue cannot cross the irreversible commit boundary while
  sub-economic;
- responsive recovery uses live settlement math and the execution-loss cap;
- unavailable recovery pays only spendable idle pro rata and burns only the
  covered share fraction;
- committed settlement initialization is restricted to the request owner or
  receiver, while later claims remain permissionless;
- pause coverage includes synchronous exits and async claims;
- synchronous redeem uses one asset price across funding and share burn;
- the pinned Main can materialize the recovery snapshot if the Adapter is
  unavailable;
- deposit cap zero is closed, cancellation requires an exact acknowledgement,
  and max views fail safe.

## QA

- A7 directed remediation: 45 PASS / 0 FAIL / 0 SKIP.
- Post-hardening focused matrix: 73 PASS / 0 FAIL / 2 intentional SKIP.
- Full regression: 1,725 PASS / 0 FAIL / 13 existing RPC/fork SKIP, 106 suites.
- Changed-source format, high/medium lint and diff-check: PASS.
- Main source parity against `a7cac3f`: PASS.
- Normalized Vault, Main and Adapter storage layouts: unchanged.
- Main method selectors: unchanged.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,283 B | 2,293 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,063 B | 11,513 B |
| `VaultBDepositLib` | 10,896 B | 13,680 B |

Vault and Main retain the mandatory 2,000-byte engineering margin. Main has
only 9 bytes above that internal floor and is frozen for further inline changes.

Production, deployment, roles, keys, balances, positions, keeper and prior
public audit branches were not changed. This package is review input, not
release approval.
