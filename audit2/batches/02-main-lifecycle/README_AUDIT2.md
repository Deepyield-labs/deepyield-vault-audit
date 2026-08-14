# Audit 2 — Batch 02: Main lifecycle

Upload `flat/DedicatedVaultMainV2.audit2.flat.sol`.

Review funding, open-series reservation/chunks/mint, close, staged guardian
recovery, inventory accounting, liquidation, withdrawal readiness and
HALTED-mode authority. Focus on state transitions, authorization,
deadlines/minimums, repeated jobs, and denial-of-service.

Pay particular attention to canonical versus raw WBNB/CAKE: donations must not
block withdrawals or NAV, while under-accounting must not make real inventory
unliquidatable. The Vault, Venue, guards and adapters must be checked in the
cross-batch pass.
