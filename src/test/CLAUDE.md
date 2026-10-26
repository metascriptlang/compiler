# Tests — where a test goes and how it runs

Examples per tier, the corpus directive contract, the two-tree convention and the emit-diff recipe: [`docs/TESTING.md`](../../docs/TESTING.md).

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

- Tests in `/tmp/` or `examples/` — always under `src/test/`.
- One mega-test that asserts twenty things — split it, so a failure names the invariant.
- `console.log` inside a `test` block — its runner does not inspect stdout for correctness. Standalone corpus programs use stdout as their oracle.
- Skipping a flaky test instead of root-causing it.
- Coverage by self-host alone — self-host green says the compiler compiles itself, not that the feature works.
- A fix where DU + generics + RC + closures interact without a test of that exact combination.
- Fuzzy comparison in a differential runner — fix the program or classify it out with `@xfail(<lane>)` and a reason; any normalization is enumerated in the runner with its reason.
- A test outside its obvious tier without a header comment saying why and where its siblings live.

## Running

Every run belongs to one of three flows, chosen by when it runs:

| flow | when | what runs | wall |
|---|---|---|---|
| **edit loop** | while a slice is in work, including before each commit | `./msc check src/index.ms`, then one check per changed contract, red on the old compiler and green on the candidate | candidate build 2–2.5 min, then under 60 s per check |
| **land gate** | once, when something outside the worktree needs the commits (root `CLAUDE.md` §Git Rules) | `tools/gate.sh` on the gate train: lanes picked from the diff, compared with `known-red.json` | 30–50 min, not waited on |
| **release ladder** | cutting a release (`docs/GIT-FLOW.md`) | `tools/gate.sh --release` plus the fixpoint check | hours |

Lanes, `msc test src/index.ms`, the tier indexes and corpus sweeps run only in the land gate and the release ladder, because one of them during an edit holds the person for most of an hour while the land gate runs it anyway.

### Edit loop

**Check the changed contract with its smallest real consumer, in under 60 s per check.** Build one candidate when compiler code changed, then prove the regression red on the old compiler and green on the candidate, including the required backend variants. You choose the checks from the diff, and a wrong choice is accepted, because the land gate runs every lane once and catches what the choice missed. When the smallest consumer cannot finish in 60 s, run it once and add it with its measurement to the over-budget list below.

Build the candidate once per compiler edit: `msc build src/index.ms --danger --lto=off --output=msc`. It takes 2–2.5 min on 8 cores and is the only step allowed over the budget. Then run one check per changed contract:

| the diff changes | check | measured |
|---|---|---|
| a function or language invariant in one module | `./msc test <owner-file> --tests-in-dir` | 4–50 s |
| program output, exit status or lifetime | `MSC=./msc MSCORPUS_ONLY=<exact,names> msc run src/test/corpus/run.ms`; add `MSCORPUS_RAISER=1` when the diff adds or edits that program, and `MSCORPUS_SAN=1` for its SAN contract | 4–10 s per program; the Raiser cells about 0.25 s each |
| one lifecycle invariant | `MSC=./msc GUARD_ONLY=<names> msc run --target=raiser src/test/guard/run.ms`; keep its ledger oracle (`guard/README.md`) | 1–5 s per guard |
| what one program emits | `./msc build <prog.ms> --emit=c`, then read that module's C | seconds |
| the cost of one flow | `MSPERF_BASE=<old msc> MSPERF_PROGRAMS=711 MSPERF_RUNS=1 msc run src/test/perf/run.ms`, read the rows of the flow you changed (`docs/BUILD-PERF.md` §Measuring by flow) | one program per arm |
| Solana, native boundary, HCR or formatter | the named failing consumer with its host and backend; recipes in `docs/TESTING.md` | not measured |
| `std/` or `runtime/` inputs | the checks above, with a candidate beside the changed support trees; `tools/syncLocalBinary.ms` belongs to delivery | as above |

- **`msc test <file>` without `--tests-in-dir` also runs the tests of every module the file imports.** For `src/analyzer/inject.ms` that is 102 test files in 85–122 s, against 7 files with the flag (lc-1, tree 651e100ee).
- **Split a performance question by flow.** Run one program and one flow per measurement (`MSC_FLOWS`, `MS_DRC_STAT`, `src/test/perf/emitCostScan.ms --diff`). A whole-compiler A/B waits for the land.
- **`MSC_FLOWS=<file>` splits a test run** into graph, phases A/B/C, cc, link and the run of the test binary. `msc test src/analyzer/inject.ms --tests-in-dir` on lc-1 alone, tree 54af0f26a, ms:

  | run | graph | A | B | C | cc | link | test run | total |
  |---|---|---|---|---|---|---|---|---|
  | default, warm | 9538 | 18564 | 3610 | 1178 | 31 | 922 | 3056 | 36900 |
  | `--release`, warm | 9228 | 17044 | 3548 | 1085 | 22 | 123 | 379 | 31431 |
  | default, cold | 9887 | 18340 | 4119 | 1663 | 28219 | 926 | 7121 | 70276 |
  | `--release`, cold | 9828 | 20222 | 5421 | 3569 | 80089 | 145 | 847 | 120121 |

  The front end (graph and phase A) is three quarters of a warm check. `--release` saves 5.5 s warm and costs 52 s of clang cold, so test builds stay at the default.
- **Over budget now:**
  - `src/checker/checkPass.ms` took 65 s with the flag, 30 s of it its own tests (tree 651e100ee, before its prelude tests shared one std check; not remeasured).
  - `src/codegen/raiser/eval.ms` took 76 s with the flag, 19 s of it its own tests, mostly `numericCondsFailure` (tree 651e100ee).
- **The guard runner's JS leg calls `msc` from `PATH`.** A host without it reports exit 127 as a red guard.

### Land gate

**When the slice is ready, `./msc check src/index.ms` is clean and its own checks are green, send the session named `merge-train` the slice name and tip** (workspace `CLAUDE.md` §Worktrees). Land with `~/nerdtools/claude/tools/wt.sh land <name>` once its keyed verdict is GREEN. Use the Mac land queue (`land <name> --async`, then `--wait` in the background) only when `.gate-host/gate-item.sh` says the changed lines are macOS-only or no `merge-train` is live. Do not run a separate gate first, because that duplicates the land gate. `tools/gate.sh --dry-run` proposes lanes to compare with the changed contract.

**After a RED land, return to the edit loop: rerun the named failures in the owning worktree, then send the new tip.** The corpus FAIL line quotes the stdout the cell printed. Fix new reds; let the existing known-now-green pruning handle entries the gate proved green. Do not use another full gate to find out whether the same failure remains. A BUSY result is not a RED: the queue retries it with eligible green lanes kept. Reuse completed evidence only while its checked code, inputs, toolchain and settings still match.

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
6. Run the focused regression in the edit loop, plus the owning-tier module when discovery or integration needs it. When the slice is ready, send it to the land gate as above; the land gate must show no new red.

A user-visible feature lands together with the corpus programs that pin its observable behaviour through every lane.
