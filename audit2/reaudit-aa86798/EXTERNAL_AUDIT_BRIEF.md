# Audit 2 — DeepYieldVaultB Follow-up Re-Audit

Pinned file:
https://github.com/Deepyield-labs/deepyield-vault-audit/blob/622977421c422b72c360929f35f78ef97f0bc5a2/audit2/reaudit-aa86798/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `aa86798f2dedec597a0a1bb9089e7faa0703073f`, package
`622977421c422b72c360929f35f78ef97f0bc5a2`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting and the asynchronous redeem
cycle: request admission, owner-only queue identity, aggregation, receiver
update, economic and full-queue commit, settlement initialization, claim,
cancellation, expiry, deferred-handle release, and unavailable-strategy
recovery.

Pay particular attention to live cap and supply changes after queue admission,
the cap-scaled minimum for a new seat, receiver fan-out, request timestamp
renewal, and atomic behavior when the final economic seat commits. Confirm that
an attacker cannot reserve multiple bounded queue slots through receiver
variation or preserve an uneconomic seat after a live cap increase.

Review the pause plus matured-strategy-proposal migration path. An uncommitted
request may be cancelled before the ordinary thirty-day expiry, but an
unresolved canonical Main handle must be journaled and then released or
explicitly abandoned before migration. Check rollback and denial-of-service
behavior for responsive, reverting, gas-burning, and contradictory Adapter/Main
witnesses.

Verify known-idle force settlement and the delayed guardian resolution of a
responsive over-cap cycle. The complete escrow must burn once; shareholder idle
must be pro-rated before adding the complete batch-earmarked protocol credit;
claim ordering must not change aggregate payout; no returned share may reclaim
the same idle; and an ordinary claim must not weaken the two-percent execution
loss cap. Paused claimability must be limited to an initialized force-settled
cycle.

Review migration from an old Strategy whose pinned asset source still holds
backing. For a fully unresponsive Strategy, the first paused and matured apply
must only quarantine the source, revoke allowance, retain the proposal, and
start a second full delay. Only the later apply may explicitly write off the
source. A responsive NAV witness or successful migration attestation must keep
nonzero source backing fail-closed. Check cancellation, replacement proposal,
same-strategy, allowance, and EIP-7702 delegation-designator edge cases.

Reassess rather than assume away the retained boundaries: permissionless repair
of a missing local snapshot in inconsistent or legacy state, standard ERC-4626
deposit/mint calls without user slippage arguments, strict NAV views during a
Strategy outage, the external linked-library relay, bootstrap donations, and
canonical Strategy immediate-liquidity assumptions. Distinguish an exploitable
canonical path from an explicit product, governance, deployment, or bounded
recovery residual.

The linked `VaultBDepositLib` logic embedded in the Vault flat is in scope.
Strategy/Main implementations, the standalone Adapter, live configuration, and
graph-wide integration are context and out of scope except where their boundary
assumptions are embedded in the linked Vault flat. Do not perform unpaid
component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions,
an exploit or failure path, severity rationale, and a minimal remediation.
