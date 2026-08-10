# Flattened single-file copies

Each file here is `forge flatten` output for one in-scope contract, so a reviewer can read
a single self-contained file without resolving submodules or remappings.

Generated from the repository root at the pinned commit. Regenerate with:

```bash
forge flatten src/<Contract>.sol -o audit/flat/<Contract>.flat.sol
```

Own source lines vs flattened (the difference is OpenZeppelin v5.6.1 boilerplate, which is
upstream-audited and out of scope):

| contract | own | flattened |
|---|---|---|
| DedicatedVaultMainV2 | 663 | 1984 |
| DeepYieldVaultB | 545 | 5044 |
| PancakeV3MasterchefVenue | 325 | 1228 |
| DedicatedVaultStrategyAdapterV2 | 279 | 4294 |
| VaultBPriceGuard | 242 | 871 |
| VaultBCakePriceGuard | 238 | 867 |
| BoundedPancakeExecutionAdapterV2 | 145 | 681 |
| BoundedPancakeRewardAdapterV2 | 114 | 650 |
