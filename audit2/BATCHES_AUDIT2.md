# Audit 2 — three-review initial plan

The package contains nine deterministic flat units, but the currently
requested external tranche is exactly three paid reviews. No request is
submitted or authorized by this package.

| Paid task | Upload inputs | Review boundary |
|---:|---|---|
| 1 | Batch 01: `DeepYieldVaultB.audit2.flat.sol` | Vault-only ERC-4626 accounting, strategyless admission gate, strategy timelock/bootstrap, paused exits, async queue, cancellation, claims, reserves, liabilities, and insolvency |
| 2 | Batch 01: `DedicatedVaultStrategyAdapterV2.audit2.flat.sol`, `FixedFeeSink.audit2.flat.sol`, plus raw `IFeeSink.sol` | One combined fee-flow unit: high-water basis, realized loss and recovery, sync/async withdrawals, fee crystallization, deferred `unremittedFee`, retry, exact deltas, treasury rotation, and failure atomicity |
| 3 | Batch 02: `DedicatedVaultMainV2.audit2.flat.sol` | Main lifecycle and its linked `MainV2*` libraries: funding, open/close/recovery, inventory, readiness, jobs, liquidation, emergency capacity, and rollback |

Do not submit `FixedFeeSink` alone for a third time. Its meaningful security
boundary is the combined Strategy/FeeSink flow in task 2.

Historical reports are hypotheses, not accepted facts or fixes. Reachability
must be re-derived against this exact candidate and its canonical graph. In
particular, use the real `FixedFeeSink`, Main, guards, adapters, and immutable
identity wiring as evidence; do not establish a finding only by replacing a
pinned component with a hypothetical malicious implementation. Explicit
trusted-admin misconfiguration should be classified separately from an
unprivileged exploit.

Every finding should include exact flat and raw-source locations, concrete
preconditions, a local unit-test or failure trace, severity rationale, and
minimal remediation. This is authorized defensive, pre-deployment review;
there is no live-system interaction in scope.

## Packaged but not in the initial three requests

The following five flat units remain available for later separately
authorized review: `PancakeV3MasterchefVenue`, `VaultBPriceGuard`,
`BoundedPancakeExecutionAdapterV2`, `VaultBCakePriceGuard`, and
`BoundedPancakeRewardAdapterV2`. Packaging them does not create an audit order.

A graph-wide integration assessment, if commissioned later, is a distinct
funded task. It should reconcile component reports rather than silently expand
one of the three scopes above.
