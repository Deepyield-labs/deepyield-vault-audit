# Audit 2 — Batch 02: Main lifecycle

Upload only `flat/DedicatedVaultMainV2.audit2.flat.sol` as one paid task.

Review funding, open-series reservation/chunks/mint, close, staged guardian
recovery, inventory accounting, liquidation, withdrawal readiness, and
HALTED-mode authority. Focus on state transitions, authorization,
deadlines/minimums, repeated jobs, and denial-of-service. The flat includes
the linked first-party `MainV2*` libraries; those libraries are part of this
one task.

Pay particular attention to canonical versus raw WBNB/CAKE: donations must
not block readiness or NAV, while downward accounting discrepancies must not
make real inventory unliquidatable. Venue, guards, adapters, Vault, and
Strategy are interface/configuration assumptions for this paid task, not
additional code to audit.
