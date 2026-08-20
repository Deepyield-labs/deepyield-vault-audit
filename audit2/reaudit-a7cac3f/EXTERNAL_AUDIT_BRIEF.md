# Audit 2 — DeepYieldVaultB

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/746f45bf118a6e1034f25f82db6d2769f22a01e8/audit2/reaudit-a7cac3f/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `a7cac3f790a7a803124f5033942d17fe65a6b390`, package
`746f45bf118a6e1034f25f82db6d2769f22a01e8`, BNB Smart Chain (chain ID 56),
pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as
in-scope. Review ERC-4626 asset/share accounting; the asynchronous redeem cycle
(`requestRedeem`, economic and full-queue commit, settlement, `claimRedeem`,
cancellation, and receiver update); empty-queue deficit funding; idle-only
sub-economic settlement; the batch-denominated execution-loss cap; timeout
force-settle authorization and partial-share burn/return; deposit/mint and async
admission gates during pause, an active cycle, and strategy migration; observed-
balance liquidity pulls and the claimable reserve; the frozen queue-open
threshold; preview/execution agreement; the value-denominated residual band;
deferred old-graph handles; malformed token-return escrow; upper/lower NAV
ordering; sub-minimum max-deposit behavior; and zero-share deposits.

The linked `VaultBDepositLib`, Strategy/Main implementations, live configuration,
and graph-wide integration are context and out of scope except where their
boundary assumptions are embedded in the linked Vault flat. Do not perform
unpaid component audits or graph-wide integration work.

For every finding provide exact flat and raw-source locations, preconditions, an
exploit or failure path, severity rationale, and a minimal remediation.
