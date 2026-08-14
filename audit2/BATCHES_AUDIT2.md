# Audit 2 — auditor upload plan

Each `.audit2.flat.sol` file is uploaded as an individual Solidity unit.
The batch directories are review queues, not files to concatenate.

| Order | Batch | Flat contracts |
|---:|---|---|
| 1 | [capital and redemptions](batches/01-capital-and-redemptions/README_AUDIT2.md) | DeepYieldVaultB, FixedFeeSink, DedicatedVaultStrategyAdapterV2 |
| 2 | [Main lifecycle](batches/02-main-lifecycle/README_AUDIT2.md) | DedicatedVaultMainV2 |
| 3 | [Pancake Venue](batches/03-pancake-venue/README_AUDIT2.md) | PancakeV3MasterchefVenue |
| 4 | [pricing and swap execution](batches/04-pricing-and-swap-execution/README_AUDIT2.md) | VaultBPriceGuard, BoundedPancakeExecutionAdapterV2, VaultBCakePriceGuard, BoundedPancakeRewardAdapterV2 |

## Mandatory cross-batch pass

After individual review, assess:

1. `DeepYieldVaultB -> DedicatedVaultStrategyAdapterV2 -> DedicatedVaultMainV2`
   for asset/share conversion, queue commitments, losses, and fees.
2. `DedicatedVaultMainV2 -> PancakeV3MasterchefVenue` for state transitions,
   observed balances, recovery, write-off, and HALTED-mode invariants.
3. `DedicatedVaultMainV2 -> PriceGuards -> Swap Adapters` for quote-to-swap
   binding, normal/emergency loss policy, capacity, inventory, and liquidation
   liveness.
4. Immutable deployment wiring in
   `source/script/DeployVaultBV2.s.sol`.

The historical PriceGuard re-audit listed in
[EXTERNAL_REVIEW_INPUTS_AUDIT2.md](EXTERNAL_REVIEW_INPUTS_AUDIT2.md) targeted
an older commit and must be re-evaluated, not presumed fixed.
