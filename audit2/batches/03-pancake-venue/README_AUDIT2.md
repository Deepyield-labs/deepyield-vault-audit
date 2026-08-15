# Audit 2 — Batch 03: Pancake Venue

Upload only `flat/PancakeV3MasterchefVenue.audit2.flat.sol` as one paid task.

Review Pancake V3 NFT custody, MasterChef failure handling, staged close and
harvest recovery, recipient degradation, controller rotation/timelock,
managed-token rescue exclusions, callbacks, minima/deadlines, and
stranded/write-off custody.

The Main/Venue accounting and HALTED-mode edge requires a separately scoped
integration review if desired. For this task, Main policy is an external
interface assumption. Retain the residual that write-off is economically
irreversible for NFT-held value and that simultaneous external recipient
failure needs external recovery.
