# Audit 2 — Batch 04 upload queue

This directory contains **four separate paid tasks**, not one combined audit.
Upload one flat per request; do not add another task's contract as a required
review target.

| Task | File | Scope and residual handoff |
|---:|---|---|
| 6 | `VaultBPriceGuard.audit2.flat.sol` | WBNB oracle/TWAP integrity, deviations, normal/emergency loss budgets, caps, and configuration. See `../../EXTERNAL_REVIEW_INPUTS_AUDIT2.md`. Executor/Main policy is out of scope. |
| 7 | `BoundedPancakeExecutionAdapterV2.audit2.flat.sol` | WBNB swap binding, approvals/input accounting, minimums/deadlines, and observed output/router mismatch handling. Guard/Main policy is out of scope. |
| 8 | `VaultBCakePriceGuard.audit2.flat.sol` | CAKE source integrity, decimal handling, divergence, active-window consumed-notional retention, emergency budgets, caps, and configuration. Reward adapter/Main policy is out of scope. |
| 9 | `BoundedPancakeRewardAdapterV2.audit2.flat.sol` | CAKE swap binding, approvals/input accounting, minimums/deadlines, observed output/router mismatch handling, and emergency-budget consumption only after settlement/output checks. Guard/Main policy is out of scope. |

A Main/guards/adapters integration review, if wanted after these four
independent reviews, must be separately funded and scoped.
