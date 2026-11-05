# Moves and lifecycle

Current contracts are in [LANG.md](LANG.md#move-semantics), including parameter modes,
[collection storage](LANG.md#collection-storage-contracts) and lifecycle hooks. Authoring
choices belong to [LANG-PREFERENCE.md](LANG-PREFERENCE.md); implementation rationale belongs
to [ANALYZER.md](ANALYZER.md).

Do not infer a copy policy from the word “move”: shared arrays and copied values have
different assignment semantics. Do not infer reference parity from one lowering path or
an accepted ownership annotation. [Advanced contracts](CONTRACTS.md) separates those proofs.

The old binary last-use/deep-copy decision tree, zero-copy-tool table and “100% parity”
roadmap are retired. They conflated shared `T[]` with value arrays and described stale
parameter/view mechanisms. `git log -- docs/LANG-MOVE.md` retains that implementation history;
it is not an alternate specification.
