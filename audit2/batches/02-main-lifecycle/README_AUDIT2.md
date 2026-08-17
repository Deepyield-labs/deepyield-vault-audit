# Audit 2 — Batch 02: Main lifecycle

This is paid task 3 in the initial tranche. Upload
`flat/DedicatedVaultMainV2.audit2.flat.sol`.

Review funding, open-series reservation/chunks/mint, close, staged guardian
recovery, inventory accounting, liquidation, withdrawal readiness, and
HALTED-mode authority. Focus on state transitions, authorization,
deadlines/minimums, repeated jobs, and denial-of-service. The flat includes
the linked first-party `MainV2*` libraries; those libraries are part of this
one task.

Pay particular attention to canonical versus raw WBNB/CAKE; historical NFT
realization and Main accounting; queued-cycle commitment before irreversible
recovery; CAKE LOWER fair-value versus UPPER cap/emergency accounting;
non-final slicing by Main and guard headroom; and rollback after a late guard,
router, or accounting failure. Venue, guards, adapters, Vault, and Strategy
are canonical reachability context, not additional line-audit targets.
