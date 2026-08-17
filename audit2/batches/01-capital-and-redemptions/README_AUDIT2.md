# Audit 2 — Batch 01 upload inputs

This directory supplies two paid review requests in the initial tranche.

| Task | Files | Scope |
|---:|---|---|
| 1 | `DeepYieldVaultB.audit2.flat.sol` | ERC-4626 asset/share accounting; lower/upper NAV; strategyless deposit/mint rejection even with an unlimited cap; strategy proposal, cancellation, bootstrap and timelock; paused synchronous exits; async requests, cancellation, claims, reserves, liabilities, and insolvency. Strategy implementation and live configuration are assumptions. |
| 2 | `DedicatedVaultStrategyAdapterV2.audit2.flat.sol` plus `FixedFeeSink.audit2.flat.sol`; raw `../../source/src/interfaces/IFeeSink.sol` | Combined fee flow from Strategy fee calculation through exact sink/treasury delivery: high-water basis, realized loss, partial sync/async exits, recovery, crystallization, `unremittedFee`, retry, treasury rotation, delta checks, and atomic rollback. Main implementation is context except where exact canonical behavior decides reachability. |

Do not submit `FixedFeeSink` as a standalone task. For task 2, use the actual
canonical Main and `FixedFeeSink` behavior as evidence rather than hypothetical
callback-capable or partially accepting replacements.

Each task should request exact locations, preconditions, a local failure
trace, severity rationale, and minimal remediation. Historical report claims
must be independently reproduced or rejected.
