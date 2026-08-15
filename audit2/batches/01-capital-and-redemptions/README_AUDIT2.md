# Audit 2 — Batch 01 upload queue

This directory contains **three separate paid tasks**, not one combined audit.
For each request, upload only the named flat and use the matching narrow scope
below. Do not require the reviewer to audit another flat.

| Task | File | Scope and residual handoff |
|---:|---|---|
| 1 | `DeepYieldVaultB.audit2.flat.sol` | ERC-4626 asset/share accounting and async requests, cancellation, claims, claimable-reserve isolation, liabilities, and insolvency. Strategy implementation and live configuration are assumptions. |
| 2 | `FixedFeeSink.audit2.flat.sol` | Non-custodial forwarding, treasury proposal/timelock, balance deltas, and recipient failure. Vault/adapter accounting is out of scope. |
| 3 | `DedicatedVaultStrategyAdapterV2.audit2.flat.sol` | Vault/Main bridge, fee basis, deferred or under-pulled fee remittance, withdrawal/callback ordering, and transfer deltas. Main and `MainV2*` code present only through concrete-type flattening is context for task 4, not part of this task. Vault/Main implementation details are out of scope. |

Each task should ask for preconditions, exploit or failure scenario, severity
rationale, and minimal remediation. A Vault/Strategy/Main integration review,
if wanted, is a separately funded task after the individual reviews.
