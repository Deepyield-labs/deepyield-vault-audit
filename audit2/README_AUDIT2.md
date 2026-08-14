# Vault B V2 — Audit 2, Round 9 candidate

This is a separate pre-deployment audit package. It is intentionally isolated
from the historical scope in the repository root and is not a deployment
approval or a claim that historical findings are remediated.

| Field | Value |
|---|---|
| Candidate source commit | `65b8af752beb2a86c000363bba255a4e1ef66297` |
| Compiler | solc `0.8.24`, optimizer runs `200`, via-IR |
| Chain target | BNB Smart Chain, chain ID `56` |
| Status | Pre-audit; not deployed |

## Contents

- `source/` — first-party deploy-graph source closure and deployment script.
  Solidity source filenames remain canonical so imports and source checksums
  remain reproducible.
- `flat/` — nine self-contained flats, each named
  `<Contract>.audit2.flat.sol`.
- `batches/` — four auditor upload queues; see
  [BATCHES_AUDIT2.md](BATCHES_AUDIT2.md).
- [SCOPE_AUDIT2.md](SCOPE_AUDIT2.md) — exact in-scope graph and exclusions.
- [EXTERNAL_REVIEW_INPUTS_AUDIT2.md](EXTERNAL_REVIEW_INPUTS_AUDIT2.md) —
  historical PriceGuard report and required re-evaluation topics.

Verify the raw source and flats before review:

```sh
(cd source && shasum -a 256 -c SHA256SUMS.txt)
(cd flat && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
(cd batches/01-capital-and-redemptions && shasum -a 256 -c SHA256SUMS_AUDIT2.txt)
```

The same check applies to each remaining batch. A flat is one upload unit;
do not concatenate flats because imported context repeats between them.

## QA and size record

Targeted non-fork checks at the candidate commit:

| Check | Result |
|---|---:|
| Deploy dry-run | 4 PASS / 0 FAIL |
| Main H-1/H-3 red witnesses | 4 PASS / 0 FAIL |
| Venue red witnesses | 10 PASS / 0 FAIL |
| Venue adversarial suite | 41 PASS / 0 FAIL |

The suite was not run as one monolithic command. Archive-dependent fork
coverage is not represented as a pass.

`DeepYieldVaultB` runtime is 22,576 bytes, leaving 2,000 bytes to EIP-170.
Any further Vault change requires a size review before implementation.

## Review request

Report vulnerabilities, economic/accounting defects, authorization failures,
denial-of-service and withdrawal-liveness risks, and configuration risks. For
each issue provide raw-source and flat locations, preconditions, exploit or
failure scenario, severity rationale, and a minimal remediation.
