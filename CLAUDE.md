# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

- **C**: primary. Deterministic memory management, lifecycle hooks. Phase 4 (Analyzer) required.
- **JavaScript**: secondary. No analyzer, direct emission.
- **Erlang**: POSTPONED.

## Build Commands

**Before choosing or running verification, read [`src/test/CLAUDE.md`](src/test/CLAUDE.md) §Running** for the diff-to-check matrix, required backend cells and recipes. It owns test selection; [`docs/TESTING.md`](docs/TESTING.md) owns corpus/directive traps. Full suites and lanes belong to landing/release, not the edit loop.

Every build/runner is heavy regardless of duration: use the workspace §Shared machines policy, including `run-remote.sh --mac` for macOS-only tests, not a blanket local `MAC_ONLY=1`. Build the candidate and all checks using it in one remote call. The edit-loop candidate command is `msc build src/index.ms --danger --lto=off --output=msc`; light `msc check` and editor-plugin installation remain local.

Before a flow A/B, read [`docs/BUILD-PERF.md`](docs/BUILD-PERF.md) §Measuring by flow. Build a control only for an A/B that needs one; probe the cheapest triggering consumer and never gate control/probe binaries. Before delivery, read the header of `tools/syncLocalBinary.ms` for the command and full/check/no-binary/web modes and obey §Git Rules. After grammar/highlight edits, install with `bash tools/editor-plugin/build.sh --install`.

Before moving a cache directory, sharing build artifacts between jobs or measuring reuse, read [`docs/BUILD-CACHE.md`](docs/BUILD-CACHE.md), because it records which reuse is proven valid, a measured false hit, and an age sweep of the global store that deletes files it does not own.

Windows-host-only traps: [`docs/WINDOWS-TRAPS.md`](docs/WINDOWS-TRAPS.md).

## Build Optimization — default `build` is UNOPTIMIZED (`-O0`)

Optimization and LTO are independent: default `-O0 -g`, release `-O2`, danger `-O3` (`src/compiler/cc.ms` `modeFlags`). Before changing LTO/toolchain behavior, read `resolveLto`, `ltoBroken` and [`docs/BUILD-PERF.md`](docs/BUILD-PERF.md) for capability, fallback/diagnostic rules and measurements. Use `--cc=clang` for macOS LTO. Treat macOS/zig and Windows/zig LTO failures as settled; reopen only with a measurement on a changed toolchain, because our flags cannot fix those pairs. GNU gcc has no default LTO (`-flto=auto` when requested); the measured gain is LTO, not choosing clang over zig.

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

All five phases run the self-host build. Pass order lives in `src/transform/index.ms` (JS behind `jsBackend`, C tail in `native/index.ms`); ownership injection in `src/analyzer/inject.ms`. Read [`docs/PIPELINE.md`](docs/PIPELINE.md) before changing phase boundaries and [`docs/PROJECT-STRUCTURE.md`](docs/PROJECT-STRUCTURE.md) for file ownership/patterns.

`lambdaLifting` runs BEFORE the generator and async state split, as the reference does: every closure is already lifted, so its env (a loop's per-iteration env included) is an ordinary local that the split keeps in the frame like any local living across a suspension. A second `lambdaLifting` after the split lifts the resume routine the split creates, whose env is the frame.

## CRITICAL: Codegen Must Be Thin/Dumb

**`src/codegen/c/` is a dumb emitter.** It only dumps what earlier phases already processed. If you find yourself adding logic to C codegen, STOP, because a bug that surfaces in codegen almost always lives earlier, in Transform or the Checker.

**Before adding ANY codegen logic, check the standard reference implementation**: (1) reference does it in transform or earlier → Transform. (2) type resolution → Checker. (3) desugaring/lowering → `src/transform/`. (4) pure C syntax emission → only then codegen.

## Entry points

- Nothing auto-calls `main`; the program is the entry module's top-level code. CLI and test-target call sites follow [`docs/LANG-PREFERENCE.md`](docs/LANG-PREFERENCE.md#program-entry-tests-and-shutdown).
- Exit means the event loop is empty. `msDrainUntilIdle()` finishes pending work and `msReportOrphanFailures()` turns unhandled rejections into exit 1; `process.exit()` skips both.
- For `--app=lib` hosts, call the entry module's init functions rather than the program-wide `MsMain()`. Read [`docs/BARE.md`](docs/BARE.md) before changing host or init behavior.

## Runtime C — avoid variadic struct args

When adding `runtime/core/` helpers, **do not pass structs ≥16 bytes or containing pointers through `...` variadics**; use an array/pointer interface instead. Scalars are fine. LLVM/Zig use the wrong variadic ABI on `aarch64-windows-gnu`, so args 4+ can silently crash module init. For a new array-taking helper, extend `src/codegen/c/expressions.ms` `emitCallExpr`'s stack-array/pointer intercept (`msStringConcatArr`, `msStringArrayFromArr`; family: `msSpawnInto`, `msWaitForStruct`), because changing the runtime signature alone does not fix calls.

## Git Rules

The workspace §Worktrees and landing owns queue policy and mandatory landing reads. Recompiler adds:

- **One worktree per arc, one writer at a time.** `claude --worktree <name>` or shared `wt.sh new <name>` provisions `wt/<name>` with vendor, `paper` and `./msc`, and reuses it in later sessions. Sequential steps are commits there. A second tree is for concurrent path-disjoint work or an unrelated `fix-<name>` that lands and retires; release/fix/merge arcs follow [`docs/GIT-FLOW.md`](docs/GIT-FLOW.md).
- **Wait for dependencies, not filenames.** Before editing, inspect ahead diffs and callers (`wt.sh ls`, `git diff main...wt/<other> -- <paths>`). Wait if consuming unlanded behavior or changing the same invariant/hunk; otherwise proceed in separate trees, even in one file. Record shared-path owners and evidence of independence in the card, because filenames alone do not establish dependencies.
- **Submit when finished and ready**, as the workspace requires. While queued, make no commit or tracked edit; read/trace or draft new files until the gate starts.
- Cards are `~/metascript/.wt/<name>.md` (`$MSC_WT_ROOT` overrides). Before the first commit fill Goal and "Done when"; when understood, fill `Layer:`, `Kind:`, `Mechanism:` in the report's words. State uses no stage codes and lets a reader new to the arc start the step without another file.
- **Main receives lands only.** `wt.sh land` rebases, gates and syncs main path by path, refusing dirty paths. Retire from outside with `wt.sh rm`; it names losses and `--force` discards only those. Use `wt.sh ls --stale` for idle trees.
- **Delivery is one-way, repo → `~/.metascript/`, through `tools/syncLocalBinary.ms` only**, from clean `main`, with binary no older than `src`, no dirty `src/std/runtime`, and provenance recorded in `~/.metascript/BUILD`, because consumers need matching binary/support trees.
- **Before land, name reach and its evidence.** If a lane observes it, use the queue. If none can (version text, comments, docs), explain why and get the person's agreement before `wt.sh land <name> --no-gate`, even if the shared playbook permits it; the flag records the missing safety net.

## The land gate — `tools/gate.sh`

`tools/gate.sh --dry-run` explains path-selected lanes, a floor of reach rather than proof. Read `~/metascript/docs/LANDING.md` before ready/submit/RED: land runs core `LAND_LANES`, and the owner adds reach with `--with`, `--programs` or `--full`; `--release` runs the release ladder. The runner owns ordered `PHASES`, parallel lanes and stopping later phases on a new red.
- **Known red is `src/test/known-red.json`.** Each lane's failures are compared with it by name; the verdict reads `N red · K known · M new` and only `new` fails the gate, and a rerun on the same state answers nothing. A new red of a named test the slice does not edit is rerun on the slice's candidate and on main's (`triage_lane`); seen on main, or fewer than twice here, it prints as `not the slice's` and does not fail the gate (`~/metascript/docs/LANDING.md` §Answering a red). Rows are written by `MAC_ONLY=1 tools/gate.sh --record` (`--lanes` limits it), which runs only on macOS from a checkout that matches `main` on the tested paths; it leaves each new row's note empty and the next gate refuses that, so fill the note with the row's card. **A row a slice adds needs the person's yes**, recorded in the row as `"approved": "<date> <their words>"`; the gate is RED before any lane on an added row without it, because a row hides that red from every later gate. A `known-now-green` row never fails a gate; dropping it (with the next Mac `--record`, since only a land gated on the Mac commits the pruned set) or editing a note needs no yes. A red only one platform or host shows is never a row: it gets a compiler inbox card (as RTX's glibc 2.43 reds did).
- **Only the queue's gate writes a landing verdict.** Never run a separate gate by hand on a host or the Mac to obtain one; it duplicates the gate and does not authorize land. Local FIFO/admission mechanics live in `tools/gate.sh` and gate-host `gate-item.sh`.
- **The object cache stays**: no `rm -rf out` before a build or a suite, because wiping it triggers the cold-build link race. Investigate a named stale-cache symptom instead of resetting another job's state ([cache rules](docs/BUILD-CACHE.md)).
- Commits belonging together land as one branch/gate. **`--full`, `--release` or a corpus lane in `--with` runs every corpus program**; do not first emit everything to select recorded passes, because that selection cost more than it saved.

## Docs Rule — never edit `docs/*.md` from reading alone

**Before changing any status claim in `docs/`, run it and measure it**, because reading the checker or finding the code path tells you code exists, not that it works or what it costs. Write the smallest `.ms` that exercises the claim, `msc run` / `msc build` it, and quote the real output in the edit.

Before changing memory, views, FFI or thread-crossing behavior, use [CONTRACTS.md](docs/CONTRACTS.md) to separate layout, access, lifetime, effects, result aliasing and concurrent callability. Trace the relevant reference and real consumer for each affected promise, because one proof does not establish the others. Distinguish a foreign declaration the compiler must trust from an internal proof it could check; an accepted unsafe internal shape is an enforcement hole, not a new supported contract.

When publishing support or proposing a rename/removal, classify the exact shape as supported in the checked scope, an enforcement hole, unsupported or unverified. Carry forward matching evidence with its source tree, binary/support provenance and exclusions; otherwise run the smallest distinguishing consumer, because source presence and checker acceptance do not prove runtime safety. Keep concept-policy choices and unapproved designs separate from documentation repair.

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
