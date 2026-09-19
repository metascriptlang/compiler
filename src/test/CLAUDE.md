# Tests — where a test goes and how it runs

Examples per tier, the corpus directive contract, the two-tree convention and the emit-diff recipe: [`docs/TESTING.md`](../../docs/TESTING.md).

## Where a test goes

| Tier | Lives in | Use for |
|---|---|---|
| Inline `test "…" { }` | the module under test | function-level invariants — one assertion concept per test, the name states the invariant, `assert` only |
| Language | `lang/*.ms` | user-visible behaviour end to end — no compiler imports, one file per feature group |
| Regression | `fixedbugs/bugNNN_short_slug.ms` | one file per shipped bug — header `Symptom / Root cause / Fix`, test name `"bugNNN: <slug>"`, next free number |
| Pipeline | `c/*.ms`, `js/*.ms` | emitted C/JS through `compileToC` / `compileToJS` — pin the load-bearing tokens, pair with a `lang/` test that runs the code |
| Phase handoff | `handoff/*.ms` | contracts between adjacent phases |
| Corpus | `corpus/programs/NNN-topic.ms` | standalone programs byte-compared across lanes — the contract lives in the `// @…` directive head |
| Lifecycle guard | `guard/*.ms` | one DRC-ledger invariant per file, trusted only after it was proven red (`guard/README.md`) |

- **Every test file is wired into an index** — the entries import an explicit list; a file nobody imports is silently never run and looks like coverage that does not exist.
- **`fixedbugs/` and `corpus/programs/` are append-only** — when the API changes, adapt the surface and keep the repro.
- **Corpus stdout is deterministic** — no timers, no randomness, no addresses, no RSS or timing prints; ordered output, fixed loop bounds.

## Anti-patterns

- Tests in `/tmp/` or `examples/` — always under `src/test/`.
- One mega-test that asserts twenty things — split it, so a failure names the invariant.
- `console.log` in tests — the runner does not inspect stdout for correctness.
- Skipping a flaky test instead of root-causing it.
- Coverage by self-host alone — self-host green says the compiler compiles itself, not that the feature works.
- A fix where DU + generics + RC + closures interact without a test of that exact combination.
- Fuzzy comparison in a differential runner — fix the program or classify it out with `@xfail(<lane>)` and a reason; any normalization is enumerated in the runner with its reason.
- A test outside its obvious tier without a header comment saying why and where its siblings live.

## Running

**Run `tools/gate.sh`.** It picks the lanes from the paths a change touches and compares every red with `src/test/known-red.json`; `--dry-run` prints the choice, `--release` runs the full ladder. Reach for a row by hand only inside a debug loop.

| Situation | Command |
|---|---|
| Inner loop — any compiler edit | `msc test src/index.ms`, or `msc test <file>` for that file plus its transitive dep tests |
| Same, under the cycle collector | `msc test src/index.ms --gc=orc` |
| Touched codegen / DRC / runtime / transform | + `msc run src/test/corpus/run.ms` |
| Touched DRC hooks, lifetimes, ownership | + `MSCORPUS_SAN=1 msc run src/test/corpus/run.ms` and `src/test/guard/run.sh` |
| Touched `std/` or anything users compile against | rebuild + `tools/sync-local-binary.sh` first, then re-run the above |

- **A compiler reads `std/` and `runtime/` from beside its own binary** — `./msc` is the candidate with this repo's trees, `msc` on `PATH` is the last published build with `~/.metascript/`.
- **Runners test `./msc` when it exists, else the installed `msc`** — `MSC=<path>` overrides, and the runner header prints the choice.
- **`msc run <runner>` runs the harness, `MSC` names the subject** — `./msc run <runner>` alone inverts that: the harness gets the new compiler while every program is still built by the old one.
- **One `msc` build at a time per tree, and never `rm -rf out` first** — both produce a red that names a different file every run; check `uptime` before trusting a timing.
- **A `fixedbugs/bugNNN` test runs the source checker** — it proves red and green for a checker or codegen rule before any rebuild.

## When you fix a bug

1. Reproduce it with a minimal program and save it.
2. Apply the fix.
3. Turn the repro into `fixedbugs/bugNNN_short_slug.ms` with the header block, and import it in `fixedbugs/index.ms`.
4. If the bug shows in a program's stdout or exit code (codegen, DRC, runtime), also add it to `corpus/programs/` — one file then guards both backends and every lane.
5. If it was found through self-host, also add a focused `lang/*.ms` test.
6. `msc test` the files you touched, then `msc test src/index.ms` — no new red.

A user-visible feature lands together with the corpus programs that pin its observable behaviour through every lane.
