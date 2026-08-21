# Vault B — Follow-up Re-Audit Candidate 8e38303

Date: 2026-08-21

Source commit:
`8e383035da5052081685b0e432b0d827656dbb3c`

Audited parent:
`896b85511a4296ce63f452b2412b8b37681274e7`

External report:
`https://bafkreie3ucuqudayy5fkagypwrju5dpqotwas7lrap3vbsi76wfjwbaixm.ipfs.community.bgipfs.com/`

External report SHA-256:
`9ba0a90a0c18c74aa01b0fb4534e8df074ec097d7103f750c91ff58a9b0408bb`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- unchanged canonical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main and the canonical Strategy
Adapter are source-identical to the audited parent.

## Remediation Summary

- a missing local recovery snapshot now proves Strategy or pinned Main
  commitment and includes responsive Strategy NAV; only a genuine NAV outage
  falls back to spendable idle;
- timeout recovery remains available for the unclaimed residual after the first
  request initializes settlement;
- the residual keeps its already-frozen unpaid entitlement and burns only the
  share fraction covered by available idle;
- a responsive but stalled residual still requires guardian pause, while a
  genuinely unavailable Strategy remains permissionless recovery;
- successful `prepareMigration()` attestation can no longer bypass the
  independent zero-balance check on the pinned old asset source;
- threshold and queue comments now state the retained live-supply anti-dilution
  invariant and bounded sybil-fan-out residual accurately.

## Finding Disposition

- H-1: canonical Main-before-Vault reachability premise rejected; fallback
  hardened as defense in depth.
- H-2: fixed for initialized outstanding residuals.
- M-3: live-supply threshold deliberately retained as an anti-dilution
  invariant.
- M-4: bounded residual; no new fee/minimum-exit economics introduced.
- L-5: fixed with an unconditional pinned-source balance postcondition.
- L-6 through L-10: documented deployment, governance, rounding, or operational
  residuals; no unrelated authority redesign is included.

## QA

- New report-directed scenarios: 14 PASS / 0 FAIL / 0 SKIP.
- Extended affected-component matrix: 183 PASS / 0 FAIL / 0 SKIP.
- Full regression: 1,739 PASS / 0 FAIL / 13 existing RPC/fork SKIP, 108 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Main, Strategy Adapter, and async Strategy interface source parity against
  `896b855`: PASS.
- Normalized Vault storage layout and method selectors: unchanged.
- Three independent re-flatten passes: 3/3 files byte-identical on every pass.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,546 B | 2,030 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,063 B | 11,513 B |
| `VaultBDepositLib` | 11,472 B | 13,104 B |

Vault and Main retain the mandatory 2,000-byte engineering margin. Vault has
only 30 bytes and Main only 9 bytes above that internal floor; both must be
treated as frozen for further inline changes.

Production, deployment, roles, keys, balances, positions, keeper, and prior
public audit branches were not changed. This package is review input, not
release approval.
