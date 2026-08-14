# Audit 2 — Batch 04: pricing and swap execution

Upload the four files in `flat/` individually.

Review both PriceGuards and bounded execution adapters for oracle/TWAP source
integrity, emergency loss/deviation policy, capacity accounting, quote-to-swap
binding, deadlines, pool/feed provenance, token decimals and deployment
parameters.

Explicitly re-evaluate the historical PriceGuard review hypotheses in
`../../EXTERNAL_REVIEW_INPUTS_AUDIT2.md`. Then assess all guards/adapters
together with Main in Batch 02; isolated policy checks are insufficient.
