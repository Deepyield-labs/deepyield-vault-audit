# External review input — PriceGuard re-audit

The requester supplied a prior independent re-audit as an input to this new
engagement:

| Field | Value |
|---|---|
| Immutable CID | `bafkreidqe54b2w5w2m3cuwnp6j6725ze7lr5cg6et3u5ml22mesoyv4ddy` |
| Public gateway URL | `https://bafkreidqe54b2w5w2m3cuwnp6j6725ze7lr5cg6et3u5ml22mesoyv4ddy.ipfs.community.bgipfs.com/` |
| Downloaded document SHA-256 | `7027781d5bb6d3362a59aff27dfd7724fae3d11bc49ee9d62f5a6124ec57831e` |
| Report target | historical `VaultBPriceGuard.flat.sol` |
| Historical repository commit | `a5a529b7044b74015c748e6fbeb443b4ad866fdc` |
| Relationship to this package | Input only; it did **not** audit candidate `65b8af7` |

The historical report recorded 1 High, 9 Medium, 10 Low, and 10 Informational
items. It is not copied into this package: verify the CID and SHA-256 above
before consulting it.

## Mandatory re-evaluation topics

Treat the following as review hypotheses, not as remediated findings:

1. Whether emergency deviation tolerance is correctly coupled to the actual
   granted loss tolerance, including the equality case.
2. Whether notional exhaustion has the intended loss/deviation/liveness
   behavior under a live oracle/TWAP gap.
3. Pool liquidity, observation cardinality, stale or abandoned-pool behavior,
   and the economic cost of TWAP manipulation at the configured tier/window.
4. Binding from emergency quote to actual successful swap and accounting of
   emergency notional; the swap adapters are in scope in this package and must
   be reviewed together with `VaultBPriceGuard`.
5. Re-activation/reset behavior of emergency budgets and possible cumulative
   exposure across one incident.
6. Aggregator-bound probe failure behavior, feed-age settings, cross-feed time
   correlation, pool factory provenance, token-decimal assumptions, and
   deployment-time immutable parameters.
7. Authority and monitoring implications of admin, guardian, and emergency
   consumer roles.

## Candidate delta that also requires review

After the historical report's commit, this candidate adds
`VaultBPriceGuard.recoveryClosePolicy` and uses it from the staged
`DedicatedVaultMainV2.recoverCloseDecrease` path. The new method selects one
oracle/loss/deviation snapshot for an LP decrease but does not consume swap
capacity itself. Review its full-LP notional construction, normal-policy
degradation, zero-leg behavior, spot-reference coherence, and interaction with
the later adapter liquidation. No statement in this package classifies the
historical report's findings as fixed.
