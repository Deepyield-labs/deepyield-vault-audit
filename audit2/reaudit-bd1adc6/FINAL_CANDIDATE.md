# Vault B — ae03b35 Critical/High Follow-up Candidate bd1adc6

Date: 2026-08-21

Source commit:
`bd1adc6af9afd5143c7851d93e53d0b0a6886ee0`

Audited parent:
`ae03b355404045d2e8df03ff3b80d957951b7a01`

External report:
`https://bafkreihktxmf5vkdce2n35hleirogaakivdm4gxee2nuludkloj5ipmfvm.ipfs.community.bgipfs.com/`

External report SHA-256:
`ea9dd85ed5431134ddf4eb2222e3000a4546ce1ae4269b45d06a5b93d43d85ab`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

## Scope

This package contains the complete changed production scope:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- unchanged canonical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main, Strategy Adapter, Venue,
guards, execution adapters, deploy wiring, and keeper are source-identical to
the audited parent.

## Critical / High Remediation Summary

- an initialized residual batch whose Strategy becomes incompletely readable
  can draw only its live-supply-pro-rata share of spendable idle;
- ordinary cancel and receiver mutation use bounded Adapter plus direct Main
  commitment witnesses and fail closed when the direct witness is unresolved;
- an expired unresolved request may proceed only as a deferred handle through
  the pre-existing pause plus matured-strategy-proposal disaster gates;
- `redeemCycleCommitted()` cannot brick an empty queue on Adapter outage and
  uses the hardened direct witness whenever requests are live;
- force-settlement health classification checks every pricing/loss getter it
  needs, using idle-only pro-rata recovery if any secondary observation fails;
- three-tier cancellation and old-Strategy migration probes have fixed gas and
  bounded return decoding, preserving gas for local completion;
- emergency migration still requires the independently pinned old custody
  source to be empty. The report's suggested bypass was rejected because it
  could orphan shareholder backing.

## Finding Disposition

- Findings 1–5 and Finding 6's gas-grief mechanism are closed by code and
  exact fail-before/pass-after tests.
- Finding 6's proposed nonzero-old-source emergency bypass is rejected as
  unsafe; custody conservation remains unconditional.
- Findings 7–10 retain their previously documented near-total-exit dust,
  bounded queue/product, direct-backing admission-DoS, and guardian emergency
  policy dispositions.
- Findings 11, 12, and 18 require a noncanonical token. Canonical BSC USDT
  identity/behavior is a mandatory deployment gate; generic-token support is
  not claimed.
- Findings 13–20 remain bounded Strategy, journal, integration, governance,
  pause, and strict/tolerant recovery boundaries except for the bounded probes
  added on the confirmed Critical/High paths.
- Findings 21–25 remain informational or sub-material availability, rounding,
  bootstrap-delay, and hygiene observations.

The source handoff contains the complete per-finding ledger and rationale.

## QA

- Exact fail-before on `ae03b35`: 29 PASS / 6 expected FAIL / 0 SKIP.
- Job-next inherited directed file: 36 PASS / 0 FAIL / 0 SKIP.
- Job-next plus governed-abandonment compatibility: 40 PASS / 0 FAIL / 0 SKIP.
- Extended affected-component matrix: 291 PASS / 0 FAIL / 0 SKIP, 24 suites.
- Full regression: 1,820 PASS / 0 FAIL / 13 existing RPC/fork SKIP, 115 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Vault ABI, method selectors, and all 42 normalized storage entries are
  identical to `ae03b35`.
- Main and every other out-of-scope production component listed above remain
  source-identical to `ae03b35`.
- Three independent re-flatten passes: 3/3 files byte-identical on every pass.

The 13 skips are not represented as fork PASS.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,542 B | 2,034 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `VaultBDepositLib` | 11,603 B | 12,973 B |

Vault and Main retain the mandatory 2,000-byte engineering margin. Main has
only 9 bytes above that internal floor. Both runtimes are frozen; any later
production change must first remove equivalent runtime or move logic into an
already-linked library and reproduce the complete size gate.

## Residual Boundary

Unavailable Strategy capital has no trustworthy live value. Recovery splits
only known spendable idle pro-rata, burns only the paid fraction, and keeps
unknown deployed claims represented by live shares. Ordinary unresolved
commitment fails closed; only the separately delayed and paused disaster path
may journal an expired unresolved handle.

Production, deployment, roles, keys, balances, positions, keeper, and prior
public audit branches were not changed. This package is review input, not
release approval.
