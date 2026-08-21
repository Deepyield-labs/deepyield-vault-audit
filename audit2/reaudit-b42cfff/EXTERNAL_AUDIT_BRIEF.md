# Audit 2 — DeepYieldVaultB Job 703 Follow-up Re-Audit

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/cea666b71ca8059984f88daabf7ce738f4728428/audit2/reaudit-b42cfff/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `b42cfff1772b76b3980734fee398081d469240be`, package
`cea666b71ca8059984f88daabf7ce738f4728428`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting and the asynchronous redeem
cycle: request admission and aggregation, economic and full-queue commit,
snapshot materialization, settlement initialization, partial claim, share burn
and return, cancellation, receiver update, expiry, deferred-handle release, and
unavailable-Strategy recovery.

Pay particular attention to unavailable-Strategy force settlement when idle
assets cover only part of the frozen batch entitlement. Confirm that the full
frozen entitlement remains the burn denominator, only the covered share
fraction burns, uncovered shares return with their claim on later-recovered
capital, claimable liabilities remain excluded, treasury credit cannot leak to
remaining holders, and rounding cannot overpay or over-burn.

Reassess the 5% economic commit threshold after both live-supply growth and
share exits. Confirm that transient departed capital cannot make the threshold
unreachable, while a later depositor cannot cheaply force an unwind. Review the
bounded `max-1` sybil queue residual and the atomic rejection of a
sub-economic final slot without assuming that a fee or identity system exists.

Review aggregated-request expiry: a top-up now renews the entire owner/receiver
slot timestamp. Check owner/receiver authorization, permissionless expiry,
escrow accounting, overflow bounds, and whether repeated top-ups can affect
another user's request.

For recovery from a canonical Main commitment with a missing local Vault
snapshot, verify that full Strategy NAV must be responsive before the Vault can
materialize the snapshot. It must fail closed rather than permanently latching
idle-only NAV as the execution-loss-cap basis, and must remain retryable after
the valuation view recovers. Reassess rollback and denial-of-service behavior
at the Strategy and pinned-Main boundaries.

Also review migration from an old Strategy whose `prepareMigration()` returns
true while `estimatedTotalAssets()` responsively reports non-zero deployed
assets. Confirm that the truthy hook cannot waive that independent observation
and that the independently pinned asset source must still be empty. Preserve
the intended paused emergency-migration boundary for genuinely unavailable
views without assuming a malicious Strategy can be made trustless.

The linked `VaultBDepositLib`, Strategy/Main implementations, live
configuration, and graph-wide integration are context and out of scope except
where their boundary assumptions are embedded in the linked Vault flat. Do not
perform unpaid component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions,
an exploit or failure path, severity rationale, and a minimal remediation.
