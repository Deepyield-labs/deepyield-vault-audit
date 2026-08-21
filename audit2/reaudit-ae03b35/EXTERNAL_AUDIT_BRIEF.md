# Audit 2 — DeepYieldVaultB Job 707 Follow-up Re-Audit

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/a54c854687a5e88ec31f1c417912f66f8acfe5d8/audit2/reaudit-ae03b35/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `ae03b355404045d2e8df03ff3b80d957951b7a01`, package
`a54c854687a5e88ec31f1c417912f66f8acfe5d8`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting and the asynchronous redeem
cycle: request admission and aggregation, economic and full-queue commit,
snapshot materialization, settlement initialization, partial claim, share burn
and return, cancellation, receiver update, expiry, deferred-handle release,
and unavailable-Strategy recovery.

Pay particular attention to force settlement while Strategy NAV is
unavailable. Confirm that the batch can draw no more than its supply-pro-rata
share of current spendable idle, while its full frozen entitlement remains the
burn denominator. Verify that only the actually paid share fraction burns,
all uncovered shares return to their owner, later-recovered deployed capital
remains represented by live shares, claimable liabilities are excluded, and
rounding cannot overpay, over-burn, or strand a material residual.

Review owner cancellation and receiver mutation when the canonical Strategy
Adapter's commitment view is false or unavailable but the independently pinned
asset source/Main remains responsive. Confirm that a responsive direct Main
commitment blocks both mutations, while a genuinely uncommitted outage remains
recoverable only if the canonical withdrawal handle is released atomically.
Check rollback and denial-of-service behavior when Adapter and Main witnesses
return false, revert, disagree, or become unavailable in different orders.

Reassess — do not assume — the retained execution-loss-cap basis, treasury
deficit-funding semantics, live-supply 5% commitment threshold, bounded sybil
queue fan-out, minimum-deposit policy, strict preview/convert outage behavior,
near-total-exit dust shortcut, operational-role delegation, and emergency
pause policy. Distinguish an exploitable canonical path from a Strategy trust
assumption, trusted donation, governance policy, or documented bounded
residual.

The linked `VaultBDepositLib`, Strategy/Main implementations, live
configuration, and graph-wide integration are context and out of scope except
where their boundary assumptions are embedded in the linked Vault flat. Do not
perform unpaid component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions,
an exploit or failure path, severity rationale, and a minimal remediation.
