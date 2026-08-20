# Audit 2 — DeepYieldVaultB

Pinned file: https://github.com/Deepyield-labs/deepyield-vault-audit/blob/2d20f19f76051b621ea82b4982875d61cee0641e/audit2/reaudit-0241c37/flat/DeepYieldVaultB.reaudit.flat.sol

Candidate: source `0241c37ae56192936c6074d7944bcae1a95cf880`, package `2d20f19f76051b621ea82b4982875d61cee0641e`, BNB Smart Chain (chain ID 56), pre-deployment and not deployed.

Audit ONLY the linked flat file. Do not treat another paid task's contract as in-scope. Review ERC-4626 asset/share accounting; the asynchronous redeem cycle (`requestRedeem`, economic and full-queue commit, settlement, `claimRedeem`, cancellation, receiver update); idle-only sub-economic settlement; timeout force-settle recovery and its guardian/permissionless boundary; bounded external probes and rollback; loss-cap and 100%-exit-band math; the exact minimum-share residual boundary; deposit/mint gating during a cycle; deferred redeem-handle release; frozen queue-cap changes and commit retry; strategy migration; and Strategy-boundary assumptions. Strategy/Main implementations, live configuration, and graph-wide integration are context and out of scope. For every finding provide exact flat and raw-source locations, preconditions, an exploit or failure path, severity rationale, and a minimal remediation. Do not include unpaid cross-batch integration work.
