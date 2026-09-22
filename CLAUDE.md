# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

- **C**: primary. Deterministic memory management, lifecycle hooks. Phase 4 (Analyzer) required.
- **JavaScript**: secondary. No analyzer, direct emission.
- **Erlang**: POSTPONED.

## Build Commands

```bash
# Verify a change: picks the lanes from the diff, names every NEW red.
tools/gate.sh                         # --dry-run = show the choice, --release = full ladder

# Tests. `msc test <file>` runs that file + its transitive dep tests.
# NOTE: no --filter/--jobs flags.
msc test src/index.ms                 # full compiler suite, native
msc test src/utils/string.ms          # one file (+ its deps)

# Corpus tier — two SEPARATE lane runs. Parity when the change touches
# codegen / DRC / runtime / transform; SAN when it touches DRC hooks; both
# before a RELEASE cut (docs/GIT-FLOW.md). A land on main is not a ship.
# Runners test ./msc when it exists, else installed msc; MSC=<path> overrides.
# Which command when: src/test/CLAUDE.md
msc run src/test/corpus/run.ms                 # parity (C↔JS) + RSS
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms  # ASan + DRC ledger
MSCORPUS_FILTER=leak msc run src/test/corpus/run.ms   # substring subset
src/test/guard/run.sh                          # lifecycle guards (proven-red)

MSCORPUS_ONLY=<exact,names> msc run src/test/corpus/run.ms   # exact subset; recipe + traps: docs/TESTING.md

msc run src/index.ms                              # build + run natively
msc build examples/actorSpawnBasic.ms --target=c  # compile to C only

# Optimized self-host binary → ./msc. Add --cc=clang on macOS to get LTO.
msc build src/index.ms --gc=drc --danger --output=msc

# Sync to ~/.metascript/ so downstream projects pick it up via $PATH
./tools/sync-local-binary.sh              # full sync
./tools/sync-local-binary.sh --check      # dry-run
./tools/sync-local-binary.sh --no-binary  # support trees only

bash tools/editor-plugin/build.sh --install   # after grammar/highlights edits
```

Windows-host-only traps: [`docs/WINDOWS-TRAPS.md`](docs/WINDOWS-TRAPS.md).

## Build Optimization — default `build` is UNOPTIMIZED (`-O0`)

Opt level and LTO are **separate axes**. `modeFlags` (`src/compiler/cc.ms`): default=`-O0 -g`, `--release`=`-O2`, `--danger`=`-O3`.

`--lto` is capability-resolved after the compiler is known (`resolveLto`): `--danger` takes thin LTO where the resolved compiler can link it, drops it with a stderr notice where it cannot, and an explicit `--lto=` against a proven-broken pair fails loud.

```bash
msc build src/index.ms --gc=drc --danger --cc=clang --output=msc   # macOS
```

**Do not re-litigate**: macOS/zig and Windows/zig cannot LTO (verified 2026-07-30 and 2026-08-31, target-scoped, no flag fixes it from our side); GNU gcc never gets LTO by default and spells it `-flto=auto`. The gain is **LTO, not clang** — clang and zig are equivalent code generators. Capability table: `src/compiler/cc.ms` (`ltoBroken`). Evidence + measurement method: [`docs/BUILD-PERF.md`](docs/BUILD-PERF.md).

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

All five phases run the self-host build. Parse: recursive descent + Pratt over `NodeKind` / `TokenKind` (`std/meta/node.ms`, `std/meta/token.ms`). TypeCheck: 3-pass (collect, resolve, check), cross-module via ExportRegistry. Transform: one ordered pass list in `src/transform/index.ms`, JS-only passes behind `jsBackend`, the C-only tail in `src/transform/native/index.ms`. Analyzer: DRC injection (`src/analyzer/inject.ms`: cross-scope last-read, branch-aware optimizer). Codegen: C primary, JS secondary.

`generatorLower` runs BEFORE `lambdaLifting` (reversed from the standard reference's order) — intentional: generator creates `$state` + FunctionExpr, lambda lifting then captures `$state` into env. Output is identical to the reference; the reversed order keeps the two transforms decoupled.

Architecture detail: [`docs/PIPELINE.md`](docs/PIPELINE.md). File tree + patterns: [`docs/PROJECT-STRUCTURE.md`](docs/PROJECT-STRUCTURE.md).

## CRITICAL: Codegen Must Be Thin/Dumb

**`src/codegen/c/` is a dumb emitter.** It only dumps what earlier phases already processed. If you find yourself adding logic to C codegen, STOP.

**The rule**: before adding ANY codegen logic, check the standard reference implementation. If it handles the concern before codegen, we must too. Evidence: of 7 C-backend failures traced 2026-03-04, **6 were bugs in Transform/Checker** that merely surfaced in codegen; only 1 (exception runtime types) belonged in codegen.

**Checklist**: (1) reference does it in transform or earlier → Transform. (2) type resolution → Checker. (3) desugaring/lowering → `src/transform/`. (4) pure C syntax emission → only then codegen.

## Writing MetaScript

Before writing or reviewing `.ms`, follow the canonical
[`../docs/CODE-STYLE.md`](../docs/CODE-STYLE.md). Use [`docs/LANG.md`](docs/LANG.md) for
language behavior the style guide does not cover.

## Entry points

- Nothing auto-calls `main`; the program is the entry module's top-level code. CLI and
  test-target call sites follow [`../docs/CODE-STYLE.md`](../docs/CODE-STYLE.md) §9.
- Exit means the event loop is empty. `msDrainUntilIdle()` finishes pending work and
  `msReportOrphanFailures()` turns unhandled rejections into exit 1; `process.exit()` skips both.
- For `--app=lib` hosts, call the entry module's init functions rather than the program-wide
  `MsMain()`. Read [`docs/BARE.md`](docs/BARE.md) before changing host or init behavior.

## Runtime C — avoid variadic struct args

When adding helpers in `runtime/core/`, **do not pass 16-byte structs (e.g. `msString`) through `...` variadics**. LLVM/Zig miscompile this on `aarch64-windows-gnu` (AAPCS64 instead of the Microsoft ARM64 variadic ABI): args 4+ read from misaligned stack slots, symptom is a silent crash at module init. Applies to any struct ≥16 bytes or containing pointers; scalars are fine.

```c
msString msStringConcatMany(int64_t count, ...);              // BAD
msString msStringConcatArr(const msString* arr, int64_t n);   // GOOD
```

**Call-site emission**: `emitCallExpr` (`src/codegen/c/expressions.ms`) name-matches `msStringConcatArr` / `msStringArrayFromArr` and rewrites the call to a stack-local array fill + pointer pass. A new array-taking runtime helper needs that intercept extended (family: `msBoxStruct`, `msSpawnInto`, `msWaitForStruct`).

## Git Rules

- **One worktree per feature or named arc, many sessions on it** — the unit has a name and a card; `claude --worktree <name>` (or `tools/wt.sh new <name>` by hand) creates branch `wt/<name>` with vendor, `paper` and a builder `./msc` ready, and re-enters the same worktree on every later session; from branch-off to done the arc's work happens only there.
- **A second worktree needs a reason** — (1) two pieces run at the same time in different sessions and write no common path, or (2) a stray change that belongs to no open arc, which gets a short `fix-<name>` worktree, lands and is retired. Sequential steps of one arc are commits in its worktree, never new worktrees; work that needs a path another worktree is ahead of `main` on (`tools/wt.sh ls`, then `git diff --name-only main...wt/<other>`) waits for that land.
- **A step is a commit, a slice is a land** — a step of an arc ends at its commit and the next step starts right away; a gate costs about ten minutes and holds the machine, so nobody lands or waits for a land after each step.
- **Land a slice when it stands alone and something needs it, not at every step and not when the arc ends** — the reasons are: another repo needs the fix through `tools/sync-local-binary.sh`, the session ends, or the worktree has neither landed nor rebased for two days while `main` moved; `land` rebases onto `main`, so the worktree stays current and keeps going after the land.
- **The card is `$MSC_WT_ROOT/<name>.md`** — `tools/wt.sh new` seeds it; its State is written for a reader who has seen none of the arc: no stage codes, and the step in flight can be started without opening another file. The SessionStart hook prints it (`tools/wt.sh card` by hand) with the compiler inbox tallied by `State:`; `tools/wt.sh ls` shows each goal, marks a worktree without one `NO CARD` and lists every card left without a branch. A fresh card gets its Goal and "Done when" before the first commit. Its `Layer:`, `Kind:` and `Mechanism:` lines are filled when the fix is understood, in the words the report uses, so the classification outlives the session and the inbox tallies by kind.
- **The main checkout only receives lands** — `tools/wt.sh land` rebases, gates, moves `main` and syncs the checkout path by path, refusing any path the checkout holds uncommitted work on.
- **A gate verdict survives a `main` that moved only by paths no lane tests** — when `main` moves during the gate, `land` rebases onto it and lands without a second gate if every path the move changed picks no lane (`tools/gate.sh --inert <from> <to>`, the gate's own inert list); a move that changes a path a lane tests re-gates. Nobody re-runs a lane on what is already known safe.
- **A worktree is retired from outside it, with `tools/wt.sh rm`** — a session cannot remove the worktree it runs in (its own processes hold it), so it reports the land and leaves the worktree; `rm` names what it would lose, `--force` discards only that; find idle ones with `tools/wt.sh ls --stale`.
- **Data flows one way, repo → `~/.metascript/`** — through `tools/sync-local-binary.sh` only, run from a clean worktree of `main` (it refuses uncommitted work under `src`, `std`, `runtime` and a binary older than `src`) and recording the commit in `~/.metascript/BUILD`; nothing mirrors into a checkout.
- **Branches and releases follow [`docs/GIT-FLOW.md`](docs/GIT-FLOW.md)** — release, fix and merge work each get their own worktree.
- **`land --no-gate` belongs to the person at the keyboard** — it lands on evidence gathered outside the gate and says so; an agent does not reach for it on its own.

## Verification Cost — lanes follow the change; the full ladder follows a release

**"Ship" means cutting a release per `docs/GIT-FLOW.md`.** Landing on `main` and publishing the binary with `tools/sync-local-binary.sh` are not shipping, and neither asks for the full ladder.

- **One command picks and runs the lanes** — `tools/gate.sh` maps the paths a change touches to lanes (the table at the top of the script), runs them one after another and stops at the first new red; `--dry-run` shows the choice and why, `--release` runs the full ladder, and `tools/wt.sh land` calls it.
- **Known red is `src/test/known-red.json`** — each lane's failures are compared with it by name; the verdict reads `N red · K known · M new` and only `new` fails the gate. `tools/gate.sh --record` on a clean `main` rewrites that file; nobody edits it by hand, and a rerun on the same state answers nothing.
- **The machine is shared** — the gate waits while load exceeds the core count and never runs two lanes at once; do not start a second heavy lane beside it.
- **The object cache stays** — no `rm -rf out` before a build or a suite; the cache is fingerprint-keyed and correct ([`docs/TESTING.md`](docs/TESTING.md)), and wiping it triggers the cold-build link race. Wipe only for a named stale-cache symptom.
- **Adjacent lands share one gate** — commits that belong together land as one branch, gated once.
- **The corpus lanes run on what the change alters** — the gate emits all programs with the merge-base compiler and the candidate and hands corpus and SAN only the programs whose C or JS differs; it runs them whole under `--lanes` / `--release`, or when the diff touches `runtime/`, `std/`, `vendor/` or the corpus runner ([`docs/TESTING.md`](docs/TESTING.md)).
- **Control and probe binaries answer one question** — build a control only for an A/B that needs one, read a probe from the cheapest lane that triggers it, and never gate either.

## Docs Rule — never edit `docs/*.md` from reading alone

**Before changing any status claim in `docs/`, run it and measure it.** Reading the checker, grepping for a handler, or finding the code path is NOT verification — it tells you code exists, not that it works or what it costs. Write the smallest `.ms` that exercises the claim, `msc run` / `msc build` it, and quote the real output in the edit.

1. **A doc's `TODO` / `PAUSED` / `NOT YET` is a hypothesis, not a fact.** They get written the moment someone is blocked and are never revisited. Every such claim probed on 2026-08-10 was already false, some by 3 months.
2. **Never generalize from one probe variant.** Vary the axis you are claiming about and put the matrix in the doc. One probe per claim is how you write a confident wrong number.
3. **Say what you did NOT verify.** A corrected table with unverified neighbours is more dangerous than an obviously stale one — it looks freshly audited.

## When to Stop and Ask

| Situation | Action |
|---|---|
| The fix tracks the reference implementation and stays inside the task | do it, gate it, report after |
| Two directions both track the reference, or the fix crosses a recorded intentional divergence | ask — one question, with a recommendation |
| The work has to leave the task's scope | stop and report |
| The fix needs a pass, structure or protocol the design and the reference both lack | stop and ask, marked **NEW MECHANISM**, before writing it |

## Commits

- **The agent commits, the person pushes** — a session owns its worktree and its `wt/<name>` branch, so it commits there on its own through `/split-commit`; `main` moves only through `tools/wt.sh land`, and nothing is pushed without a yes.
- **Checked before every commit** — `./msc check src/index.ms` is clean when a `.ms` under `src/` changed (~5 s), and the step's own guard has gone red on the old compiler and green on one candidate build, on C plus `--target=js` for that one file; the lanes belong to the gate before a land, not to each commit.

IMPORTANT: never mention specific reference projects in all documents or comment inside our source code — this covers the line-by-line mapping to a reference compiler, which lives outside the repo; naming a design inspiration in `docs/` is fine

@paper/local.md
