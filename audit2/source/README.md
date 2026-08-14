# Raw source snapshot

This directory is a minimal first-party source closure for the Round 9 deploy
graph. It excludes dead/legacy products by design; see `../SCOPE.md`.

The exact source identity is commit
`65b8af752beb2a86c000363bba255a4e1ef66297` of the contract repository. The
files under `flat/` are generated from that same commit and include vendored
dependency context for self-contained review. `SHA256SUMS.txt` covers every raw
file in this directory except itself.
