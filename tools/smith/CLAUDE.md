# Smith — random differential testing for msc

Smith generates random deterministic MetaScript programs, runs them through the
existing corpus lanes, records divergences as reproducible bundles, and reduces
them. It tests the compiler; it is not part of the pipeline and nothing here
ships in a build.

Read `docs/DESIGN.md` before changing anything. Every rule below exists because
a measurement forced it — `docs/CSMITH-STUDY.md` holds the numbers. Update that
file by re-measuring, never by editing a number from reading alone.

## Commands — from the repo root

```bash
msc run tools/smith/main.ms gen 7                             # print the program for seed 7
msc run tools/smith/main.ms run 1 30                          # seeds 1..30 through the corpus lanes
msc run tools/smith/main.ms run 1 10 --plant=backend          # planted C↔JS divergence (opt: O0↔danger)
msc run tools/smith/main.ms run 1 30 --features="types=int32,float64 depth=2"
msc run tools/smith/main.ms run 1 3 --san                     # SAN lane (ASan + DRC ledger); bundle kind san, mode recorded
msc run tools/smith/main.ms run 1 3 --plant=san --san        # planted use after free; only the SAN lane judges it
msc run tools/smith/main.ms rerun out/smith/bundles/<name>    # VOID / NOT REPRODUCED / REPRODUCED
msc run tools/smith/main.ms run 1 20 --features="fams=async"  # opt-in family: native, spawn, actor, race, async run only when named
msc run tools/smith/main.ms gen 3 --features="modules=4 modshapes=cycle,alias,ns" --out=out/smith/p3   # a module tree
msc run tools/smith/main.ms run 1 20 --features="modules=3"   # project bundles (layout: project); reduce refuses them
msc run tools/smith/main.ms diag 1 40                         # diagnostic catalogue: legal twin + one-line mutant, pinned message and position
msc run tools/smith/main.ms diag 1 40 --plant                 # planted column shift; only wrong-position findings
msc run tools/smith/main.ms diag show 7                       # the case of one seed
msc test tools/smith/gen.ms                                   # generator, features and rng contracts
msc test tools/smith/proj.ms                                  # + the module-tree splitter
msc test tools/smith/diag.ms                                  # + the diagnostic catalogue (main.ms runs its CLI under test; not a test entry)
msc run tools/smith/main.ms cov 1 20 --msc=out/smith/cov/msc-cov   # per-pass coverage of a batch
tools/smith/campaign.sh tools/smith/campaign.txt out/smith/r3        # the matrix campaign, one batch at a time on a quiet machine
```

`cov` needs a coverage-instrumented compiler and the commit it was built from beside it:

```bash
msc build src/index.ms --release --cc=clang --lto=off \
  --passC="-fprofile-instr-generate -fcoverage-mapping" --passL="-fprofile-instr-generate" \
  --output=out/smith/cov/msc-cov && git rev-parse HEAD > out/smith/cov/msc-cov.src
```

The compiler under test follows the corpus convention: `MSC=<path>`, else `./msc`,
else the installed `msc`; the installed `msc` runs the harness. `MSCORPUS_LANES`,
`MSCORPUS_RAISER`, `MSCORPUS_JOBS`, `MSCORPUS_BUILD_JOBS` and
`MSCORPUS_CELL_TIMEOUT_MS` (Smith's default 60000) pass through to the runner.
The Raiser lane is off unless `MSCORPUS_RAISER=1`; a campaign that claims
Raiser evidence sets it. `diag` writes to `out/smith/diag/bundles/` (planted runs
to `plant-bundles/`) and judges `msc check` only, so it has no lanes.

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
- **Evidence is write-once.** A bundle directory is named by a hash of its
  metadata and program and is never rewritten; a rerun keeps its observation
  under `out/smith/reruns/`. A rerun is VOID when the metadata is missing or
  malformed, the lane set, support tree, corpus runner or compiler differ, or
  the program no longer regenerates.
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
