# Vault B — aa86798 Safe-Recovery Candidate f4ff567

Date: 2026-08-22

Source / production remediation commit:
`f4ff567689150d52a8e9b18cd05dc95a31931e0d`

Audited parent:
`aa86798f2dedec597a0a1bb9089e7faa0703073f`

External report:
`https://bafkreic65be7ns5mrm4sizva3v347jvvibvndk7ee73e6yfx6msfaklyra.ipfs.community.bgipfs.com/`

External report SHA-256:
`5ee849f6cbac8b392466a0dd77cfa6b5406ad1abe427f64f60b7f32450297888`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

## Scope

This package contains the complete changed production scope and its canonical
boundary context:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- source-identical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main, Strategy Adapter, Venue, guards,
execution adapters, deploy wiring, keeper, and production state are unchanged.

## Critical / High Remediation Summary

The prior timeout path tried to price claims while deployed value or loss
telemetry was unavailable. The replacement is deliberately value-neutral:

- delayed recovery creates no cash entitlement and burns no shares;
- every outstanding request becomes cancelled when claimed and receives all of
  its escrowed shares back;
- late-recovered assets remain NAV shared by all live shares;
- responsive-but-over-cap recovery requires pause plus guardian authority;
- unavailable or inconsistent secondary Strategy getters cannot block the
  bounded commitment check or local share return;
- unreleased canonical handles are journaled for gated reconciliation;
- synchronous `withdraw` / `redeem` use spendable idle only and cannot trigger a
  post-pricing Strategy unwind;
- migration's independent Strategy NAV probe receives a one-million-gas budget;
- `GUARDIAN_ROLE` is recoverable through the delayed default-admin authority.

Healthy ready-cycle settlement, its execution-loss cap, and ordinary queue
commitment are unchanged.

## QA

- Critical/High directed subset: 56 PASS / 0 FAIL / 0 SKIP.
- Expanded Vault B matrix: 1,270 PASS / 0 FAIL / 9 existing fork/RPC SKIP, 77 suites.
- Full repository regression: **1,884 PASS / 0 FAIL / 13 existing fork/RPC SKIP**,
  120 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Vault external method selectors: byte-for-byte identical to `aa86798`.
- Vault semantic storage labels, slots, offsets, and types: identical to `aa86798`.
- Main source: byte-for-byte identical to `aa86798`.
- Vault runtime links only `VaultBDepositLib`; no new linked target exists.

The skips are not represented as fork PASS.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,257 B | 2,319 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,063 B | 11,513 B |

Vault and Main retain the mandatory 2,000-byte engineering margin. Main remains
tight and must not receive another inline change without first recovering size.

## Explicit Residuals

- A timed-out request receives no immediate cash; it receives all shares and may
  re-enter the queue after the canonical Strategy recovers.
- Recovery liveness still requires enough transaction gas for the bounded
  commitment probe and tolerant handle-release tiers.
- Medium/Low findings in the source report remain re-audit scope unless their
  mechanism disappeared as a direct consequence of the feature reduction.
- Archive-fork tests remain a deployment gate.

## Release Boundary

Production, deployment, roles, keys, balances, positions, keeper, prior public
audit branches, and prior packages were not changed. This package is review
input, not release approval. Deployment remains blocked pending independent
re-audit and operational release gates.
