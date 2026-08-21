# Final candidate `1da3f7c` — locked design decisions

The two remaining items are genuine either/or tradeoffs (you cannot have both). Industry
practice: pick the side that rules out the catastrophic outcome (permanently frozen / trapped
funds), document and accept the narrow residual. Both are LOCKED below; the contract already
implements them, so no core-settlement change is made (avoids regression risk).

## 1. Recovery gate → LIVENESS (no permanent freeze). LOCKED.
`forceSettleStuckCycle` is timeout-only: after 7 days anyone may settle a stuck cycle pari-passu
from idle, regardless of the strategy view.
- Chosen because a permanent freeze (funds locked forever) is the unacceptable outcome; a bounded
  worst-case payout after a long timeout is acceptable. This is the standard async-redeem escape hatch.
- Accepted residual: if a HEALTHY strategy's cycle is left unclaimed for 7+ days it could be settled
  from idle, forfeiting its deployed-value share. In practice a healthy strategy delivers in hours and
  holders claim well before 7 days, so this window is effectively unreachable.

## 2. Exit gate during a strategy outage → DON'T TRAP (fail-open). LOCKED.
`cancelRedeem`/`updateRedeemReceiver` fail open when the strategy view reverts: an owner can always
cancel an uncommitted request during an outage.
- Chosen because access to one's own funds outranks perfect loss-attribution; never trapping a user is
  the standard default.
- Accepted residual: a narrow window in which a committed batch could be exited loss-free, shifting
  that loss to remaining holders. Bounded, and the treasury/guardian backstops exist.
- Ideal future hardening (not shipped): a monotonic "Main committed" latch giving BOTH properties
  (don't-trap AND don't-escape). Deferred — it is a core-settlement change that could not be safely
  verified in this environment; the safe standard side is locked instead.

## Everything else
- Loss-cap charge formula: unchanged by design (the exiting batch bears the loss it causes; remaining
  holders absorb none). Not a defect.
- Remaining Low/defensive/policy items (F-7 NAV upper>=lower, tolerant cancel, exotic-token handling,
  admin timelock, pause scope): documented; none is a fund-theft path. 0 Critical across all passes.
