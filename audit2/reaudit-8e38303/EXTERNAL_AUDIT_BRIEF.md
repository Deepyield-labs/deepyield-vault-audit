# Audit 2 — DeepYieldVaultB Follow-up Re-Audit

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/4435099ed2cda3bb169001d634eb34be5568d260/audit2/reaudit-8e38303/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `8e383035da5052081685b0e432b0d827656dbb3c`, package
`4435099ed2cda3bb169001d634eb34be5568d260`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting and the asynchronous redeem
cycle: request admission, economic and full-queue commit, snapshot
materialization, settlement initialization, claim, cancellation, receiver
update, expiry, deferred-handle release, and unavailable-strategy recovery.

Pay particular attention to recovery when canonical Main has committed but the
Vault snapshot is missing; the distinction between responsive Strategy NAV and
idle-only outage fallback; execution-loss-cap basis; recovery of the unclaimed
residual after a first claim fixed the cycle price; partial payout, proportional
share burn, and returned shares; guardian-paused recovery from a responsive but
permanently unready handle; claimable-liability exclusion; and rollback or
denial-of-service paths.

Also review migration from an old Strategy whose `prepareMigration()` returns
true while its independently pinned asset source still holds backing. Confirm
that the source-balance postcondition cannot be bypassed. Reassess the retained
live-supply commit threshold and bounded sybil queue-fan-out as explicit design
residuals rather than assuming they were removed.

The linked `VaultBDepositLib`, Strategy/Main implementations, live
configuration, and graph-wide integration are context and out of scope except
where their boundary assumptions are embedded in the linked Vault flat. Do not
perform unpaid component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions,
an exploit or failure path, severity rationale, and a minimal remediation.
