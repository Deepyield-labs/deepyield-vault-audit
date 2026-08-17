# Audit 2 — Batch 04 upload queue

These four flats are packaged for later separately authorized tasks; none is
part of the initial three-review tranche. If commissioned, upload one flat per
request and keep the other implementations as canonical reachability context.

| Technical unit | File | Scope and residual handoff |
|---:|---|---|
| 6 | `VaultBPriceGuard.audit2.flat.sol` | WBNB oracle/TWAP integrity, deviation, normal/emergency capacity, conservative UPPER notional, feed failure and immutable configuration. See `../../EXTERNAL_REVIEW_INPUTS_AUDIT2.md`. |
| 7 | `BoundedPancakeExecutionAdapterV2.audit2.flat.sol` | One-shot Main binding, approvals/input accounting, minimums/deadlines, observed output/router mismatch, and final-debit rollback. |
| 8 | `VaultBCakePriceGuard.audit2.flat.sol` | Direct/cross-pool plus independent CAKE/USD reference integrity, decimal/freshness handling, divergence, LOWER fair value, UPPER cap notional, snapshot capacity, and emergency budget policy. |
| 9 | `BoundedPancakeRewardAdapterV2.audit2.flat.sol` | One-shot Main binding, approvals/input accounting, minimums/deadlines, observed output/router mismatch, and emergency-budget consumption only after settlement/output checks. |

A Main/guards/adapters integration review, if wanted after these four
independent reviews, must be separately funded and scoped.
