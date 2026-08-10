# DeepYield Vault B V2 — audit package

ERC-4626 liquidity-management system on BNB Chain that runs one active PancakeSwap V3
USDT/WBNB concentrated-liquidity position, optionally staked in Pancake MasterChef.

This repository contains the complete on-chain scope, the deployment script with its
constructor-argument manifest, and the test suite. It is a **pre-deployment candidate**:
the constructor arguments in `script/DeployVaultBV2.config.example.json` are placeholders
(all role addresses are zero) and the deployment starts halted — deposits require a
separate admin `enableOperations` transaction.

## Scope

The authority for what is in scope is `script/DeployVaultBV2.s.sol`: every contract it
deploys is in scope.

| # | contract | role |
|---|---|---|
| 1 | `src/DeepYieldVaultB.sol` | user-facing ERC-4626 vault; users deposit USDT, receive shares |
| 2 | `src/DedicatedVaultStrategyAdapterV2.sol` | bridge between the vault and Main; tracks principal, crystallizes the performance fee (`performanceFeeBps = 2000`, immutable, capped at 30%) |
| 3 | `src/DedicatedVaultMainV2.sol` | holds Vault B assets, manages the single active V3 position |
| 4 | `src/PancakeV3MasterchefVenue.sol` | mints/closes the LP NFT, stakes in MasterChef, collects trading fees and CAKE, returns all tokens to Main |
| 5 | `src/BoundedPancakeExecutionAdapterV2.sol` | **the USDT/WBNB swap executor actually wired into V2** (`DedicatedVaultMainV2.executionAdapter`, immutable) |
| 6 | `src/BoundedPancakeRewardAdapterV2.sol` | CAKE/USDT reward swap executor |
| 7 | `src/VaultBPriceGuard.sol` | oracle/TWAP guard for the WBNB leg |
| 8 | `src/VaultBCakePriceGuard.sol` | oracle/TWAP guard for the CAKE leg |
| 9 | `src/partners/PartnerAttributedSplitter.sol` | fee sink — receives the crystallized performance fee |
| 10 | `src/partners/PartnerRegistry.sol` | partner attribution registry behind the splitter |

Plus everything they import: `src/interfaces/` (10 files) and `src/libraries/`
(`FullMath`, `LiquidityAmounts`, `TickMath`, `V3PositionValuer`).

### Not in scope

`src/DedicatedVaultMain.sol`, `src/DedicatedVaultStrategyAdapter.sol`,
`src/PancakeV3SwapAdapter.sol` and `src/ExcludeIdlePairedQuoter.sol` are the **previous
(V1) wiring**. They are present only so that `test/VaultBProductionWiring.t.sol` and
`test/VaultBWiredLifecycleFork.t.sol` compile. V2 does not deploy them —
`DedicatedVaultMainV2` swaps exclusively through `IVaultBExecutionAdapterV2`, i.e.
`BoundedPancakeExecutionAdapterV2`.

## Fund flow

```
User USDT
  → DeepYieldVaultB
  → DedicatedVaultStrategyAdapterV2        (principal accounting, performance fee)
  → DedicatedVaultMainV2                   (custody, position lifecycle)
  → PancakeV3MasterchefVenue               (LP NFT mint / stake / harvest / close)
  → Pancake V3 NonfungiblePositionManager / MasterChef V3 / USDT-WBNB pool

Swaps:
DedicatedVaultMainV2
  → BoundedPancakeExecutionAdapterV2       (USDT/WBNB, guarded by VaultBPriceGuard)
  → BoundedPancakeRewardAdapterV2          (CAKE/USDT, guarded by VaultBCakePriceGuard)
  → Pancake SmartRouter → pool

Performance fee:
DedicatedVaultStrategyAdapterV2 → feeRecipient / IFeeSink → PartnerAttributedSplitter
```

## Invariants we believe hold, and want challenged

- No contract may send user funds to an arbitrary recipient.
- The Venue returns all tokens only to Main.
- Main returns USDT only through the authorized StrategyAdapter.
- StrategyAdapter returns user assets only to the Vault, except the bounded performance fee.
- An active LP position cannot permanently block redemption.
- Emergency exits remain available when normal opens are disabled.
- NAV must not exceed conservatively executable value.
- USDT, WBNB, CAKE, LP fees and fee liabilities are each accounted exactly once.
- Roles and immutable addresses match the deployment manifest.

`AUDIT_SCOPE.md` lists the specific questions per contract.

## Build

```bash
git clone --recursive <this repo>
cd deepyield-vault-audit
forge build
forge test --no-match-path 'test/*Fork*'     # 157 tests, no RPC required
```

Toolchain: Foundry, solc `0.8.24`, optimizer on (200 runs), **`via_ir = true` is
required** — the two-sided open path exceeds the legacy codegen stack limit; see the
comment in `foundry.toml`.

Dependencies are pinned git submodules: OpenZeppelin Contracts `v5.6.1`, forge-std
`v1.16.1`.

Fork tests (`test/*Fork*.t.sol`) need a BSC archive RPC; `foundry.toml` points at public
dataseed endpoints, which are rate-limited.

## Status at packaging time

- `forge build`: clean (warnings only — lint hints on ERC-20 return values inside tests).
- `forge test --no-match-path 'test/*Fork*'`: **157 passed, 0 failed**.
- Not deployed. No mainnet address to verify against yet.
