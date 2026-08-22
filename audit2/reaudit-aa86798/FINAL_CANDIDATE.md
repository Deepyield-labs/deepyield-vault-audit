# Vault B — bd1adc6 Follow-up Candidate aa86798

Date: 2026-08-22

Source commit:
`aa86798f2dedec597a0a1bb9089e7faa0703073f`

Production remediation commit:
`a13a1cc39e59ebe80cbbc79b03a5ae1894989b67`

Audited parent:
`bd1adc6af9afd5143c7851d93e53d0b0a6886ee0`

External report:
`https://bafkreihwecovvwjftmqnge6nedcm3c2cgcuqk2i35skenc2bhbw66jbepy.ipfs.community.bgipfs.com/`

External report SHA-256:
`f6208715ff3fe097432e359a128a7a86b01abeb3b0649a639a7eacb88e9debec`

Chain / compiler: BNB Smart Chain (chain ID 56), Solidity 0.8.24,
`evm_version=cancun`, `via_ir=true`, optimizer 200 runs. Pre-deployment and not
deployed.

The final source commit is a test-only successor of the production remediation
commit. The two commits have byte-identical `src/`; the successor updates six
legacy assertions that required behavior intentionally removed by the queue and
force-settlement hardening.

## Scope

This package contains the complete changed production scope and its canonical
boundary context:

- `DeepYieldVaultB`;
- linked `VaultBDepositLib`;
- source-identical `DedicatedVaultStrategyAdapterV2` boundary context.

The Vault flat embeds the linked library source. The standalone library flat
makes the deployed link target explicit. Main, Strategy Adapter, Venue, guards,
execution adapters, deploy wiring, and keeper are source-identical to the
audited parent.

## Critical / High Remediation Summary

- pending queue identity is owner-only, so receiver fan-out cannot buy multiple
  seats; a new seat must satisfy the live cap/supply-scaled minimum;
- a live cap increase takes effect immediately, while aggregation cannot renew
  a request's age;
- after pause plus a matured strategy proposal, an uncommitted request can be
  cancelled early and a fully dead canonical handle can be journaled, then
  released or explicitly abandoned before migration;
- known-idle force settlement burns the complete escrow, fixes only the batch's
  pro-rata claim on provable shareholder idle, adds the complete earmarked
  protocol credit, and never returns shares able to reclaim the same idle;
- normal over-cap settlement remains rejected, while a responsive cycle that
  stays blocked for seven days has a guardian-paused known-idle resolution;
- an unresponsive old strategy with direct pinned-source backing requires two
  separate matured actions: quarantine and allowance revocation first, then a
  second full delay before explicit source write-off;
- any responsive NAV or successful migration attestation keeps nonzero old
  source backing fail-closed;
- default admin cannot grant itself guardian authority; guardian is
  self-administered;
- paused claims are allowed only after force settlement is initialized;
- dust cannot bypass the loss cap unless the request is the genuine full-supply
  exit, and EIP-7702 delegation-designator asset sources are rejected.

## Finding Disposition

- H-1 through H-5, M-6, M-8, M-9, L-11, and L-15 are closed by code and exact
  adversarial tests.
- M-7 remains a bounded recovery residual. The canonical Main → Adapter → Vault
  callback snapshots before Main commitment atomically. Permissionless repair
  of a missing local snapshot remains only for inconsistent or legacy state and
  requires a positive commitment witness plus responsive full NAV.
- M-10 remains the standard ERC-4626 integration boundary: `deposit` and `mint`
  have no user slippage argument. Conservative upper-NAV pricing, a pinned
  source-balance floor, and deposit-readiness gates remain on-chain.
- L-12 is the intentional external linked-library boundary required by the
  EIP-170 split; canonical Main endpoints authenticate the pinned Vault.
- L-13, L-14, and L-16 retain their documented bootstrap-delay, strict outage
  view, and canonical Strategy-liquidity boundaries.
- L-17 is mitigated by the two-day pause/proposal journal path instead of a
  renewable thirty-day request veto.

No Critical finding existed in the input report. Author-side remediation QA
found no unresolved Critical or High issue in this scoped candidate. This is
not a guarantee about the result of an independent audit.

## QA

- Focused high-risk migration/queue matrix: 50 PASS / 0 FAIL.
- Added Low-hardening and strategy-gate subset: 30 PASS / 0 FAIL.
- Affected-component matrix: 331 PASS / 0 FAIL / 2 existing skips.
- Full clean detached regression at exact commit `aa86798`: **1,872 PASS / 0
  FAIL / 13 existing RPC/fork SKIP**, 119 suites.
- Changed-source format, high/medium lint, and diff-check: PASS.
- Vault external method selectors: 112 → 112, byte-for-byte identical.
- Every prior storage label, slot, offset, and type is semantically identical.
  One append-only field was added: `_emergencyStrategySourceWriteOffScheduled`,
  slot 33, offset 0, `bool`.
- Vault runtime links only `VaultBDepositLib`; no new linked target exists.
- Three independent re-flatten passes reproduced all three package files
  byte-for-byte.

The skips are not represented as fork PASS.

## Runtime Sizes

| Contract | Parent | Candidate | Delta | EIP-170 margin |
|---|---:|---:|---:|---:|
| `DeepYieldVaultB` | 22,542 B | 22,561 B | +19 B | 2,015 B |
| `DedicatedVaultMainV2` | 22,567 B | 22,567 B | 0 B | 2,009 B |
| `VaultBDepositLib` | 11,603 B | 13,056 B | +1,453 B | 11,520 B |

Vault and Main retain the mandatory 2,000-byte engineering margin, but only by
15 and 9 bytes respectively. Both tight runtimes are frozen. Any later inline
change must first remove equivalent runtime or move logic into an already-linked
library and reproduce the complete size gate.

## Release Boundary

Production, deployment, roles, keys, balances, positions, keeper, prior public
audit branches, and prior packages were not changed. This package is review
input, not release approval. Deployment remains blocked pending an independent
re-audit and the remaining operational release gates.
