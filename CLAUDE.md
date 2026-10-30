# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

- **C**: primary. Deterministic memory management, lifecycle hooks. Phase 4 (Analyzer) required.
- **JavaScript**: secondary. No analyzer, direct emission.
- **Erlang**: POSTPONED.

## Build Commands

A command reference, not a plan: pick the check from [`src/test/CLAUDE.md`](src/test/CLAUDE.md) §Running. Every command here except `msc check` and the editor plugin is a heavy job (workspace `CLAUDE.md` §Shared machines): run it through `~/metascript/.gate-host/run-remote.sh`, building the candidate in the same call, or with `MAC_ONLY=1` when it needs macOS.

```bash
# Edit loop: one check per changed contract, each under 60 s. Which check when: src/test/CLAUDE.md §Running
msc test src/utils/string.ms --tests-in-dir   # one module's tests; without the flag it also runs every import's tests
MSCORPUS_ONLY=<exact,names> msc run src/test/corpus/run.ms   # named corpus programs; recipe + traps: docs/TESTING.md
GUARD_ONLY=<names> msc run --target=raiser src/test/guard/run.ms   # named lifecycle guards
MSPERF_BASE=<old msc> MSPERF_PROGRAMS=711 nice -n 10 msc run src/test/perf/run.ms   # one flow A/B; docs/BUILD-PERF.md "Measuring by flow"

# Land gate and release ladder: never mid-edit. Runners test ./msc when it exists, else installed msc; MSC=<path> overrides.
tools/gate.sh                         # lanes picked from the diff; --dry-run = show the choice, --release = release ladder
msc test src/index.ms                 # full compiler suite
msc run src/test/corpus/run.ms                 # corpus parity (C↔JS) + RSS
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms  # corpus ASan + DRC ledger
msc run --target=raiser src/test/guard/run.ms   # every lifecycle guard

msc run src/index.ms                              # build + run natively
msc build examples/actorSpawnBasic.ms --target=c

# Optimized self-host binary → ./msc. Add --cc=clang on macOS to get LTO.
msc build src/index.ms --danger --output=msc

# Edit loop candidate: thin-LTO off, so the link takes ~0.2 s instead of ~15 s at the same -O3 (docs/BUILD-PERF.md).
msc build src/index.ms --danger --lto=off --output=msc

# Sync to ~/.metascript/ so downstream projects pick it up via $PATH
./msc run --target=raiser tools/syncLocalBinary.ms            # full sync
./msc run --target=raiser tools/syncLocalBinary.ms check      # dry-run
./msc run --target=raiser tools/syncLocalBinary.ms no-binary  # support trees only
./msc run --target=raiser tools/syncLocalBinary.ms web        # browser compiler only (emcc) → ~/.metascript/web/

bash tools/editor-plugin/build.sh --install   # after grammar/highlights edits
```

Before moving a cache directory, sharing build artifacts between jobs or measuring reuse, read [`docs/BUILD-CACHE.md`](docs/BUILD-CACHE.md), because it records which reuse is proven valid, a measured false hit, and an age sweep of the global store that deletes files it does not own.

Windows-host-only traps: [`docs/WINDOWS-TRAPS.md`](docs/WINDOWS-TRAPS.md).

## Build Optimization — default `build` is UNOPTIMIZED (`-O0`)

Opt level and LTO are **separate axes**. `modeFlags` (`src/compiler/cc.ms`): default=`-O0 -g`, `--release`=`-O2`, `--danger`=`-O3`.

`--lto` is resolved after the compiler is known (`resolveLto`): `--release` and `--danger` take thin LTO where the resolved compiler can link it; where it cannot, `--danger` drops it with a stderr notice and `--release` drops it silently; an explicit `--lto=` against a proven-broken pair fails loud.

```bash
msc build src/index.ms --danger --cc=clang --output=msc   # macOS
```

**Treat macOS/zig and Windows/zig LTO as settled** by `ltoBroken`, and reopen it only with a new measurement on a changed toolchain, because they cannot LTO target-wide and no flag on our side fixes it; GNU gcc never gets LTO by default and spells it `-flto=auto`. The gain is **LTO, not clang**: clang and zig are equivalent code generators. Capability table: `src/compiler/cc.ms` (`ltoBroken`). Evidence and method: [`docs/BUILD-PERF.md`](docs/BUILD-PERF.md).

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

All five phases run the self-host build. Parse: recursive descent + Pratt over `NodeKind` / `TokenKind` (`std/meta/node.ms`, `std/meta/token.ms`). TypeCheck: 3-pass (collect, resolve, check), cross-module via ExportRegistry. Transform: one ordered pass list in `src/transform/index.ms`, JS-only passes behind `jsBackend`, the C-only tail in `src/transform/native/index.ms`. Analyzer: DRC injection (`src/analyzer/inject.ms`: cross-scope last-read, branch-aware optimizer). Codegen: C primary, JS secondary.

`generatorLower` runs BEFORE `lambdaLifting` (reversed from the standard reference's order) on purpose: generator creates `$state` + FunctionExpr, lambda lifting then captures `$state` into env, which keeps the two transforms decoupled. Where the order would change the result, the split restores the reference's outcome: a nested routine is rebuilt at each resume instead of stored in the frame (`hoistStateRoutines`).

Architecture detail: [`docs/PIPELINE.md`](docs/PIPELINE.md). File tree + patterns: [`docs/PROJECT-STRUCTURE.md`](docs/PROJECT-STRUCTURE.md).

## CRITICAL: Codegen Must Be Thin/Dumb

**`src/codegen/c/` is a dumb emitter.** It only dumps what earlier phases already processed. If you find yourself adding logic to C codegen, STOP, because a bug that surfaces in codegen almost always lives earlier, in Transform or the Checker.

**Before adding ANY codegen logic, check the standard reference implementation**: (1) reference does it in transform or earlier → Transform. (2) type resolution → Checker. (3) desugaring/lowering → `src/transform/`. (4) pure C syntax emission → only then codegen.

## Entry points

- Nothing auto-calls `main`; the program is the entry module's top-level code. CLI and test-target call sites follow [`docs/LANG-PREFERENCE.md`](docs/LANG-PREFERENCE.md#program-entry-tests-and-shutdown).
- Exit means the event loop is empty. `msDrainUntilIdle()` finishes pending work and `msReportOrphanFailures()` turns unhandled rejections into exit 1; `process.exit()` skips both.
- For `--app=lib` hosts, call the entry module's init functions rather than the program-wide `MsMain()`. Read [`docs/BARE.md`](docs/BARE.md) before changing host or init behavior.

## Runtime C — avoid variadic struct args

When adding helpers in `runtime/core/`, **do not pass 16-byte structs (e.g. `msString`) through `...` variadics**, because LLVM/Zig miscompile this on `aarch64-windows-gnu` (AAPCS64 instead of the Microsoft ARM64 variadic ABI): args 4+ read from misaligned stack slots and the program crashes silently at module init. Applies to any struct ≥16 bytes or containing pointers; scalars are fine.

```c
msString msStringConcatMany(int64_t count, ...);              // BAD
msString msStringConcatArr(const msString* arr, int64_t n);   // GOOD
```

**Call-site emission**: `emitCallExpr` (`src/codegen/c/expressions.ms`) name-matches `msStringConcatArr` / `msStringArrayFromArr` and rewrites the call to a stack-local array fill + pointer pass. A new array-taking runtime helper needs that intercept extended (family: `msBoxStruct`, `msSpawnInto`, `msWaitForStruct`).

## Git Rules

How a slice reaches `main` (ready check, gate queue, RED and GREEN) is in the workspace `CLAUDE.md` §Worktrees and landing and `~/metascript/.gate-host/README.md`; what proof a slice needs before it is submitted, and how to answer a red, is `~/metascript/docs/LANDING.md`. This repository adds:

- **One worktree per feature or named arc, many sessions on it, one writer at a time.** `claude --worktree <name>` (or `~/nerdtools/claude/tools/wt.sh new <name>`) creates branch `wt/<name>` with vendor, `paper` and a builder `./msc` ready, and re-enters the same worktree on every later session.
- **A second worktree needs a reason**: two pieces run at the same time in different sessions and write no common path, or a stray change that belongs to no open arc, which gets a short `fix-<name>` worktree, lands and is retired. Sequential steps of one arc are commits in its worktree.
- **Wait for dependencies, not filenames.** Inspect ahead worktrees' diffs and affected callers before editing (`wt.sh ls`, then `git diff main...wt/<other> -- <paths>`). Wait for their land when this work consumes their unlanded behavior or would independently change the same invariant or hunk; otherwise proceed in separate worktrees, even in one file, because file overlap alone neither proves nor excludes a dependency. Record shared-path owners and the evidence of independence in the card.
- **A step is a commit**, and it gets no gate of its own: the slice it belongs to is gated once.
- **Submit a slice the moment it is finished and passes its ready check** (workspace `CLAUDE.md` §Worktrees and landing): do not hold finished slices for a milestone or until something outside needs them, because each slice now gets its own gate on an idle host while held slices pile into big lands that go red more often. While a slice waits in the queue, its worktree takes no commit and no tracked edit; read, trace and draft new files for the next slice meanwhile.
- **The card is `~/metascript/.wt/<name>.md`** (`$MSC_WT_ROOT` overrides the folder); `wt.sh new` seeds it. Its State is written for a reader who has seen none of the arc, with no stage codes, so the step in flight can be started without opening another file. A fresh card gets its Goal and "Done when" before the first commit; its `Layer:`, `Kind:` and `Mechanism:` lines are filled when the fix is understood, in the report's words, so the inbox tallies by kind.
- **The main checkout only receives lands.** `wt.sh land` rebases, gates, moves `main` and syncs the checkout path by path, refusing any path the checkout holds uncommitted work on.
- **A worktree is retired from outside it** with `wt.sh rm`, because a session cannot remove the worktree it runs in; `rm` names what it would lose and `--force` discards only that. `wt.sh ls --stale` finds idle ones.
- **Data flows one way, repo → `~/.metascript/`**, through `tools/syncLocalBinary.ms` only, run from a clean worktree of `main` (it refuses uncommitted work under `src`, `std`, `runtime` and a binary older than `src`) and recording the commit in `~/.metascript/BUILD`.
- **Branches and releases follow [`docs/GIT-FLOW.md`](docs/GIT-FLOW.md)**; release, fix and merge work each get their own worktree.
- **Name what a change can alter before you land it**: who reads the changed code, which test or corpus program reaches it. When a lane can observe it, it goes through the gate queue. When none can (a string only `msc --version` prints, a comment, a doc), say so with that evidence and land with `land --no-gate` once the person agrees, even where the shared worktree playbook would land it without asking, because the gate is the shared safety net and the flag records that it did not run.

## The land gate — `tools/gate.sh`

Which flow a run belongs to, and the check for each kind of change, is in [`src/test/CLAUDE.md`](src/test/CLAUDE.md) §Running; read it before you test, run or measure anything. The land gate itself:

- **One command picks and runs the lanes.** `tools/gate.sh` maps changed paths to lanes and runs `PHASES` in order, with independent lanes inside a phase running concurrently; a new red skips later phases. The land gate keeps only the core of that choice (`LAND_LANES`: the very cheap, very important or often red lanes; corpus and san on the programs the slice adds or edits); the owner adds what its change reaches with `--with <lanes>` and `--programs <names>`, and `--full` keeps every chosen lane (`~/metascript/docs/LANDING.md` §What the land gate runs). `--dry-run` shows the choice and why; `--release` runs the release ladder. A path is only its stand-in for what the change can reach; the decision is yours.
- **Known red is `src/test/known-red.json`.** Each lane's failures are compared with it by name; the verdict reads `N red · K known · M new` and only `new` fails the gate, and a rerun on the same state answers nothing. A new red of a named test the slice does not edit is rerun on the slice's candidate and on main's (`triage_lane`); seen on main, or fewer than twice here, it prints as `not the slice's` and does not fail the gate (`~/metascript/docs/LANDING.md` §Answering a red). Rows are written by `MAC_ONLY=1 tools/gate.sh --record` (`--lanes` limits it), which runs only on macOS from a checkout that matches `main` on the tested paths; it leaves each new row's note empty and the next gate refuses that, so fill the note with the row's card. **A row a slice adds needs the person's yes**, recorded in the row as `"approved": "<date> <their words>"`; the gate is RED before any lane on an added row without it, because a row hides that red from every later gate. A `known-now-green` row never fails a gate; dropping it (with the next Mac `--record`, since only a land gated on the Mac commits the pruned set) or editing a note needs no yes. A red only one platform or host shows is never a row: it gets a compiler inbox card (as RTX's glibc 2.43 reds did).
- **`tools/gate.sh` queues machine-wide FIFO** in `~/.metascript/gates` on the machine it runs on and checks free cores before its phases (gate hosts turn the FIFO off and admit by `gate-item.sh`). Never run one by hand on a gate host or the Mac to get a verdict: only the gate queue's gate writes one (workspace `CLAUDE.md` §Worktrees and landing).
- **The object cache stays**: no `rm -rf out` before a build or a suite, because wiping it triggers the cold-build link race. Investigate a named stale-cache symptom instead of resetting another job's state ([cache rules](docs/BUILD-CACHE.md)).
- **Adjacent lands share one gate**: commits that belong together land as one branch.
- **Under `--full`, `--release` or a corpus lane named in `--with`, the corpus lanes run every program.** No gate emits every program to skip those with a recorded pass: over 105 gates to 2026-10-30 that select took 22.5 h and saved at most 11 h of corpus and san.
- **Control and probe binaries answer one question**: build a control only for an A/B that needs one, read a probe from the cheapest lane that triggers it, and never gate either.

## Docs Rule — never edit `docs/*.md` from reading alone

**Before changing any status claim in `docs/`, run it and measure it**, because reading the checker or finding the code path tells you code exists, not that it works or what it costs. Write the smallest `.ms` that exercises the claim, `msc run` / `msc build` it, and quote the real output in the edit.

1. **A doc's `TODO` / `PAUSED` / `NOT YET` is a hypothesis, not a fact**: they are written when someone is blocked and rarely revisited.
2. **Never generalize from one probe variant.** Vary the axis you are claiming about and put the matrix in the doc.
3. **Say what you did NOT verify**, because a corrected table with unverified neighbours looks freshly audited.

## When to Stop and Ask

| Situation | Action |
|---|---|
| The fix tracks the reference implementation and stays inside the task | do it, verify it in the edit loop, report after; it reaches `main` through the land gate |
| Two directions both track the reference, or the fix crosses a recorded intentional divergence | ask — one question, with a recommendation |
| The work has to leave the task's scope | stop and report |
| The fix needs a pass, structure or protocol the design and the reference both lack | stop and ask, marked **NEW MECHANISM**, before writing it |

## Commits

- **The agent commits, the person pushes**: a session commits in its own worktree through `/split-commit`; `main` moves only through `wt.sh land`, and nothing is pushed without a yes.
- **Checked before every commit**: `./msc check src/index.ms` is clean when a `.ms` under `src/` changed (~5 s), and the step's own pin has gone red on the old compiler and green on one candidate build, in the backend variants `src/test/CLAUDE.md` §Edit loop requires. Lanes belong to the land gate.

IMPORTANT: never name a reference project or cite its `file:line` in source code or its comments, because the line-by-line mapping to a reference compiler lives outside the repo (`paper/NIM-REF.md`); a comment cites the entry by ID instead (`NIM-REF CK-46`), and naming a design inspiration in `docs/` is fine.

@paper/local.md
