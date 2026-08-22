# Audit 2 — DeepYieldVaultB Safe-Recovery Follow-up Re-Audit

Pinned file:
https://github.com/Deepyield-labs/deepyield-vault-audit/blob/a332a8a06e7cfca51c116d424bba536df538aa7d/audit2/reaudit-f4ff567/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `f4ff567689150d52a8e9b18cd05dc95a31931e0d`, package
`a332a8a06e7cfca51c116d424bba536df538aa7d`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Review the remediation of the previously reported
1 Critical and 5 High findings: timed-out redeem recovery with unavailable or
inconsistent Strategy telemetry; loss-cap and batch-value accounting; bounded
external-view gas; synchronous exit behavior; and guardian recoverability.

Confirm that delayed recovery is value-neutral. It must create no asset entitlement,
burn no share, and return each outstanding request's complete escrowed shares to its
owner. Late-recovered assets must remain Vault NAV shared by all live shares. Check
partial claim ordering, request aggregation, receiver updates, claimable liabilities,
deferred handle release, rollback, and repeated recovery/claim calls for any route to
double payment, confiscation, cross-subsidy, or permanent queue lock.

Confirm that healthy ready-cycle settlement and its ordinary execution-loss cap are
unchanged. A responsive but over-cap cycle may use delayed recovery only while paused
and under guardian authority; an unavailable commitment witness may permit delayed
permissionless recovery. Secondary NAV/loss/getter failures must not prevent the local
zero-value cancellation, while an unresolved canonical handle must remain durably
journaled for gated reconciliation.

Review synchronous ERC-4626 `withdraw` and `redeem` after immediate liquidity was
narrowed to spendable idle. Confirm that neither path can trigger a Strategy unwind
after shares were priced and that deployed capital exits only through the asynchronous,
loss-bounded cycle. Verify preview/execution consistency and denial-of-service behavior.

Review Strategy migration with the increased bounded NAV-probe gas budget and the
pinned old asset-source postcondition. Confirm that a nonempty old source cannot be
orphaned and that a reverting, gas-burning, or contradictory Strategy cannot bypass
the migration gates. Review restoration and revocation of `GUARDIAN_ROLE` through the
delayed default-admin authority.

Reassess the report's Medium and Low findings where they remain reachable; do not assume
they were removed merely because the Critical/High recovery feature was reduced.

The linked `VaultBDepositLib` logic embedded in the Vault flat is in scope. Standalone
Strategy/Main implementations, live configuration, and graph-wide integration are
context and out of scope except where their boundary assumptions are embedded in the
linked Vault flat. Do not perform unpaid component audits or graph-wide integration
work.

For every finding provide exact flat and raw-source locations, preconditions, an
exploit or failure path, severity rationale, and a minimal remediation.
