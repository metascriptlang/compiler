# Smith — random differential testing for msc

Smith generates random deterministic MetaScript programs, runs them through the
existing corpus lanes, records divergences as reproducible bundles, and reduces
them. It tests the compiler; it is not part of the pipeline and nothing here
ships in a build.

Read `docs/DESIGN.md` before changing anything. Every rule below exists because
a measurement forced it — `docs/CSMITH-STUDY.md` holds the numbers. Update that
file by re-measuring, never by editing a number from reading alone.

## Hard rules

- **Nothing generated is committed.** Programs, bundles, logs and reduced
  candidates live under `out/smith/` (untracked). The only artifacts that enter
  the repo are reduced, confirmed regressions, and they enter as corpus
  programs under `src/test/corpus/programs/`, named by invariant per the
  contract in `docs/TESTING.md` — never as smith output.
- **The bundle is the unit of evidence**: seed, feature vector, generator
  commit, msc build and support-tree commit, per-lane outputs. A bundle that
  does not rerun byte-identically from its metadata is void.
- **No single oracle.** Lane agreement (C-drc / C-orc / C-danger ↔ JS ↔
  raiser) plus the SAN ledger is the oracle; a digest alone never closes a case
  (collisions measured, CSMITH-STUDY §Oracle). Identical failure on every lane
  is UNRATED, not green.
- **A timeout is not a bug** until a longer deadline proves it
  (CSMITH-STUDY §Driver).
- **Reduction predicates pin failure identity** — lane pair, symptom, and the
  type/width axis of the failure. A reduction that moves the axis is rejected;
  loose predicates drift (CSMITH-STUDY §Reduction).
- **The Csmith checkout is a read-only reference.** Take mechanisms, never
  source. Its machine-local path lives on the arc card, not in tracked files.
- Lane policy, known-red and "no heavy lane beside the gate" are inherited from
  the root `CLAUDE.md` and `docs/TESTING.md`. Smith adds no second test runner:
  it drives the corpus lanes with their own semantics (`MSCORPUS_*`).
