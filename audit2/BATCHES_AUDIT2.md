# Audit 2 — one-file paid review plan

Every `.audit2.flat.sol` file below is one paid external task. A batch is an
upload location only, not a combined scope. Each task must state: **Audit ONLY
the linked flat file. Do not treat another paid task's contract as in-scope.**

| Paid-task order | Upload location | Flat file | Narrow review boundary |
|---:|---|---|---|
| 1 | Batch 01 | `DeepYieldVaultB` | ERC-4626 accounting; async queue, cancellation, claims, claimable-reserve isolation, liabilities, and Strategy-boundary assumptions |
| 2 | Batch 01 | `FixedFeeSink` | forwarding, treasury timelock, balance deltas, and recipient failures |
| 3 | Batch 01 | `DedicatedVaultStrategyAdapterV2` | Vault/Main bridge, fee basis, deferred or under-pulled fee remittance, callbacks, ordering, and transfer deltas |
| 4 | Batch 02 | `DedicatedVaultMainV2` | Main lifecycle, recovery, inventory, liquidation, withdrawal readiness, and its linked first-party libraries |
| 5 | Batch 03 | `PancakeV3MasterchefVenue` | NFT/MasterChef lifecycle, staged close/harvest, rescue, rotation, and write-off boundaries |
| 6 | Batch 04 | `VaultBPriceGuard` | WBNB oracle/TWAP policy, deviations, loss budgets, and caps |
| 7 | Batch 04 | `BoundedPancakeExecutionAdapterV2` | WBNB execution binding, approvals, minimums/deadlines, and observed output |
| 8 | Batch 04 | `VaultBCakePriceGuard` | CAKE source/decimal/divergence, active-window consumed-notional retention, and emergency budget policy |
| 9 | Batch 04 | `BoundedPancakeRewardAdapterV2` | CAKE execution binding, approvals, minimums/deadlines, observed output, and post-settlement emergency-budget debit ordering |

Scope is the named deployable plus first-party library logic linked, inlined,
or transitively compiled into its runtime. Another deployable, and dependency
code pulled in solely through it, is context and out of scope when it appears
only for type resolution. In particular, the Strategy flat contains Main and
`MainV2*` implementation context because it imports the concrete Main type;
that context belongs exclusively to task 4. The Main task owns its linked
first-party libraries, but does not require review of the separate Venue,
guard, adapter, Vault, or Strategy implementation.

If a cross-contract assessment is required after the nine reviews, commission
it as a separate tenth task with its own funded scope and links. Do not impose
that assessment as a condition of any individual task.
