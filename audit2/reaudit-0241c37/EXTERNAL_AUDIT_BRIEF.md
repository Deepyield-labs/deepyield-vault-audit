# Audit 2 — Follow-Up Review: Vault Redemption and Strategy Migration

External links:

- `DeepYieldVaultB` with embedded linked-library source:
  https://raw.githubusercontent.com/Deepyield-labs/deepyield-vault-audit/2d20f19f76051b621ea82b4982875d61cee0641e/audit2/reaudit-0241c37/flat/DeepYieldVaultB.reaudit.flat.sol
- Deployed `VaultBDepositLib` link target:
  https://raw.githubusercontent.com/Deepyield-labs/deepyield-vault-audit/2d20f19f76051b621ea82b4982875d61cee0641e/audit2/reaudit-0241c37/flat/VaultBDepositLib.reaudit.flat.sol
- Canonical migration counterpart `DedicatedVaultStrategyAdapterV2`:
  https://raw.githubusercontent.com/Deepyield-labs/deepyield-vault-audit/2d20f19f76051b621ea82b4982875d61cee0641e/audit2/reaudit-0241c37/flat/DedicatedVaultStrategyAdapterV2.reaudit.flat.sol

Candidate: BNB Smart Chain, chain ID 56, pre-deployment.

Source commit:
`0241c37ae56192936c6074d7944bcae1a95cf880`.

Frozen package-content commit:
`2d20f19f76051b621ea82b4982875d61cee0641e`.

Audited parent:
`234e7f1d6948a1dee8ed2ce8090e90a380db2b97`.

Audit the linked `DeepYieldVaultB` flat file together with its deployed
`VaultBDepositLib` link target and the canonical
`DedicatedVaultStrategyAdapterV2` migration counterpart. Treat these three
files as one review boundary: the Vault delegates settlement and migration
checks into the library, while migration completes through the Adapter → Main
custody boundary.

Review synchronous and asynchronous redemption, queue aggregation and frozen
capacity, full-queue and threshold commitment, cancellation, claimable
liabilities, force settlement, failed-call rollback, deferred handle release,
strategy proposal/activation, allowance rotation, idle/donation migration,
fee crystallization, and accounting conservation.

Pay particular attention to:

- whether an underfunded full queue can settle at an idle cap instead of
  initiating the canonical Main unwind;
- the distinction between a genuinely unavailable strategy and a responsive
  strategy that never becomes withdrawal-ready after timeout;
- guardian + paused authorization for the latter case, while preserving
  permissionless recovery for a true external outage;
- fixed-gas commitment probes, the independent recovery gas reserve, and
  atomic rollback after late strategy/Main failures;
- the exact `MIN_REDEEM_SHARES` residual boundary;
- persistence and one-time release of genuine deferred redeem handles;
- frozen queue-cap changes and retry behavior after a deferred full-queue
  commit attempt;
- atomic strategy migration: fee crystallization, direct Main balance sweep,
  source-drained attestation, allowance revocation/grant, and rejection while
  LP inventory or queued withdrawals remain;
- donation and `unremittedFee` accounting during migration;
- callback ordering that snapshots the Vault before Main crosses an
  irreversible withdrawal-commit boundary.

`DedicatedVaultMainV2`, Venue, guards, execution adapters, keeper, and deploy
scripts are canonical reachability context only except where the supplied
Adapter calls Main. Do not perform unpaid component audits or a graph-wide
integration review outside the three supplied flat files.

For every finding provide exact flat/source locations, preconditions, a
concrete exploit or failure scenario, severity rationale, and minimal
remediation. Distinguish an exploitable canonical path from a policy or
future-integration concern.

Package SHA256:

- `DeepYieldVaultB.reaudit.flat.sol`:
  `0c21388d706f826743def338680ec2d959fd670c9a2c4da835b16ba59c8aaee2`
- `VaultBDepositLib.reaudit.flat.sol`:
  `4a796cefcc8d7fd6a4f477d45b8aaf59bf412b376e46c6f8888df9a8a965dcc4`
- `DedicatedVaultStrategyAdapterV2.reaudit.flat.sol`:
  `779ed7967f987e207fd17b2870277ca4ebf1c4d4dd9b5fa331213397204d88ff`

Author-side evidence: 1,642 PASS / 0 FAIL / 13 existing RPC or harness SKIP,
101 suites. Runtime margins are 2,036 B for Vault, 2,009 B for unchanged Main,
11,547 B for Adapter, and 17,282 B for the linked library. This evidence and a
clean external report do not authorize deployment or release.
