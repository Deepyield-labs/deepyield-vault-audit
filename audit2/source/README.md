# Raw source snapshot

This directory is the minimal 32-file first-party source closure for the Vault
B V2 deployment graph. The exact source identity is contract-repository commit
`18c1beb5071605385ecc0276322d87e6c6ea5652`. The files under `../flat/` were
generated independently from that same commit with solc `0.8.24`, optimizer
runs `200`, via-IR, Cancun, and IPFS metadata.

`SHA256SUMS.txt` covers every raw file here except itself. The snapshot omits
legacy, partner, HyperEVM, and other unreachable code. It also intentionally
omits `VaultFeesLib.sol`, which is not part of this deployment closure; see
`../SCOPE_AUDIT2.md`.
