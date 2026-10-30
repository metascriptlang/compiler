# Tests — where a test goes and how it runs

Examples per tier, the corpus directive contract, the two-tree convention and the emit-diff recipe: [`docs/TESTING.md`](../../docs/TESTING.md).

When measuring TypeScript compatibility, read [`compat/typescript/README.md`](compat/typescript/README.md) for the optional oracle lane's commands and interpretation, because backend parity alone does not establish TS compatibility.

## Where a test goes

| Tier | Lives in | Use for |
|---|---|---|
| Inline `test "…" { }` | the module under test | function-level invariants — one assertion concept per test, the name states the invariant, `assert` only |
| Language | `lang/*.ms` | user-visible behaviour end to end — no compiler imports, one file per feature group |
| Pipeline | `c/*.ms`, `js/*.ms` | emitted C/JS through `compileToC` / `compileToJS` — pin the load-bearing tokens, pair with a `lang/` test that runs the code |
| Phase handoff | `handoff/*.ms` | contracts between adjacent phases |
| Corpus | `corpus/programs/<invariant>.ms` or `<invariant>/main.ms` | standalone programs byte-compared across lanes — the contract lives in the `// @…` directive head |
| Lifecycle guard | `guard/*.ms` | one DRC-ledger invariant per file, trusted only after it was proven red (`guard/README.md`) |

- **Register each runnable test module** in its `lang/`, `handoff/`, `c/` or `js/` index. Corpus and lifecycle-guard runners discover standalone entries; imported fixture modules are not entries.
- **Place new regressions by their invariant and consumer boundary**, not a bug number.
- **A `<module>Parked.ms` stays unregistered.** It holds the contracts of that module that are red because of an open compiler bug; the inbox card names it on its `Parked at:` line, and the fixing session moves its tests into the module and deletes it.
- **Corpus stdout is deterministic** — no timers, randomness, addresses, RSS or timing prints; ordered output, fixed loop bounds. Extend an existing invariant program when a variant shares its oracle.

## Anti-patterns

- Tests in `/tmp/` or `examples/` — always under `src/test/`, because no runner or gate discovers them elsewhere.
- One mega-test that asserts twenty things — split it, so a failure names the invariant.
- `console.log` inside a `test` block — its runner does not inspect stdout for correctness. Standalone corpus programs use stdout as their oracle.
- Skipping a flaky test instead of root-causing it, because the skip hides a race the gate meets again.
- Coverage by self-host alone — self-host green says the compiler compiles itself, not that the feature works.
- A fix where DU + generics + RC + closures interact without a test of that exact combination.
- Fuzzy comparison in a differential runner — fix the program or classify it out with `@xfail(<lane>)` and a reason; any normalization is enumerated in the runner with its reason.
- A test outside its obvious tier without a header comment saying why and where its siblings live.

## Running

Every heavy job (workspace `CLAUDE.md` §Shared machines: any compiler build, any test runner including `msc test <file>`, a corpus, guard, SAN, perf, fmt or LSP run, whatever its length) goes to a gate host through `~/metascript/.gate-host/run-remote.sh`, and to the Mac only with `MAC_ONLY=1` when it needs macOS. `run-remote.sh` copies only tracked and unignored files and each call may pick another host, so `./msc` never travels: build the candidate and run every check that uses it in one call:

```bash
~/metascript/.gate-host/run-remote.sh --cores 8 --job "<session>: <what>" -- bash -c \
  'msc build src/index.ms --danger --lto=off --output=msc && ./msc test <owner-file> --tests-in-dir && MSC=$PWD/msc MSCORPUS_ONLY=<names> msc run src/test/corpus/run.ms'
```

`msc` on the host's `PATH` is the last synced build (`~/.metascript/BUILD`), not the slice's merge base. When the slice changes `std/meta` or anything else the compiler imports from std, build with a builder at the tree root, because the host's `msc` loads its own std: `cp "$(command -v msc)" builder && ./builder build src/index.ms --danger --lto=off --output=msc`. Light work stays on the Mac: edits, reads, `./msc check src/index.ms`, emitting one small program.

Every run belongs to one of three flows, chosen by when it runs:

| flow | when | what runs | wall |
|---|---|---|---|
| **edit loop** | while a slice is in work, including before each commit; ends at ready | `./msc check src/index.ms`, then one check per changed contract, red on the old compiler and green on the candidate; last, the ready check | candidate build 2–2.5 min on 8 cores, then under 60 s per check; ready check 10–20 min on Linux |
| **land gate** | once per slice, submitted the moment it is finished and ready (workspace `CLAUDE.md` §Worktrees and landing) | `tools/gate.sh` through the gate queue: lanes picked from the diff, compared with `known-red.json` | `~/metascript/.gate-host/README.md` §The gate; waited on with `gate-queue wait` in the background |
| **release ladder** | cutting a release (`docs/GIT-FLOW.md`); landing on `main` and syncing the binary are not releases | `tools/gate.sh --release` plus the fixpoint check | hours |

Lanes, `msc test src/index.ms`, the tier indexes and corpus sweeps run only in the land gate and the release ladder, because one of them during an edit holds a host and the person for tens of minutes while the land gate runs it anyway.

### Edit loop

When a check changes cache state or compares reuse, give it a fresh `MSC_CACHE_DIR` and a
fresh `HOME` (or `MSC_NO_GLOBAL_CACHE=1`) as [BUILD-CACHE.md](../../docs/BUILD-CACHE.md)
describes, because a fresh working directory alone still inherits an exported `MSC_CACHE_DIR`
and the shared global store. Keep the perf runner's cold controls cold.

**Check the changed contract with its smallest real consumer, in under 60 s per check.** Build one candidate when compiler code changed, then prove the regression red on the old compiler and green on the candidate, including the required backend variants. You choose the checks from the diff. The loop ends with the ready check, `~/metascript/.gate-host/README.md` §Ready: the slice merged onto current `main`, built as a Linux candidate, every test of its own green on every cell it runs in, a self-host chain when it changes what the compiler does to itself, and the shared records it moves re-recorded (`gate-queue ready-check <slice> <host>` automates the candidate and the derived own tests, not the self-host chain). The land gate catches interactions between slices, not what the loop skipped, because a slice's own red found there costs a full gate on a shared host. When the smallest consumer cannot finish in 60 s, run it once and add it with its measurement to `docs/TESTING.md` §Edit-loop check costs.

Build a candidate per compiler edit, in the same `run-remote.sh` call as the checks that use it (above). Prove red with the test on a candidate built without the fix (build once before applying it, the TDD order), or on the host's `msc` when the installed build still shows the bug. Then one check per changed contract:

| the diff changes | check | measured |
|---|---|---|
| a function or language invariant in one module | `./msc test <owner-file> --tests-in-dir` | 4–50 s |
| program output, exit status or lifetime | `MSC=./msc MSCORPUS_ONLY=<exact,names> msc run src/test/corpus/run.ms`; add `MSCORPUS_RAISER=1` when the diff adds or edits that program, and `MSCORPUS_SAN=1` for its SAN contract | 4–10 s per program; the Raiser cells about 0.25 s each |
| one lifecycle invariant | `MSC=./msc GUARD_ONLY=<names> msc run --target=raiser src/test/guard/run.ms`; keep its ledger oracle (`guard/README.md`) | 1–5 s per guard |
| what one program emits | `./msc build <prog.ms> --emit=c`, then read that module's C | seconds |
| the cost of one flow | `MSPERF_BASE=<old msc> MSPERF_PROGRAMS=711 MSPERF_RUNS=1 msc run src/test/perf/run.ms`, read the rows of the flow you changed (`docs/BUILD-PERF.md` §Measuring by flow) | one program per arm |
| formatting | `MSFMT_ROOTS=<dir> msc run src/test/fmt/run.ms` on the directories you changed | 6.6–13.5 s for `src/utils` |
| LSP behaviour | `msc run src/test/lsp/run.ms` (the replay scenarios) | 37–44 s |
| Solana, native boundary or HCR | the named failing consumer with its host and backend; recipes in `docs/TESTING.md` | not measured |
| `std/` or `runtime/` inputs | the checks above, with a candidate beside the changed support trees; `tools/syncLocalBinary.ms` belongs to delivery | as above |

- **`msc test <file>` without `--tests-in-dir` also runs the tests of every module the file imports.** For `src/analyzer/inject.ms` that is 102 test files in 85–122 s, against 7 files with the flag (lc-1, tree 651e100ee).
- **Split a performance question by flow.** Run one program and one flow per measurement (`MSC_FLOWS`, `MS_DRC_STAT`, `src/test/perf/emitCostScan.ms --diff`, or one program under `perf record`); a whole-compiler A/B waits for the land.
- **Measured per-file costs and the checks over budget** are in [`docs/TESTING.md`](../../docs/TESTING.md) §Edit-loop check costs; a check that cannot finish in 60 s is added there with its measurement.
- **The guard runner's JS leg calls `msc` from `PATH`.** A host without it reports exit 127 as a red guard.

### Land gate

**When the slice is finished, run its ready check and submit it at once** (`gate-queue ready-check`, `submit`, then `wait` in the background; workspace `CLAUDE.md` §Worktrees and landing, the Mac land queue only when that section says so). Do not run a separate gate first, because that duplicates the land gate. `tools/gate.sh --dry-run` proposes lanes to compare with the changed contract.

**After a RED, return to the edit loop: rerun the named failures (`queue/<slice>.red`) through `run-remote.sh` on a candidate of the tip, redo the ready check, then submit the new tip** (`~/metascript/.gate-host/README.md` §RED). The corpus FAIL line quotes the stdout the cell printed. Fix new reds; let the existing known-now-green pruning handle entries the gate proved green. Do not use another full gate to find out whether the same failure remains.

### Traps

- **A compiler reads `std/` and `runtime/` from beside its own binary** — `./msc` is the candidate with this repo's trees, `msc` on `PATH` is the last published build with `~/.metascript/`.
- **Runners test `./msc` when it exists, else the installed `msc`** — `MSC=<path>` overrides, and the runner header prints the choice.
- **`msc run <runner>` runs the harness, `MSC` names the subject** — `./msc run <runner>` alone inverts that: the harness gets the new compiler while every program is still built by the old one.
- **One `msc` build at a time per tree, and never `rm -rf out` first** — both produce a red that names a different file every run; check `uptime` before trusting a timing.
- **Checker-source handoff contracts run natively**; a runtime/backend claim additionally needs a real language or corpus consumer.
- **The owning tier indexes are land-gate entries**. `src/test/index.ms` is not; run a new module with `msc test <file> --tests-in-dir` and register it in its owning tier index, which the land gate runs.

## When you fix a bug

1. Reproduce it with a minimal program and save it.
2. Apply the fix.
3. Add a contract to the owner module under `lang/`, `handoff/`, `c/` or `js/`, or create a semantic family there when no owner exists. Import new runnable modules in the tier index.
4. If the bug changes program output or exit status, add a standalone semantic corpus consumer with an absolute expected oracle, and exercise its required backends. A duplicate of the same owner and oracle is not a new contract.
5. If found by self-host, prove the user-visible path with a focused language test.
6. Run the focused regression in the edit loop, plus the owning-tier module when discovery or integration needs it. When the slice is ready, submit it to the land gate as above; the land gate must show no new red.

A user-visible feature lands together with the corpus programs that pin its observable behaviour through every lane.
