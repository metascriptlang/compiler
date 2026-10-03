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

**Run `tools/gate.sh`.** It picks the lanes from the paths a change touches and compares every red with `src/test/known-red.json`; `--dry-run` prints the choice, `--release` runs the full ladder. Reach for a row by hand only inside a debug loop.

| Situation | Command |
|---|---|
| Inner loop — any compiler edit | `msc test src/index.ms`, or `msc test <file>` for that file plus its transitive dep tests |
| Same, under the cycle collector | `msc test src/index.ms --gc=orc` |
| Touched codegen / DRC / runtime / transform | + `msc run src/test/corpus/run.ms` |
| Touched DRC hooks, lifetimes, ownership | + `MSCORPUS_SAN=1 msc run src/test/corpus/run.ms` and `msc run --target=raiser src/test/guard/run.ms` |
| Touched `std/` or anything users compile against | rebuild + `tools/syncLocalBinary.ms` first, then re-run the above |

- **A compiler reads `std/` and `runtime/` from beside its own binary** — `./msc` is the candidate with this repo's trees, `msc` on `PATH` is the last published build with `~/.metascript/`.
- **Runners test `./msc` when it exists, else the installed `msc`** — `MSC=<path>` overrides, and the runner header prints the choice.
- **`msc run <runner>` runs the harness, `MSC` names the subject** — `./msc run <runner>` alone inverts that: the harness gets the new compiler while every program is still built by the old one.
- **One `msc` build at a time per tree, and never `rm -rf out` first** — both produce a red that names a different file every run; check `uptime` before trusting a timing.
- **Checker-source handoff contracts run natively**; a runtime/backend claim additionally needs a real language or corpus consumer.
- **The owning tier indexes are gate entries**. `src/test/index.ms` is not; run a new module with `msc test <file> --tests-in-dir`, then its owning tier index.

## When you fix a bug

1. Reproduce it with a minimal program and save it.
2. Apply the fix.
3. Add a contract to the owner module under `lang/`, `handoff/`, `c/` or `js/`, or create a semantic family there when no owner exists. Import new runnable modules in the tier index.
4. If the bug changes program output or exit status, add a standalone semantic corpus consumer with an absolute expected oracle, and exercise its required backends. A duplicate of the same owner and oracle is not a new contract.
5. If found by self-host, prove the user-visible path with a focused language test.
6. Run the changed file and its owning tier index, then `tools/gate.sh`; no new red.

A user-visible feature lands together with the corpus programs that pin its observable behaviour through every lane.
