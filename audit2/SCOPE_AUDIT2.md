# Scope — Vault B V2 Audit 2 re-audit candidate

Scope authority is `source/script/DeployVaultBV2.s.sol` from source commit
`27e1e617296dde8c0dc1ff621eeec3a3b10b409d`. Every contract it deploys is in
scope; the source snapshot includes the first-party Solidity dependencies
needed to review that graph.

## In-scope deployables

| Contract | Role |
|---|---|
| `DeepYieldVaultB` | User-facing ERC-4626 vault and asynchronous redeem queue |
| `FixedFeeSink` | Fixed-treasury performance-fee receiver |
| `VaultBPriceGuard` | USDT/WBNB oracle, deviation, loss, and emergency policy |
| `BoundedPancakeExecutionAdapterV2` | USDT/WBNB bounded swap executor |
| `VaultBCakePriceGuard` | CAKE/USDT price and execution policy |
| `BoundedPancakeRewardAdapterV2` | CAKE/USDT bounded reward-swap executor |
| `PancakeV3MasterchefVenue` | Pancake V3 NFT lifecycle and MasterChef integration |
| `DedicatedVaultMainV2` | Position, inventory, withdrawal, and recovery state machine |
| `DedicatedVaultStrategyAdapterV2` | Vault/Main bridge, accounting, and performance-fee lifecycle |

## Architectural context

```text
User USDT -> DeepYieldVaultB -> DedicatedVaultStrategyAdapterV2
          -> DedicatedVaultMainV2 -> PancakeV3MasterchefVenue
          -> Pancake V3 NFPM / MasterChef / USDT-WBNB pool

DedicatedVaultMainV2 -> BoundedPancakeExecutionAdapterV2 -> Router
                      -> BoundedPancakeRewardAdapterV2  -> Router
                      -> VaultBPriceGuard / VaultBCakePriceGuard
```

This context identifies interface assumptions only. Paid review boundaries
are specified in `BATCHES_AUDIT2.md`. Two targets are intentionally combined
only for the Strategy/FeeSink fee-flow review; other implementation text is
context unless that task explicitly owns it.

The Main flat includes all of its linked first-party `MainV2*` libraries,
including `MainV2Open` and `MainV2Liquidation`. Those libraries are in scope
within the single Main task.

The Strategy flat also contains Main and `MainV2*` source text because the
Strategy imports the concrete Main type. That text is type-resolution and
reachability context, not a second Main line audit. The combined fee-flow task
owns Strategy, `FixedFeeSink`, and `IFeeSink`; the separate Main task owns Main
and its linked libraries.

## First-party dependencies included in `source/`

The closure includes the dedicated Venue, async-strategy, fee-sink, Pancake,
and execution interfaces; FullMath, TickMath, LiquidityAmounts, V3 valuation,
Vault deposit, and each `MainV2*` library used by the deployables. Vendored
OpenZeppelin context appears in the flats but is not independently first-party
scope. `VaultFeesLib.sol` is not reachable from this deployment graph and is
intentionally excluded.

## Explicitly out of scope

- Legacy V1 `DedicatedVaultMain`, legacy adapters, and prior V1 router/quoter
  paths.
- Obsolete `FeeSplitter`, `PartnerRegistry`, `PartnerAttributedSplitter`, and
  the entire partner-wrapper subsystem; the graph uses `FixedFeeSink`.
- HyperEVM/LiFi contracts and unrelated products.
- Off-chain keeper/broadcaster software, deployment keys, production state,
  and any actual deployment.
- `DeployVaultBV2BroadcastRehearsal.s.sol`, which is a local transaction-prefix
  rehearsal harness and is not imported by the production deployment graph.

The exclusions are not assertions of safety. They are absent to avoid paying
for review of dead or unreachable code.
