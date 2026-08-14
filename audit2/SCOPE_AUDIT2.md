# Scope — Vault B V2 Round 9 candidate

Scope authority is `source/script/DeployVaultBV2.s.sol`. Every contract it
deploys is in scope; the package includes every first-party Solidity dependency
of that deployment graph.

## In-scope deployables

| Contract | Role |
|---|---|
| `DeepYieldVaultB` | User-facing ERC-4626 vault and asynchronous redeem queue |
| `FixedFeeSink` | Fixed-treasury performance-fee receiver |
| `VaultBPriceGuard` | USDT/WBNB oracle, deviation, loss and emergency policy |
| `BoundedPancakeExecutionAdapterV2` | USDT/WBNB bounded swap executor |
| `VaultBCakePriceGuard` | CAKE/USDT price and execution policy |
| `BoundedPancakeRewardAdapterV2` | CAKE/USDT bounded reward-swap executor |
| `PancakeV3MasterchefVenue` | Pancake V3 NFT lifecycle and MasterChef integration |
| `DedicatedVaultMainV2` | Position, inventory, withdrawal and recovery state machine |
| `DedicatedVaultStrategyAdapterV2` | Vault/Main bridge, accounting and performance-fee lifecycle |

## Required cross-contract review

```text
User USDT -> DeepYieldVaultB -> DedicatedVaultStrategyAdapterV2
          -> DedicatedVaultMainV2 -> PancakeV3MasterchefVenue
          -> Pancake V3 NFPM / MasterChef / USDT-WBNB pool

DedicatedVaultMainV2 -> BoundedPancakeExecutionAdapterV2 -> Router
                      -> BoundedPancakeRewardAdapterV2  -> Router
                      -> VaultBPriceGuard / VaultBCakePriceGuard
```

Focus in particular on:

- access control and immutable wiring across the full graph;
- ERC-4626 pricing, queue ordering, cancellation, claims, fees, liabilities,
  insolvency, and strategy migration;
- open/mint/close/recovery state transitions, repeated jobs, deadline/minimum
  validation, and the invariant that a HALTED Main cannot be resumed by an
  emergency close;
- canonical versus raw non-USDT inventory, NAV bounds, and liquidation of
  donated or under-accounted WBNB/CAKE;
- Pancake NFT custody, MasterChef failures, blacklist degradation, managed-token
  rescue exclusions, controller rotation, and written-off NFT custody;
- normal and emergency oracle/deviation/loss policy, notional accounting,
  quote-to-swap binding, price manipulation, stale feeds, TWAP availability,
  liquidity, pool provenance, and deploy-time configuration;
- all arbitrary-recipient, approval, callback, reentrancy, and role-escalation
  paths.

## First-party dependencies included in `source/`

The source closure includes the dedicated Venue, async-strategy, fee-sink,
Pancake, and execution interfaces; the FullMath, TickMath, LiquidityAmounts,
V3 valuation, Vault deposit/fee, and every `MainV2*` library used by the
deployables. Vendored OpenZeppelin code is present in the flats for usage
context but is not independently first-party scope.

## Explicitly out of scope

- Legacy V1 `DedicatedVaultMain`, legacy adapters and prior V1 router/quoter
  paths.
- Obsolete `FeeSplitter`, `PartnerRegistry`, `PartnerAttributedSplitter`, and
  the entire partner-wrapper subsystem; the deploy graph uses `FixedFeeSink`.
- HyperEVM/LiFi contracts and unrelated products.
- Off-chain keeper/broadcaster software, deployment keys, production state,
  and any actual deployment.

The exclusions are not an assertion of safety. They are not reachable from the
current `DeployVaultBV2` graph and are intentionally absent from this snapshot
to avoid paying for review of dead code.
