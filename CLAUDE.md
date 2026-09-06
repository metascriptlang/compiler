# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

## Git Rules

**NEVER** use `git stash`, `git reset`, `git checkout .`, `git restore`, or any command that discards, overrides, or resets the current working tree state. The working tree contains in-progress work that must not be lost.

## Docs Rule — never edit `docs/*.md` from reading alone

**Before changing any status claim in `docs/`, run it and measure it.** Reading the checker, grepping for a handler, or finding the code path is NOT verification — it tells you code exists, not that it works or what it costs. Write the smallest `.ms` that exercises the claim, `msc run` / `msc build` it, and quote the real output in the edit.

1. **A doc's `TODO` / `PAUSED` / `NOT YET` is a hypothesis, not a fact.** They get written the moment someone is blocked and are never revisited. Every such claim probed on 2026-08-10 was already false, some by 3 months.
2. **Never generalize from one probe variant.** Vary the axis you are claiming about and put the matrix in the doc. One probe per claim is how you write a confident wrong number.
3. **Say what you did NOT verify.** A corrected table with unverified neighbours is more dangerous than an obviously stale one — it looks freshly audited.

## Shared Worktree

A long-lived git worktree is kept at `/tmp/verify-parent` for HEAD-clean verification. **Do NOT remove it.** Reuse across sessions.

```bash
cd /tmp/verify-parent && git checkout <commit-ish>
cp -R /Users/le/metascript/recompiler/vendor /tmp/verify-parent/
cp -R /Users/le/metascript/recompiler/examples /tmp/verify-parent/
```

**Untracked but required** (must be copied in): `vendor/` — without it `@compile` fails; NEVER run `sync-local-binary.sh` from a worktree missing `vendor/` (its `rsync --delete` wipes `~/.metascript/vendor/`). `examples/` — LSP lifecycle tests read the phase5/phase6 fixtures; missing → 9 reds.

## Build Commands

```bash
# Tests. `msc test <file>` runs that file + its transitive dep tests.
# NOTE: no --filter/--jobs flags.
msc test src/index.ms                 # full compiler suite, native
msc test src/utils/string.ms          # one file (+ its deps)

# Corpus tier — two SEPARATE lane runs, both must be green to ship.
# Runners test ./msc when it exists, else installed msc; MSC=<path> overrides.
# Which command when: src/test/CLAUDE.md §5.0
msc run src/test/corpus/run.ms                 # parity (C↔JS) + RSS, ~19 min
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms  # ASan + DRC ledger, ~10 min
MSCORPUS_FILTER=leak msc run src/test/corpus/run.ms   # substring subset
src/test/guard/run.sh                          # lifecycle guards (proven-red)

# Narrow fix, want corpus confidence without the ~19-min run? Emit-diff
# selector: --emit=c every corpus program with HEAD vs candidate, hash-diff
# the C. Identical C ⇒ no lane outcome can change. PROVE selector sensitivity
# on a known-affected PLAIN program first (test-block repros diff 0).
# Recipe + traps: src/test/CLAUDE.md §5.3

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

Full build → test → sync → verify workflow: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).
Windows-host-only traps: [`docs/WINDOWS-TRAPS.md`](docs/WINDOWS-TRAPS.md).

## Build Optimization — default `build` is UNOPTIMIZED (`-O0`)

Opt level and LTO are **separate axes**. `modeFlags` (`src/compiler/cc.ms`): default=`-O0 -g`, `--release`=`-O2`, `--danger`=`-O3`. A plain `build` compiler runs ~4.5x slower than `--danger`.

`--lto` is capability-resolved after the compiler is known (`resolveLto`): `--danger` takes thin LTO where the resolved compiler can link it, drops it with a stderr notice where it cannot, and an explicit `--lto=` against a proven-broken pair fails loud.

```bash
msc build src/index.ms --gc=drc --danger --cc=clang --output=msc   # macOS, +13%
```

**Do not re-litigate**: macOS/zig and Windows/zig cannot LTO (verified 2026-07-30 and 2026-08-31, target-scoped, no flag fixes it from our side); GNU gcc never gets LTO by default and spells it `-flto=auto`. The gain is **LTO, not clang** — clang and zig are equivalent code generators. Capability table: `src/compiler/cc.ms` (`ltoBroken`). Evidence + measurement method: [`docs/BUILD-PERF.md`](docs/BUILD-PERF.md).

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

All five phases COMPLETE. Parse: 37 NodeKind, 80+ TokenKind, recursive descent + Pratt. TypeCheck: 3-pass (collect, resolve, check), cross-module via ExportRegistry. Transform: 20 general + 4 C-backend. Analyzer: DRC injection (~2500 lines, cross-scope last-read, branch-aware optimizer). Codegen: C primary, JS secondary.

`generatorLower` runs BEFORE `lambdaLifting` (reversed from the standard reference's order) — intentional: generator creates `$state` + FunctionExpr, lambda lifting then captures `$state` into env. Output is identical to the reference; the reversed order keeps the two transforms decoupled.

Architecture detail: [`docs/PIPELINE.md`](docs/PIPELINE.md). File tree + patterns: [`docs/PROJECT-STRUCTURE.md`](docs/PROJECT-STRUCTURE.md).

## Entry Point: there is no `main()` auto-call

**Nothing calls `main` for you.** A program is the top-level code of its entry module; `main` is an ordinary function with no special status in codegen (removed 2026-08-16, `15df69d`, both backends). Symptom of relying on the old behaviour: builds and links clean, prints nothing, exits 0.

| Signature | Call site |
|---|---|
| `main(): void` | `main();` |
| `async main()` | `await main();` — preferred (a bare call also completes, but reads like a bug) |
| `main(): number` as exit status | `process.exit(main());` |

- Test-suite programs scored by exit code: a bare `main();` swallows the status and turns a red guard green. Forward it: `const rc = main(); if (rc !== 0) process.exit(rc);`
- **A module that is both a CLI and a test target needs a guard** — a test build still executes top-level code. `src/index.ms` ends with `when (!testBuild) { process.exit(main()); }`. Without it, `msc test src/index.ms` runs the CLI instead of the tests. (`test` is a keyword and cannot be the flag name.)
- **Exit = event loop empty; orphan rejections = exit 1** (Node semantics). `msDrainUntilIdle()` completes pending timers/continuations/pool workers, then `msReportOrphanFailures()` prints unhandled rejections and forces exit 1. `process.exit()` skips both.
- **`MsMain()` is program-wide init, not per-module init** — it runs `__DatInit000()` + `__Init000()` for *every* alive module. For `--app=lib` hosts, call the entry module's own init functions instead (550 KB vs 11.9 KB on `--os=emcc`). Matrix: [`docs/BARE.md`](docs/BARE.md).

## CRITICAL: Codegen Must Be Thin/Dumb

**`src/codegen/c/` is a dumb emitter.** It only dumps what earlier phases already processed. If you find yourself adding logic to C codegen, STOP.

**The rule**: before adding ANY codegen logic, check the standard reference implementation. If it handles the concern before codegen, we must too. Evidence: of 7 C-backend failures traced 2026-03-04, **6 were bugs in Transform/Checker** that merely surfaced in codegen; only 1 (exception runtime types) belonged in codegen.

**Checklist**: (1) reference does it in transform or earlier → Transform. (2) type resolution → Checker. (3) desugaring/lowering → `src/transform/`. (4) pure C syntax emission → only then codegen.

## Writing Idiomatic MetaScript

Looks like TypeScript, differs semantically. Full reference with examples: [`docs/LANG.md`](docs/LANG.md).

**Match** — prefer over if-else chains for enum/string/number dispatch.
- `_` is the wildcard (NOT `default`); `|` for alternatives; `when (…)` for guards
- Bare identifiers are always BINDINGS, never value comparisons
- Expression arms (`=> value`) return implicitly; block arms (`=> { … }`) require explicit `return`
- **`try` in a match arm FAILS** — use if-else when an arm needs `try`
- **`break`/`continue` in a match arm** target the generated switch, not the enclosing loop
- **C-style `for` in a match arm FAILS** (not normalized) — use `while` or `for..of`

**`Result<T, E>` + `try`** — `try expr` unwraps or early-returns the error; `try expr catch fallback` unwraps or substitutes. Fields: `result.ok`, `result.value` (only after `if (r.ok)`), `result.error` (else branch). Internally a boolean-discriminated match-type Union, so the C layout is a tagged union and `r.value` is unreachable when `!r.ok`.

**`interface` = reference type** (heap-allocated, refcounted, constructed from object literals). **`struct` = value type** (stack-allocated, copied). No `implements`, no method dispatch.

**`"a".code`** — compile-time character code, zero runtime cost. Works in match patterns.

**Numeric types — no bare `number` in this compiler.** Project convention, not a language rule. `number` **is** `float64` (8-byte double) and ~98% of values here are integers, so bare `number` wastes memory and is a soundness footgun: `int32[]` was silently accepted where `number[]` was expected and reinterpreted by a raw pointer cast (4- vs 8-byte elements) → out-of-bounds read. Use `int32` for index/length/count/depth/offset/id (`int64` past 2^31), `float64` when genuinely fractional. Bare int literals infer `int32`. Migration tracked in `NUMBER-MIGRATE.md`.

**Null** — MetaScript has no `undefined`. `null as unknown as T` is the idiom for nullable typed fields.

**Loops** — always reach for `for..of` first; C-style `for` when you need the index; `while` only when neither fits (condition-driven scanners, polling, multi-variable termination). Never `let i = 0; while (i < arr.length)`.

| Context | `for..of` | `for (let i…)` | `while` |
|---|---|---|---|
| Top-level / function body | **preferred** | OK | last resort |
| Match arms | **preferred** | **FAILS** | OK |
| Closures / callbacks | **preferred** | OK | last resort |

**TypeScript pitfalls**: `interface` is a data struct, not a contract · `type` is a reserved keyword (use `tokenType`, `nodeType`) · no `indexOf`/`includes` on strings — use `slice`/`length`/`findChar`/`charAt` from `utils/string.ms` · arrays pass by pointer, strings are value types · narrow discriminated unions with `as`.

**Other syntax**: `move` (ownership transfer) · `defer` (LIFO scope-exit) · `unreachable` · `out` parameters · `distinct type` · `extern function` (C FFI) · decorators `@derive`, `@comptime`, `@emit` (backend-conditional code is `when (c) { … }`) · sized integers `int8`…`uint64`, `float32`, `float64`.

## Standard Reference Implementation

**Every fix MUST track the standard reference implementation at `~/projects/nim`** (checker, transform, analyzer, codegen passes) and respect [`docs/NIM-REF.md`](docs/NIM-REF.md). Before changing compiler code: locate the analogous reference pass, read it, and confirm the fix either matches its behaviour or is a documented intentional divergence. Do **not** invent behaviour the reference doesn't have, and do **not** reason from first principles when the reference can be read — verified reference-reading beats reasoning.

If the fix touches **async / actor / spawn / await / parallel**, read [`docs/PARALOCK.md`](docs/PARALOCK.md) first.

Divergences are recorded in [`docs/NIM-REF.md`](docs/NIM-REF.md) — single source of truth, per-subsystem mapping (same / intentional-diverge / incomplete-gap). Do not duplicate divergence rationale here; add it there.

## Runtime C — avoid variadic struct args

When adding helpers in `runtime/core/`, **do not pass 16-byte structs (e.g. `msString`) through `...` variadics**. LLVM/Zig miscompile this on `aarch64-windows-gnu` (AAPCS64 instead of the Microsoft ARM64 variadic ABI): args 4+ read from misaligned stack slots, symptom is a silent crash at module init. Applies to any struct ≥16 bytes or containing pointers; scalars are fine.

```c
msString msStringConcatMany(int64_t count, ...);              // BAD
msString msStringConcatArr(const msString* arr, int64_t n);   // GOOD
```

**Call-site emission**: `emitCallExpr` (`src/codegen/c/expressions.ms`) name-matches `msStringConcatArr` / `msStringArrayFromArr` and rewrites the call to a stack-local array fill + pointer pass. A new array-taking runtime helper needs that intercept extended (family: `msBoxStruct`, `msSpawnInto`, `msWaitForStruct`).

## Backends

- **C**: primary. Deterministic memory management, lifecycle hooks, compile via clang. Phase 4 (Analyzer) required.
- **JavaScript**: secondary. No analyzer, direct emission.
- **Erlang**: POSTPONED.

## Debugging DRC / codegen bugs

Suspect a leak, UAF, or RC-accounting bug? **Do not read `src/analyzer/inject.ms` first.** Write twin minimal probes in MS and Nim, emit C from both, diff the hot loop. Recipe, calibrated RC conventions, and the anti-patterns that waste the most time: [`docs/DRC-PROBE.md`](docs/DRC-PROBE.md). The `/trace-nim` skill wraps this workflow.

IMPORTANT: never mention specific reference projects in all documents or comment inside our source code
