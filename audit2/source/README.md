# Raw source snapshot

This directory is the minimal first-party source closure for the Vault
B V2 deployment graph. The exact source identity is contract-repository commit
`27e1e617296dde8c0dc1ff621eeec3a3b10b409d`. The files under `../flat/` were
generated independently from that same commit with solc `0.8.24`, optimizer
runs `200`, via-IR, Cancun, and IPFS metadata.

`SHA256SUMS.txt` covers every raw file here except itself. The snapshot omits
legacy, partner, HyperEVM, and other unreachable code. It also intentionally
omits `VaultFeesLib.sol`, which is not part of this deployment closure; see
`../SCOPE_AUDIT2.md`.

`DeployVaultBV2BroadcastRehearsal.s.sol` is also omitted: it is a local
failure-rehearsal harness, not imported by the production deployment script or
any of the nine deployables.
