# Audit scope — DeepYield Vault B V2

DeepYield Vault B is a multi-contract ERC-4626 liquidity-management system on BNB Chain.

Source: https://github.com/Deepyield-labs/deepyield-vault-audit

Scope authority is `script/DeployVaultBV2.s.sol` — every contract it deploys is in scope.
`src/DedicatedVaultMain.sol`, `src/DedicatedVaultStrategyAdapter.sol`,
`src/PancakeV3SwapAdapter.sol` and `src/ExcludeIdlePairedQuoter.sol` are the previous (V1)
wiring, retained only so two wiring/fork tests compile — **out of scope**.

## 1. DedicatedVaultMainV2 + PancakeV3MasterchefVenue + BoundedPancakeExecutionAdapterV2 + BoundedPancakeRewardAdapterV2 + VaultBPriceGuard + VaultBCakePriceGuard

`DedicatedVaultMainV2` holds Vault B assets and manages one active PancakeSwap V3
USDT/WBNB concentrated-liquidity position.

`PancakeV3MasterchefVenue` mints and closes the LP NFT, optionally stakes it in Pancake
MasterChef, collects trading fees and CAKE rewards, and returns all USDT, WBNB and CAKE to
`DedicatedVaultMainV2`.

`BoundedPancakeExecutionAdapterV2` is the immutable USDT/WBNB swap executor
(`DedicatedVaultMainV2.executionAdapter`). `BoundedPancakeRewardAdapterV2` performs the
CAKE/USDT reward swaps. Both are constrained by the corresponding price guard
(`VaultBPriceGuard`, `VaultBCakePriceGuard`) — token pairs, router, recipient, deadline,
approvals, oracle deviation and minimum output must all be bounded.

Please audit:

- custody and arbitrary-recipient risks;
- immutable contract wiring;
- keeper, guardian, controller and admin authorization;
- open, mint, stake, harvest, unstake, close and emergency lifecycle;
- stuck LP NFT or MasterChef dependency;
- one-sided and out-of-range position closes;
- approval reset and malicious-token/reentrancy behavior;
- minOut, deadline, price manipulation, slippage and MEV protection;
- price-guard soundness: TWAP window, oracle staleness bounds (`maxBnbFeedAge`,
  `maxUsdtFeedAge`), `maxOracleDeviationBps`, and the separate normal vs emergency loss
  budgets (`normalSwapLossBps` vs `maxEmergencySwapLossBps`);
- notional and rate limits: `hardMaxActiveAssets`, `hardMaxSwapPerJob`,
  `hardDailySwapLimit`, canary caps, and whether they can be bypassed or exhausted as a DoS;
- idle WBNB and CAKE handling;
- conservative NAV and balance-delta accounting;
- emergency close, `maxEmergencyDuration` and withdrawal liveness;
- duplicate or inconsistent active-position state.

## 2. DedicatedVaultStrategyAdapterV2

Bridges the ERC-4626 Vault and `DedicatedVaultMainV2`. Moves USDT between them, tracks
principal and crystallizes the performance fee.

The performance fee is `performanceFeeBps = 2000` (20% of realized USDT profit), immutable,
hard-capped at 30% (`MAX_PERFORMANCE_FEE_BPS`). It is paid to `feeRecipient` and recorded
through `IFeeSink` (`PartnerAttributedSplitter`).

Please audit:

- vault-only and Main-only authorization boundaries;
- principal/accountedAssets correctness;
- profit and performance-fee calculation;
- harvest and withdrawal fee-bypass possibilities;
- duplicate fee charging (both the harvest path and the async-claim path record into the
  fee sink — confirm exactly-once);
- feeRecipient, IFeeSink and fee-transfer safety;
- losses, partial withdrawal and full withdrawal;
- strategy migration and stranded assets;
- NAV before and after accrued fees.

## 3. DeepYieldVaultB

The user-facing ERC-4626 Vault. Users deposit USDT and receive shares. The Vault combines
idle USDT with strategy-reported assets, and supports an async redeem queue.

Please audit:

- ERC-4626 deposit, mint, withdraw and redeem accounting;
- share-price manipulation and first-depositor attacks;
- donations and rounding;
- deposit cap (`vaultDepositCap`) and minimum deposit;
- totalAssets correctness across Vault, Adapter, Main and LP;
- deposits while LP fees or rewards are accrued;
- withdrawals while an LP position is active;
- the async redeem queue: request, claim, cancellation, share transfers while queued,
  and ordering/starvation;
- strategy shortfall and withdrawal liveness;
- pause semantics: deposits may pause but user exits must remain available;
- the halted-at-deployment state and the single admin `enableOperations` transition;
- strategy replacement and allowance handling;
- insolvency, stale NAV and fee-liability handling.

## 4. PartnerRegistry + PartnerAttributedSplitter

The fee sink that receives the crystallized performance fee, with partner attribution
(`partnerShareBps`).

Please audit:

- who may register or mutate partner attribution, and whether it can redirect fees;
- split arithmetic, rounding and residual dust;
- whether a malicious or reverting partner can block harvest, claim or withdrawal;
- treasury address handling (`projectTreasury`, `vaultTreasury`).

## Cross-contract invariants

Expected fund flow:

```
User USDT → DeepYieldVaultB → DedicatedVaultStrategyAdapterV2 → DedicatedVaultMainV2
          → PancakeV3MasterchefVenue → Pancake V3 NFPM / MasterChef / pool
```

Swap flow:

```
DedicatedVaultMainV2 → BoundedPancakeExecutionAdapterV2 (USDT/WBNB, VaultBPriceGuard)
                     → BoundedPancakeRewardAdapterV2    (CAKE/USDT, VaultBCakePriceGuard)
                     → Pancake SmartRouter → USDT/WBNB pool
```

Required invariants:

- no contract may send user funds to an arbitrary recipient;
- the Venue returns all tokens only to Main;
- Main returns USDT only through the authorized StrategyAdapter;
- the StrategyAdapter returns user assets only to DeepYieldVaultB, except the bounded
  performance fee to the fee sink;
- an active LP position cannot permanently block redemption;
- emergency exits remain available when normal opens are disabled;
- NAV must not exceed conservatively executable value;
- USDT, WBNB, CAKE, LP fees and fee liabilities must be accounted exactly once;
- roles and immutable addresses must match the deployment manifest
  (`script/DeployVaultBV2.config.example.json`).

Please report vulnerabilities, economic/accounting defects, access-control failures,
denial-of-service and withdrawal-liveness risks, with severity, exploit scenario, affected
lines and concrete remediation.

## Out of band

The off-chain keeper and durable transaction broadcaster are not Solidity and are not in
this repository, but they influence deadline, nonce, replay, receipt/reorg recovery and the
timeliness of emergency exits. We intend to submit them as a separate engagement.
