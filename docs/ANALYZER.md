# Analyzer: lifecycle placement

Phase 4 places lifecycle operations for C and Raiser; JS uses its own value-copy emission.
The source entry is `analyzeProgram` in `src/analyzer/index.ms`. Raiser reaches it through
`analyzeForRaiser` in `src/codegen/raiser/rgen.ms`, not a VM-store counting policy.
Phase ordering is in [PIPELINE.md](PIPELINE.md); editing obligations are in
[src/analyzer/CLAUDE.md](../src/analyzer/CLAUDE.md).

## Why placement is separate from representation

A copy, move, borrow and shared reference need not perform the same runtime operation.
Classification must use the actual type/storage contract, not infer deep copying from the
word “array” or ownership from a pointer-shaped C value. The emitter must not rediscover
lifetime decisions after the analyzer has placed them.

Hook generation, placement and optimization have separate jobs: a generated cleanup body
does not decide where it runs, and removing a redundant operation must not erase cleanup
owed on another path. For an aliased destructive assignment, the source must survive the
old destination's destruction. Finally/defer reads and exception exits are obligations too,
not only the straight-line last read.

The decision owners are `moveOrCopy`/`generateCleanup` in `inject.ms`, classification in
`classify.ms`, last-read/alias analysis in `cfg.ms`/`alias.ms`, cursor inference in
`cursors.ms`, and `optimizeDrc` in `optimize.ms`. Consult them rather than maintaining a
second algorithm or insertion-point inventory here. In particular, source shapes with a
non-owning annotation still need the proof described in [Advanced contracts](CONTRACTS.md).

## Historical measurements, not current certification

Preserved from the earlier document, not rerun for this rewrite:

- 2026-09-21: self-host and 223 corpus programs emitted byte-identical C after lifecycle-op
  identity replaced name matching; 119 destroys were removed, all on runtime operations.
  The original observation did not record its tree.
- 2026-09-22, tree `5158d70c07c173380e72a42f99f1d58003dff425`: 3789/3789 tests passed;
  self-host generations 1/2 emitted 326 identical C modules. JS self-host stopped before
  emission on unavailable std crypto/zip imports; it was not verified.
- 2026-09-20: a probe over 51 corpus programs numbered 000–307 and a small control did not
  reach the For/ForOf/Match statement arms; Switch did arrive. The other 169 programs and
  self-host were not measured, and the record supplied no tree. This is not permission to
  delete an unreached arm.
- 2026-09-21: 44,700 last-read queries over self-host and 223 corpus programs changed 588
  copy decisions to moves after symbol-keyed CFGs replaced name keys: 362 differed in
  defs/reachability and 224 were old misses (222 `postBytes`). The exact separating edge/def
  in the 362 and the original tree were not recorded.

Those results do not prove current optimization, control coverage, leak freedom or alias
safety. A changed invariant needs its smallest real consumer and required runtime/backend
checks; the land gate observes interactions, not a blanket safety property.
