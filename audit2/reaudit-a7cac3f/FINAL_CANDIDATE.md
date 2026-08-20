# Vault B — Final Re-Audit Candidate a7cac3f

Date: 2026-08-20

Source commit:
`a7cac3f790a7a803124f5033942d17fe65a6b390`

Audited parent:
`0241c37ae56192936c6074d7944bcae1a95cf880`

External report SHA256:
`3a6ea8d0c04a9a9c11b9459d0314c1643c25532a94c07b0c4717e18c11ac22f2`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- canonical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat is
included to make the deployed link target explicit. The Adapter is unchanged by
this successor and is included only to reproduce canonical migration and redeem
boundary assumptions; it is not a request for a second unpaid component audit.

## Remediation summary

- an empty queue cannot materialize an irreversible local commit through treasury
  deficit funding;
- the execution-loss cap is batch-denominated in preview and execution;
- an underfunded sub-economic full queue remains uncommitted and cancelable;
- force settlement burns only payout-covered shares and returns the uncovered
  remainder to the recorded owner;
- responsive guardian recovery uses healthy known-idle pricing;
- async pause, strategy-migration reentrancy, actual-balance liquidity checks,
  frozen commit thresholds and upper/lower NAV ordering are hardened;
- preview/execute boundaries, value-denominated residual protection, uncommitted
  claim authorization, malformed-return escrow, sub-minimum max views, zero-share
  deposits and aggregate-trigger retry are covered by directed tests;
- deferred old-graph handles block migration until reconciled.

The source handoff records the explicit policy verdicts for pause-time synchronous
exits, operational roles, exact direct-backing checks and the immutable recovery
probe budget.

## QA

- Exact Critical/High fail-before witnesses: 5 failures on parent, PASS after fix.
- Follow-up plus inherited delta matrix: 60 PASS / 0 FAIL / 2 existing SKIP.
- Stale-fixture adjudication matrix: 119 PASS / 0 FAIL / 0 SKIP.
- VaultB-wide regression: 1,066 PASS / 0 FAIL / 9 existing SKIP, 59 suites.
- Changed-source format, high/medium lint and diff-check: PASS.
- Exact parent/candidate method-selector maps are identical.
- Exact 41-entry parent storage prefix is identical; one internal counter is
  appended at slot 32.

## Runtime sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,544 B | 2,032 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `DedicatedVaultStrategyAdapterV2` | 13,029 B | 11,547 B |
| `VaultBDepositLib` | 8,949 B | 15,627 B |

Vault and Main retain the mandatory 2,000-byte engineering margin. Main source
and runtime are unchanged by this successor.

Production, deployment, roles, keys, balances, positions and prior public audit
branches were not changed. This package is review input, not release approval.
