# Vault B V2 — Audit 2 re-audit package

This is a separate pre-deployment re-audit package. It supersedes this
repository's older Audit 2 package only on branch
`audit2/reaudit-18c1beb-20260815`; it does not alter historical branches,
approve deployment, or assert that any finding is remediated.

| Field | Value |
|---|---|
| Candidate source commit | `18c1beb5071605385ecc0276322d87e6c6ea5652` |
| Compiler | solc `0.8.24`, optimizer runs `200`, via-IR, Cancun, IPFS metadata |
| Flattener | Forge `1.6.0-v1.7.0`, commit `f83bad912a9dba7bf0371def1e70bb1896048356` |
| Chain target | BNB Smart Chain, chain ID `56` |
| Status | Pre-deployment re-audit; not deployed |

## Contents

- `source/` — the 32-file first-party source closure and deployment script.
- `flat/` — nine self-contained upload units named
  `<Contract>.audit2.flat.sol`.
- `batches/` — upload locations only. Each flat is a separate paid review
  task; see [BATCHES_AUDIT2.md](BATCHES_AUDIT2.md).
- [SCOPE_AUDIT2.md](SCOPE_AUDIT2.md) — deploy graph and exclusions.
- [EXTERNAL_REVIEW_INPUTS_AUDIT2.md](EXTERNAL_REVIEW_INPUTS_AUDIT2.md) —
  historical PriceGuard input and review hypotheses.

Verify the package before review:

```sh
(cd source && shasum -a 256 -c SHA256SUMS.txt)
(cd flat && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(cd batches/01-capital-and-redemptions && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(cd batches/02-main-lifecycle && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(cd batches/03-pancake-venue && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(cd batches/04-pricing-and-swap-execution && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(shasum -a 256 -c PACKAGE_SHA256SUMS_AUDIT2.txt)
```

The batch copy of each flat is byte-identical to its `flat/` counterpart. Do
not concatenate flats: imported context repeats between upload units.

Each master flat was generated twice from a frozen full-repository export of
the candidate, with the tracked dependencies present, and the two outputs were
compared byte-for-byte. The generation primitive was:

```sh
forge flatten "src/<Contract>.sol" -o "audit2/flat/<Contract>.audit2.flat.sol"
```

## Independent acceptance and byte sizes

Independent acceptance of the exact candidate ran 429 focused non-fork tests:
429 PASS, 0 FAIL, 0 SKIP. It also checked the integration lineage, storage/API
surface, and targeted formatting. Fork-gated and monolithic test runs are not
represented as a pass here.

| Contract | Runtime bytes | EIP-170 margin |
|---|---:|---:|
| `DeepYieldVaultB` | 22,147 | 2,429 |
| `DedicatedVaultMainV2` | 21,644 | 2,932 |
| `DedicatedVaultStrategyAdapterV2` | 12,429 | 12,147 |
| `PancakeV3MasterchefVenue` | 19,612 | 4,964 |
| `VaultBPriceGuard` | 12,983 | 11,593 |
| `VaultBCakePriceGuard` | 11,975 | 12,601 |
| `BoundedPancakeExecutionAdapterV2` | 6,155 | 18,421 |
| `BoundedPancakeRewardAdapterV2` | 3,594 | 20,982 |
| `FixedFeeSink` | 5,882 | 18,694 |

All byte counts are deployed runtime bytecode after stripping a leading `0x`.

## Review request

For each finding, provide flat and raw-source locations, preconditions, an
exploit or failure scenario, severity rationale, and minimal remediation.
Follow the one-file paid-task boundaries in `BATCHES_AUDIT2.md`. A later
cross-contract integration assessment, if desired, must be a separately
scoped and funded task.
