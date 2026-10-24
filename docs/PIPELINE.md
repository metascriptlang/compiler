# PIPELINE — Compiler Architecture

> Architecture/design guideline for the compilation pipeline. How the phases fit
> together, what each owns, and the contracts between them. Not a roadmap or status
> tracker. For the concurrency model see [LANG-CONCURRENCE.md](LANG-CONCURRENCE.md).

```
Source.ms → [1 Parse] → [2 Check] → [3 Transform] → [4 Analyze] → [5 Codegen] → C / JS
```

The compiler is self-hosted (written in `.ms`) — each generation is built by the
previous one, and it parses target source with its own parser. Primary backend is **C** (full
DRC); **JS** is secondary (no analyzer needed). Erlang is postponed.

---

## Phase 1 — Parse + Module Loading (`src/lexer`, `src/parser`, `src/ast`, `src/module`)

Recursive-descent + Pratt precedence. Produces the full AST (named-field discriminated
union `NodeData`, not a generic child array). Module loading resolves imports
eagerly (`loadSourceModule` → lex → `callStateProgramParser` → walk import decls).

A `.h` import is a module whose source `headerModuleSource` translates from the C header before it is lexed (see [`src/module/CLAUDE.md`](../src/module/CLAUDE.md)).

## Phase 2 — Macro Expansion + Type Checking (`src/checker`, `src/compiler/meta`)

**2a Macro expansion** — `@`-macros and bare-call macros expand eagerly *during* checking
(eager-inline model): `checkCallExpr` rewrites a macro CallExpr → its expansion and
re-checks, so the result type flows back.

**2b Type checking — 3-pass**:
- `collectPass` — gather every declaration (so forward refs / mutual recursion resolve
  regardless of source order).
- `resolvePass` — parse the string type annotations into `Type` objects, enrich symbols.
- `checkPass` / `checkExprPass` — type inference + validation + control-flow checks.

Two drivers run the three passes, and neither calls the other: `checkModuleGraph`
(`src/checker/orchestrator.ms`) checks every module on the `msc build` / `run` / `test` path, and
`checkProgramCore` (`src/checker/checkPass.ms`) is the single-program path. A new per-module pass
goes into both and must be idempotent, and it is proven by `msc run`, not only by unit tests.
`checkProgramWithRegistry` then checks each module a second time with a fresh ctx, so
`lookupModuleCtx(ctx.modulePath)` there returns the ctx from the first check. Compare
`ctx.modulePath` before that lookup when the module may be the one being checked.

Do not add locals or branches inside the `NodeKind.BinaryExpr` arm of `checkExprPass.ms`. The
checker's flow analysis on that arm grows exponentially and hung the self-host build for 35
minutes at 100% CPU without ever reaching clang (observed 2026-08-30, not re-measured). Put new
operator logic in a helper in `fit.ms` (like `checkBitwiseOperands`), called once next to the
existing `effLeft`/`effRight` reads. A build at 100% CPU with flat RSS and no clang child is
hung: `sample <pid>` it.

Cross-module symbol resolution via `ExportRegistry`. Flat `Type` class (all fields
present, unused empty) to avoid self-referencing-struct codegen bugs.

## Phase 3 — Transforms + Normalization (`src/transform`)

Lowers rich syntax to a minimal shape so Phases 4–5 see simple forms. **This is where
complex expressions are lowered to STATEMENTS**, rather than handled inline in the analyzer.

### Infrastructure

- **Walks.** `ast/visitor.ms` owns the child traversal that transform and analyzer share: `forEachChild`,
  `mapChildren`, and `anyChild` / `anyDescendant` (a search with early exit, in place of a
  found-flag walk). `transform/walker.ms` builds the bottom-up 1:1 rewrites on it (`walkNode`,
  `replaceInExpr`); `blockExpand.ms` is the 1:N statement-list walk, the primitive for a pass
  that splices siblings (`walkExpandBlocks`); `walkEffects.ms` answers evaluation-order
  questions (`hasEffect`, `walkOnceEvaluated`). `walker.ms` re-exports the other two, so a pass
  imports one module.
- **context.ms** — `TransformContext` carries the temp counter, the errors, the checker
  context, the backend flags, and one hand-off field per pass pair (a pass that records what a
  later pass must emit). `freshTempSym` mints `$prefix_N` temps and `freshOwnedSym` mints
  `__prefix_N` locals that own a value.
- **util.ms** — node builders (`makeVarDecl`, `makeIf`, `makeCall`, …) and `evalOnce` (capture
  an expression in a temp). `place.ms` clones a place expression for a second read or write;
  `numKinds.ms` and `maybeCarrier.ms` hold the numeric-kind and `Maybe` facts several passes
  share. A pass that needs one imports it from there rather than copying it.

### Order of passes

The order is the code: `transformProgram` in `src/transform/index.ms` (one list, each
step gated by `jsBackend` where a backend needs it) and, for C only, `transformForNative` in
`src/transform/native/index.ms`; [`TRANSFORM.md`](TRANSFORM.md) tracks it per pass. Do not copy
the list into a doc. Order is a contract, and these edges hold in `index.ms` at `99ff1ce60`:
`for` lowers to `while` before `for-of`; `switch` and `match` lower to `if` before `async` and
generators; `async` lowers before `generatorLower`; `generatorLower` runs before `lambdaLifting`
(the reverse of the usual order, on purpose: the generator creates `$state` and a function
expression, and lifting then captures `$state` into the environment; a nested routine is rebuilt
at each resume rather than stored in the frame); `callHoist` runs after `lambdaLifting`;
`destructorLifting` is the last step of `transformProgram`; on C the `native/` tail follows it.

### What Phase 4 (Analyzer) requires Phase 3 to have done
`defer`→try/finally · all `for`→`while` · all `match`→if/else, or a C `switch` when the
discriminant is ordinal (`SwitchStmt`, the one control kind the analyzer still dispatches) · destructuring→explicit
accesses · `try`-expr→result checks · closures→(fn,env) pairs · per-type
`_destroy/_copy/_sink/_wasMoved` bodies (`destructorLifting`) · generators→state machines.
If the analyzer needs to know something the source still encodes structurally, the rule is
**add a transform, not analyzer logic** (keeps codegen/analyzer thin).

## Phase 4 — Analyze: DRC Injection (C backend only) (`src/analyzer`)

Deterministic Reference Counting: `analyzeProgram` (`src/analyzer/index.ms`) walks the
post-transform AST and inserts `=destroy/=copy/=sink/=wasMoved` calls at the right points
(`injectProgram`, with `classify` deciding what each type needs and `scope` tracking the
cleanup owed per scope), then `optimizeDrc` removes the redundant pairs. Two analyses feed the
injector: cursor inference (`cursors.ms`, which variables only borrow) and last-read over a
graph-free CFG (`cfg.ms`, with `alias.ms` for path aliasing). A cursor is found by that
inference, not by a `$` name: a user local `$t = s` and `t = s` emit the same C. Per-type hook
bodies are not made here: `destructorLifting` makes them at the end of Phase 3. See
[`ANALYZER.md`](ANALYZER.md) for the RC insertion-point table and the moveOrCopy decision tree.
The reference-count convention (`msAlloc` returns rc=0 for a sole owner) is in `runtime/drc.h`.

### After DRC, before codegen (C only) — `transform/native/nativeLower.ms`

The C driver's order is `transformProgram` → `transformForNative` → `analyzeProgram` →
`lowerNativeAccess` (`src/compiler/compile.ms`). `lowerNativeAccess` rewrites array and string
access to runtime macros. Before it, `blockReduce.ms` versions a checked signed-integer
reduction (`acc += xs[i]`, `acc -= x`, `acc += a[i] * b[i]`) into guarded blocks: a block whose
sum provably cannot overflow runs as a plain sum, otherwise the unchanged checked body runs and
stops at the exact element. It runs after DRC because the cursor analysis counts any pointer
passed to a call as a possible mutation and would then own the borrowed array. Pins:
`src/test/c/blockReduce.ms`, `src/test/corpus/programs/blockReduce*`.

## Phase 5 — Backend Codegen (`src/codegen/c`, `src/codegen/js`)

**Codegen is a thin/dumb emitter** — it only dumps what earlier phases produced. If you find
yourself adding logic to codegen, it almost certainly belongs in Transform or Checker
(evidence: 6 of 7 traced "codegen" bugs were really Transform/Checker bugs). C backend needs
Phase 4; JS backend skips it (JS GC handles lifetime). Codegen reads the alive-symbol set
(DCE), closure-vs-direct-call list (closureCallMarker), and emits per-`Promise<T>` future
structs, per-type lifecycle hooks, etc.

---

## AST node kinds by phase (orientation)

Phase 1 introduces the full surface syntax (`NodeKind` in `std/meta/node.ms`: literals, expressions, statements,
declarations, error-handling). Phase 2 adds macro/check synthetic kinds. Phase 3 *removes*
rich kinds (match, for, defer, try-expr, ternary-in-stmt) and adds lowered forms (while,
if/else, ordinal switch, state machines, lifted functions, temps). Phases 4–5 add ~0 new kinds — they
annotate/emit. Net: by Phase 5 the AST is a small, C-shaped subset.

---

## RAISER VM — compile-time execution & metaprogramming (`src/codegen/raiser`, `src/raiser`)

RAISER executes MetaScript at **compile time** (`@comptime`, macro bodies, const folding),
and whole programs under `msc run --target=raiser`. It consumes the **post-transform AST**
(`transformForRaiser`) and skips Phase 4 and Phase 5.

**Core architecture:**
- **Register-based** instruction set; the word file and the ref file each start at 256 slots and grow.
- **One `switch` dispatch** in `src/raiser/vm.ms`, one arm per opcode.
- **Handle-based heaps** (`ObjectHeap`/`ArrayHeap`), one per strand: arena by default,
  refcount + cycle collector under `gcMode = "orc"`.

Design, measured status and what is not built: [`RAISER.md`](RAISER.md).

Flow: `Source → Parse → Check → Transform → Raiser codegen (primitives→bytecode) → Raiser VM
(execute, fold results back into the AST)`.

### CallHost — reaching host std from comptime bytecode

Comptime MS code (e.g. `exec("pkg-config …")`) is pure MS compiled to bytecode, but it
bottoms out in operations the VM cannot perform itself (fs, process, env). RAISER reaches
them through a **name-keyed registry of MS host functions** — no dlopen, no generated C.

**Two layers:**
- **Layer 1** — pure-MS wrappers in `std/*` (`readFile`, `exec`, `env`), compiled to bytecode,
  run inside the VM.
- **Layer 2** — host bridges: `src/compiler/meta/hostTable.ms` registers
  `RaiserHostFn` wrappers under the extern's native name
  (`registerHostFn("msFsReadFile", …)`).

**Mechanism:**
- Loading (lazy): the first `@comptime`/macro evaluation calls
  `ensureHostTableLoaded()` (`codegen/raiser/eval.ms` calls it, `compiler/meta/hostTable.ms` defines it), which populates the
  registry in `src/raiser/hostRegistry.ms` once per process.
- Checking: macros always check against the `.rms` prelude
  (`buildPreludeContext(stdPath, ".rms")`) regardless of the build target, so
  extern declarations resolve to `CallHost` call sites.
- Codegen: a call whose callee symbol carries `nativeName` emits
  `CallHost R0, nameIdx, argc` — the NAME rides in the constant pool.
- Execution: VM dispatch looks the name up in the registry, unboxes the args,
  calls the MS bridge (which itself calls the host compiler's std — the same
  `shared.ms`/std sources the C backend compiles), and boxes the result.

Known gaps, tracked in [`RAISER.md`](RAISER.md) §std access: the table is
hand-maintained; an extern added to `.rms` without a bridge compiles with a
`no host bridge` warning at the call site and fails at runtime with
"Unknown host function". The
originally-sketched alternative — a build-time-generated C table of
`{name, fnPtr, sigTag}` letting the VM call statically linked natives
directly — is the `CallExtern` direction on the roadmap (Phase 5), not the
current mechanism.

---

## Trans-Am — incremental computation (`src/compiler/transam`)

Memoized query engine (incremental rebuild): each phase result is a cache entry keyed by
(query kind, file id), and a dependency recomputed to the same output hash leaves its dependents
valid, so re-compilation only recomputes what changed. `checkModuleGraph` and the LSP use it.
Design: [`TRANSAM.md`](TRANSAM.md).

---

## Module dependency rules

Circular imports are broken by **callback injection**: a `callbacks.ms` holds function slots and
the module that owns the real implementation registers it at load. There are four:
`parser/statements/callbacks.ms`, `checker/checkerCallbacks.ms`,
`compiler/meta/callbacks.ms`, `compiler/fmt/printer/callbacks.ms`. A new import edge that
reorders module init can read a callback before it is registered: an import of
`checker/checkExprPass` from a pass under `src/transform/` built clean and then SIGSEGV'd every
C compile while JS compiles kept working (observed 2026-08-01, not re-measured).
Target source is parsed by our own parser as raw strings, so parse bugs
are always in `src/parser`.
