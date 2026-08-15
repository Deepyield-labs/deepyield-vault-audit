# External review input — PriceGuard re-audit

The requester supplied a prior independent review as context for the separate
`VaultBPriceGuard.audit2.flat.sol` task:

| Field | Value |
|---|---|
| Immutable CID | `bafkreidqe54b2w5w2m3cuwnp6j6725ze7lr5cg6et3u5ml22mesoyv4ddy` |
| Public gateway URL | `https://bafkreidqe54b2w5w2m3cuwnp6j6725ze7lr5cg6et3u5ml22mesoyv4ddy.ipfs.community.bgipfs.com/` |
| Downloaded document SHA-256 | `7027781d5bb6d3362a59aff27dfd7724fae3d11bc49ee9d62f5a6124ec57831e` |
| Historical repository commit | `a5a529b7044b74015c748e6fbeb443b4ad866fdc` |
| Relationship to this package | Input only; it did not audit candidate `18c1beb5071605385ecc0276322d87e6c6ea5652` |

The historical report recorded 1 High, 9 Medium, 10 Low, and 10 Informational
items. It is not copied into this package. Verify the CID and SHA-256 before
consulting it.

## Review hypotheses for the single WBNB PriceGuard task

Treat these as hypotheses, not assertions that a historical finding is fixed:

1. Emergency deviation tolerance versus granted loss tolerance, including
   equality.
2. Notional exhaustion under a live oracle/TWAP gap.
3. Pool liquidity, observation cardinality, stale/abandoned pools, and TWAP
   manipulation cost at the configured tier/window.
4. Emergency activation/reset and cumulative exposure within an incident.
5. Feed ages, cross-feed timing, factory provenance, token decimals, and
   deployment-time immutable parameters.
6. Authority and monitoring implications of admin, guardian, and emergency
   consumer roles.

Quote-to-swap binding and adapter output accounting belong to their own paid
adapter tasks. A combined Main/guard/adapter review is not required of this
single-file task; it may be commissioned separately after the individual work.
