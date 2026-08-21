# Audit 2 — DeepYieldVaultB Critical/High Follow-up Re-Audit

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/08eaf41a0da2e0ada97ed9a84e31dc025a784915/audit2/reaudit-bd1adc6/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `bd1adc6af9afd5143c7851d93e53d0b0a6886ee0`, package
`08eaf41a0da2e0ada97ed9a84e31dc025a784915`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting and the asynchronous redeem
cycle, focusing on the 1 Critical and 5 High findings reported against parent
`ae03b35`.

Verify that an initialized residual batch whose Strategy becomes unavailable
or only partially readable cannot draw more than its live-supply-pro-rata
share of current spendable idle. Confirm that its unpaid frozen entitlement
remains the burn denominator, only the paid fraction burns, uncovered shares
return live, and later-recovered capital cannot be claimed twice.

Review every commitment-witness state: local Vault true/false, Adapter
true/false/revert/gas-burn, and pinned direct Main true/false/revert/gas-burn.
Ordinary cancellation and receiver mutation must fail closed on an unresolved
direct witness, while an empty queue must not be bricked by an Adapter outage.
For expired requests, confirm that unresolved Main can only become a deferred
handle through pause plus a matured strategy proposal; an Adapter cancellation
acknowledgement alone must not create a normal permissionless release.

Verify force settlement when commitment responds but batch-commitment, either
loss getter, or NAV fails. Healthy initialization requires every observation;
otherwise recovery must use bounded known-idle pro-rata accounting and retain
the guardian-pause gate for a responsive but incomplete Strategy.

Check gas and return-data griefing across all three cancellation tiers and old-
Strategy migration. The caller must retain gas for local completion and
rollback. Confirm that emergency migration still rejects a nonempty pinned old
asset source; do not assume the report's suggested bypass is safe, because it
could orphan backing.

Reassess the retained Medium/Low boundaries only as they are reachable inside
this linked Vault flat: near-total-exit dust, bounded queue fan-out,
direct-backing donation admission DoS, guardian timeout policy, canonical BSC
USDT assumptions, strict versus tolerant handle release, and Strategy
availability/trust. Distinguish an exploitable canonical path from a product,
governance, deployment, or explicitly bounded residual.

The linked `VaultBDepositLib`, Strategy/Main implementations, live
configuration, and graph-wide integration are context and out of scope except
where their boundary assumptions are embedded in the linked Vault flat. Do not
perform unpaid component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions,
an exploit or failure path, severity rationale, and a minimal remediation.
