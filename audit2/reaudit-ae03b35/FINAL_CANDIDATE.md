# Vault B — Job 707 Follow-up Re-Audit Candidate ae03b35

Date: 2026-08-21

Source commit:
`ae03b355404045d2e8df03ff3b80d957951b7a01`

Audited parent:
`b42cfff1772b76b3980734fee398081d469240be`

External report:
`https://bafkreifg6gcc43wsjrp636bf4n2ui75fssvxwvu4ujtnje2lrxsz376roa.ipfs.community.bgipfs.com/`

External report SHA-256:
`a6f1842e6ed24c5fedf825e375447fa594ab7b569ca266d4934b8de59dffd170`

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

## Remediation Summary

- unavailable-Strategy recovery preserves the frozen full batch entitlement
  as its burn denominator but caps its spendable-idle draw at the batch's
  supply-pro-rata share of current idle;
- only the paid fraction burns, while all uncovered shares return live with
  their claim on later-recovered deployed capital;
- owner cancellation and receiver mutation now consult responsive direct Main
  commitment when the Adapter witness is false or unavailable;
- a fully unavailable external witness does not falsely commit a local cycle,
  and cancellation must still release the canonical withdrawal handle
  atomically.

## Finding Disposition

- Finding 1 (disproportionate idle draw) is closed by code and exact numerical
  fail-before/pass-after coverage.
- Finding 2 (weaker owner-mutation commitment witnesses) is closed as
  defense-in-depth at the canonical Adapter/Main boundary.
- Finding 3's proposed live-NAV loss-cap basis is rejected: the frozen basis
  deliberately separates execution loss from underlying NAV movement.
- Finding 4 is rejected as trusted treasury over-funding/donation behavior;
  deficit sizing remains an operational responsibility.
- Finding 5 remains a bounded queue/product residual. Removing recoverable
  sybil identities requires a fee or minimum-exit policy.
- Findings 6–10 retain their documented minimum-deposit, strict-view outage,
  bounded dust, role-delegation, and emergency-pause policy dispositions.

## QA

- Job 707 fail-before: 29 PASS / 2 expected FAIL / 0 SKIP.
- Job 707 inherited directed file after remediation: 31 PASS / 0 FAIL / 0 SKIP.
- Extended affected-component matrix: 260 PASS / 0 FAIL / 1 intentional
  archive-fork SKIP.
- Full regression: 1,784 PASS / 0 FAIL / 13 existing RPC/fork SKIP, 112 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Vault ABI, method selectors, and normalized storage layout: unchanged from
  `b42cfff`.
- Main and every other out-of-scope production component listed above remain
  source-identical to `b42cfff`.
- Three independent re-flatten passes: 3/3 files byte-identical on every pass.

## Runtime Sizes

| Contract | Runtime | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,570 B | 2,006 B |
| `DedicatedVaultMainV2` | 22,567 B | 2,009 B |
| `VaultBDepositLib` | 11,508 B | 13,068 B |

Vault and Main retain the mandatory 2,000-byte engineering margin, but only by
6 and 9 bytes respectively. Both runtimes are frozen; any later production
change must begin with linked-library extraction or equivalent runtime removal
and must reproduce the complete size gate.

## Residual Boundary

An unavailable Strategy cannot provide a trustworthy current value for
deployed capital. The recovery rule therefore splits only known spendable idle
pro-rata, burns only the paid fraction, and represents every unknown deployed
claim with live shares. It is a bounded liquidity recovery rule, not a
universal fair-value oracle.

Production, deployment, roles, keys, balances, positions, keeper, and prior
public audit branches were not changed. This package is review input, not
release approval.
