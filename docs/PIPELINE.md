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

`.h` C-header imports are inlined as `extern` decls before parsing (`inlineHeaderImports`).

## Phase 2 — Macro Expansion + Type Checking (`src/checker`, `src/compiler/meta`)

**2a Macro expansion** — `@`-macros and bare-call macros expand eagerly *during* checking
(eager-inline model): `checkCallExpr` rewrites a macro CallExpr → its expansion and
re-checks, so the result type flows back.

**2b Type checking — 3-pass**:
- `collectPass` — gather every declaration (so forward refs / mutual recursion resolve
  regardless of source order).
- `resolvePass` — parse the string type annotations into `Type` objects, enrich symbols.
- `checkPass` / `checkExprPass` — type inference + validation + control-flow checks.

Cross-module symbol resolution via `ExportRegistry`. Flat `Type` interface (all fields
present, unused empty) to avoid self-referencing-struct codegen bugs.

## Phase 3 — Transforms + Normalization (`src/transform`)

Lowers rich syntax to a minimal shape so Phases 4–5 see simple forms. **This is where
complex expressions are lowered to STATEMENTS**, rather than handled inline in the analyzer.

### Infrastructure (`src/transform/`)
- **walker.ms** — three walk modes:
  - `walkNode(node, visitor)` — bottom-up 1:1 (coercions, folding).
  - `walkExpandBlocks(node, expander, ctx)` — 1:N statement-list expansion + recursive
    descent into bodies. The splice-siblings primitive (used by resultDesugar, callHoist).
  - `replaceInExpr(node, replacer)` — bottom-up expression-only rewrite.
- **context.ms** — `TransformContext{tempCounter, errors, fnDeclNames}`; `freshTempSym`
  mints `$prefix_N` symbols; `freshOwnedSym` mints `__prefix_N` for locals the analyzer
  must own — the non-`$` name is load-bearing, `analyzer/inject.ms:1691,1971` treat a
  `$`-prefixed local initialized from an identifier as a cursor and never destroy it.
- **util.ms** — node builders (`makeVarDecl`, `makeIf`, `makeCall`, …) + `evalOnce`
  (capture expr in a temp) + `extractBodyStmts`.

### Ordered general pipeline (`index.ms`) — load-bearing order
defer → … → forLoopLower → forOfLower → matchLower → tailCall → paramReassign → asyncDesugar →
generatorLower → spawn/await/actor lowering → varHoist → lambdaLifting → **callHoist** →
builtinLower → operator/string/subscript lowering → conditionalExprLower → updateExpr →
restParam → … . Order is a contract: e.g. `for`→`while` before `for-of`; `match`→`if`
before generators; `generatorLower` runs after `lambdaLifting` (intentional reversal — see
CONTRIBUTING.md). C-backend-only sub-pipeline runs after: closureCallMarker, pointerParam,
rangeCheckInject, optionalCoercion.

### What Phase 4 (Analyzer) requires Phase 3 to have done
`defer`→try/finally · all `for`→`while` · all `match`→if/else · destructuring→explicit
accesses · `try`-expr→result checks · closures→(fn,env) pairs · per-type
`_destroy/_copy/_sink/_wasMoved` bodies (`destructorLifting`) · generators→state machines.
If the analyzer needs to know something the source still encodes structurally, the rule is
**add a transform, not analyzer logic** (keeps codegen/analyzer thin).

## Phase 4 — Analyze: DRC Injection (C backend only) (`src/analyzer`)

Deterministic Reference Counting: walks the post-transform AST, inserts
`=destroy/=copy/=sink/=wasMoved` calls at the right points. Direct AST rewrite + scope-based
cleanup + conservative last-read (Mohnen graph-free CFG). Three stages: hook lifting
(`destructorLifting`) → injection (`inject.ms` + `classify` + `scope` + `lastRead`) →
optimization (`optimize.ms`, redundant-op elimination). See [`ANALYZER.md`](ANALYZER.md)
for the RC insertion-point table and the moveOrCopy decision tree. DRC convention:
`msAlloc` returns rc=0 = sole owner; `msDecRefIsLast` true at rc==0 (rc counts the owners beyond the first).

## Phase 5 — Backend Codegen (`src/codegen/c`, `src/codegen/js`)

**Codegen is a thin/dumb emitter** — it only dumps what earlier phases produced. If you find
yourself adding logic to codegen, it almost certainly belongs in Transform or Checker
(evidence: 6 of 7 traced "codegen" bugs were really Transform/Checker bugs). C backend needs
Phase 4; JS backend skips it (JS GC handles lifetime). Codegen reads the alive-symbol set
(DCE), closure-vs-direct-call list (closureCallMarker), and emits per-`Promise<T>` future
structs, per-type lifecycle hooks, etc.

---

## AST node kinds by phase (orientation)

Phase 1 introduces the full surface syntax (~58 NodeKinds: literals, expressions, statements,
declarations, error-handling). Phase 2 adds macro/check synthetic kinds. Phase 3 *removes*
rich kinds (match, for, defer, try-expr, ternary-in-stmt) and adds lowered forms (while,
if/else, state machines, lifted functions, temps). Phases 4–5 add ~0 new kinds — they
annotate/emit. Net: by Phase 5 the AST is a small, C-shaped subset.

---

## RAISER VM — compile-time execution & metaprogramming (`src/codegen/raiser`, `runtime/raiser`)

RAISER executes MetaScript at **compile time** (`@comptime`, macro bodies, const folding).
It consumes the **post-transform AST** — so it never has to understand `match`/`defer`/`for`
natively; Phase 3 already lowered them.

**Core architecture:**
- **Register-based** instruction set (256 slots) — ~30% less dispatch overhead than stack VMs.
- **Computed-goto** dispatch (`vm_dispatch.h` / `dispatch.c`).
- **Handle-based arena** memory (`ObjectHeap`/`ArrayHeap`, monotonic growth — short-lived
  comptime tasks).
- **Flat tagged `RaiserValue`** (Nil/Bool/Int/Float/String/Array/Object), kind-dispatched.

Flow: `Source → Parse → Check → Transform → Raiser codegen (primitives→bytecode) → Raiser VM
(execute, fold results back into the AST)`.

### CallHost — reaching host std from comptime bytecode

Comptime MS code (e.g. `exec("pkg-config …")`) is pure MS compiled to bytecode, but it
bottoms out in operations the VM cannot perform itself (fs, process, env). RAISER reaches
them through a **name-keyed registry of MS host functions** — no dlopen, no generated C.

**Two layers:**
- **Layer 1** — pure-MS wrappers in `std/*` (`readFile`, `exec`, `env`), compiled to bytecode,
  run inside the VM.
- **Layer 2** — host bridges: `src/compiler/meta/hostTable.ms` registers ~40
  `RaiserHostFn` wrappers under the extern's native name
  (`registerHostFn("msFsReadFile", …)`).

**Mechanism:**
- Loading (lazy): the first `@comptime`/macro evaluation calls
  `ensureHostTableLoaded()` (`codegen/raiser/eval.ms`), which populates the
  registry in `src/raiser/hostRegistry.ms` once per process.
- Checking: macros always check against the `.rms` prelude
  (`buildPreludeContext(stdPath, ".rms")`) regardless of the build target, so
  extern declarations resolve to `CallHost` call sites.
- Codegen: a call whose callee symbol carries `nativeName` emits
  `CallHost R0, nameIdx, argc` — the NAME rides in the constant pool.
- Execution: VM dispatch looks the name up in the registry, unboxes the args,
  calls the MS bridge (which itself calls the host compiler's std — the same
  `shared.ms`/std sources the C backend compiles), and boxes the result.

Known gaps, tracked in `src/raiser/CLAUDE.md` §std Access: the table is
hand-maintained (an extern added to `.rms` without a bridge fails at runtime
with "Unknown host function"), and nothing yet enforces closure. The
originally-sketched alternative — a build-time-generated C table of
`{name, fnPtr, sigTag}` letting the VM call statically linked natives
directly — is the `CallExtern` direction on the roadmap (Phase 5), not the
current mechanism.

---

## Trans-Am — incremental computation (`src/transam`)

Memoized query engine (incremental rebuild): caches phase results keyed by content hash so
re-compilation only recomputes what changed. Used by the LSP and watch builds.

---

## Module dependency rules

Each module dir has an `index.ms` hub re-exporting its public API. Circular imports between
sub-parsers are broken via **callback injection** (`callbacks.ms` holds function pointers;
`core.ms` registers real implementations at load) — sub-parsers import only from
`callbacks.ms`. Target source is parsed by our own parser as raw strings, so parse bugs
are always in `src/parser`.
