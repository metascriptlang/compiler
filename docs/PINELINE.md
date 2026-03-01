# Compilation Pipeline

6 phases from `compile.zig:295`. Phases 1-2 = frontend (shared with LSP). Phases 3-5 = backend (compilation only).

```
                                              [Monomorphize]  (for C and Raiser)
                                                    |
                                                    v
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
                 \_______________\________________\________________\_______________/
                                    Trans-Am (incremental query cache)
```

---

## Phase 1: Parse + Module Loading (src/parser,lexer,ast,module)

Lex source into tokens, parse tokens into AST, recursively load all imported modules.

| Step | What it does |
|------|-------------|
| Tokenize | Source text to token stream |
| Parse | Token stream to AST (recursive descent + Pratt) |
| Module resolve | `resolver.ms`: translate import specifiers to candidate absolute paths |
| Module load | `loader.ms`: depth-first recursive loading with cycle detection, topological ordering |
| Module graph | `graph.ms`: lightweight Module/ModuleGraph data structures (primitives only, no Node/Symbol fields) |

### Self-Hosted Module Loading (`src/module/`)

```
entryPath
  → resolver.resolveImport(specifier, fromFile) → ResolveCandidates { paths[] }
  → loader.loadModule(graph, path, provider)    → Module (source + state + imports)
  → ModuleGraph { modules[], loadOrder[] }       — topological order for checking
```

**Key design decisions:**
- **Module is lightweight** — only primitive fields (string, string[], enum). NO Node, Symbol, or SymbolTable fields. This avoids the DRC lifecycle mangling bug where lifecycle hooks for transitively reachable types get wrong module path mangling.
- **ASTs not stored on Module** — re-parsed from `Module.source` each pass. Inefficient (3x parse per module) but avoids DRC codegen crash.
- **SourceProvider abstraction** — `MapProvider` for tests (string→string map), real file I/O provider TBD.
- **Cycle detection** — module state machine (`Unloaded→Loading→Parsed→Ready`). Re-encountering a `Loading` module = circular import.
- **Topological order** — depth-first loading naturally produces correct `loadOrder` (dependencies before dependents).

**Input:** `.ms` source file path
**Output:** ModuleGraph with sources, import entries, topological load order

---

## Phase 2: Macro Expansion + Type Checking (src/checker)

Expand macros first (Hermes VM), then run 3-pass type checking.

                           ast/node.ms
                          (Node, NodeKind)
                               │
                ┌──────────────┼──────────────┐
                ▼              ▼              ▼
           types.ms       symbol.ms      context.ms
          (TypeKind,     (SymbolTable,   (CheckerContext,
           Type)          Scope chain)   ExportRegistry,
                │              │         ExtensionRegistry)
                └──────┬───────┴──────┬───────┘
                       ▼              ▼
                collectPass.ms  resolvePass.ms
                 (Pass 1)        (Pass 2)
                       │              │
                       └──────┬───────┘
                              ▼
                        checkPass.ms ◄── compat.ms
                       (Pass 3: stmts)   (isAssignable,
                              ▲           scoreCandidate)
                              │
                    checkerCallbacks.ms
                     (circular break)
                              │
                              ▼
                      checkExprPass.ms
                       (Pass 3: exprs)
                              │
                              ▼
                      orchestrator.ms (multi-module)
                              │
                              ▼
                          index.ms (hub + integration tests)

### 2a: Macro Expansion

Hermes VM evaluates `@derive`, `@comptime`, custom `macro!()` invocations. Replaces `macro_invocation` nodes with generated AST subtrees.

### 2b: Type Checking -- 3-Pass (Industry Standard)

Proven pattern used by TypeScript, Go, C#/Roslyn, Java/javac, JS++, and Swift.

| Pass | Purpose | Reference (`compile.zig`) | Self-Hosted (`checker/`) |
|------|---------|--------------------------|--------------------------|
| **1. Collect** | Register all declarations from all modules (names + signatures) | `collectDeclarations()` | `collectTopLevel()` |
| **2. Resolve** | Resolve type references, propagate import/export types cross-module | `propagateExports` + `TypeResolver.resolve()` | `resolveDeclarations()` + `ExportRegistry` cross-module propagation |
| **3. Check** | Infer expression types + validate compatibility | `TypeInference.infer()` + `checkTypes()` | `checkProgramBody()` |

**Why 3-pass over single-pass like legacy impl (research-backed):**

Industry evidence (Feb 2026 survey of 8 production compilers):
- Every compiler supporting forward references without forward declarations uses
  a dedicated declaration collection pass before type resolution.
  requires forward declarations and has limited circular import support (RFC #6
  open since 2016, "functionally inadequate").
- The 3-pass pattern (collect -> resolve -> check) is independently adopted by
  Go (`collectObjects -> packageObjects -> processDelayed`),
  C#/Roslyn (`Declaration -> Bind -> Emit`),
  JS++ (`parse+collect -> resolve -> check`),
  Java/javac (`Enter Phase 1 -> Enter Phase 2 -> Attr`).

Concrete advantages over single-pass:
- **Forward references without workarounds** -- no `tyForward` placeholders,
  no `sfForward` flags, no deferred body hacks.
- **Circular import support** -- Pass 1 collects from ALL modules before any
  resolution begins. JS++ chose 4 passes specifically for this.
- **Better error messages** -- full context available before reporting.
- **Incremental implementation** -- each pass is independently buildable/testable.

Self-hosted status: All 3 passes implemented. Multi-module type propagation complete:
- `checkModuleGraph()` checks modules in topological order, each getting all 3 passes (Nim-aligned: per-module 3-pass, not 3 passes across all modules)
- Export marking via `isExported` flag on Symbol (simpler than Nim's dual public/hidden tables)
- Cross-module type propagation via `ExportRegistry` — exports registered after each module's 3-pass, imported types resolved from registry in downstream modules' collect pass
- Extension method registry (`ExtensionRegistry`) tracks `function f(this self: Type)` declarations for UFCS-style member resolution (instance + static)
- Cross-module extension propagation: `ExportedSymInfo` carries `extReceiverType`/`extIsStatic`, `collectImport()` registers imported extensions in local registry
- Generic extension inference: `unifyType()` recursive structural matching extracts type params from receiver (e.g., `T[]` vs `string[]` → `T=string`), pre-substituted in `checkMemberExpr`
- Function overload resolution via `scoreCandidate()` in `compat.ms` (TypeRelation scoring: Exact > FromLiteral > Generic > Subtype > IntConv > Convertible > None)

Trans-Am incremental engine (see §Trans-Am below) is fully compatible with 3-pass.
Queries work regardless of how many internal passes the checker uses.

Codegen-related concerns (type canonicalization, lifecycle hook synthesis,
discriminant analysis) are handled as pre-processing when those phases are
implemented -- separate from the type checker's pass count.

### 2b-note: Reference Compiler Bloat Analysis

Reference checker is ~51,876 lines, quite bloated. Root causes to avoid in self-hosted implementation:

| Bloat Source | Lines Wasted | Fix |
|-------------|-------------|-----|
| Imperative builtin registration | ~5,000 | Table-driven: declare data arrays, register in loop |
| Duplicated AST traversal (collectDecl + checkTypes share 21 node handlers) | ~1,200 | Shared visitor or store enough in Pass 1 to avoid re-discovery |
| 18 redundant type switch statements in inference | ~2,000 | Shared helpers: `isNumeric(t)`, `isCallable(t)`, `getReturnType(t)` |
| resolver.zig as separate full AST walk | ~3,277 | Resolve type references lazily at point of use in Pass 3 |
| LSP tracking scattered (48 calls) in checker hot path | ~500 | Separate post-pass or event/hook system |

### 2c: Type Registration

Pre-compute all struct/array/tuple/Result type definitions into a `TypeRegistry` for fast codegen lookup. Eliminates runtime HashMap queries.

**Input:** Parsed AST from Phase 1
**Output:** Fully typed AST, symbol table, type registry, lifecycle hooks

---

## Phase 3: Transforms + Normalization — COMPLETE

Multiple sub-transforms that rewrite the typed AST before codegen. All 27 general-purpose transforms fully implemented with Nim/reference compiler parity. 4 C-backend transforms fully implemented.

### 3a: Self-Hosted Transform Pipeline (27 general-purpose transforms)

Fixed execution order — each transform may depend on results of earlier ones.

| # | Transform | File | Strategy | What it does |
|---|-----------|------|----------|-------------|
| 1 | deferLower | `lowering/deferLower.ms` | 1:N expand | `defer cleanup()` → try/finally wrapping |
| 2 | constantFolding | `coercion/constantFolding.ms` | 1:1 visitor | `2+3` → `5`, `"a"+"b"` → `"ab"`, `!true` → `false` |
| 3 | stringConcatFlatten | `coercion/stringConcatFlatten.ms` | 1:1 visitor | `"a" + x + "b"` → `ms_string_concat("a", x, "b")` |
| 4 | optionalChain | `coercion/optionalChain.ms` | 1:1 visitor | `a?.b` → `a != null ? a.b : null` |
| 5 | nullishCoalesce | `coercion/nullishCoalesce.ms` | 1:1 visitor | `x ?? 42` → `x != null ? x : 42` |
| 6 | typeCoercion | `coercion/typeCoercion.ms` | 1:1 visitor | `String(x)` → `x.toString()` |
| 7 | stringTruthiness | `coercion/stringTruthiness.ms` | 1:1 visitor | `if (str)` → `if (str.length > 0)` |
| 8 | destructuringLower | `desugar/destructuringLower.ms` | 1:N expand | `const [a,b] = f()` → temp + indexed access |
| 9 | spreadExpand | `desugar/spreadExpand.ms` | 1:1 visitor | `fn(...[a,b])` → `fn(a,b)` (array literal inline) |
| 10 | arrayMethodInline | `desugar/arrayMethodInline.ms` | 1:N expand | `arr.map/filter/reduce(fn)` → inline while loops (zero call overhead) |
| 11 | forLoopLower | `lowering/forLoopLower.ms` | 1:1 visitor | `for(init;cond;update)` → `{ init; while(cond) { body; update; } }` |
| 12 | forOfLower | `lowering/forOfLower.ms` | 1:N expand | `for (x of arr)` → while loop with iterator |
| 13 | resultDesugar | `desugar/resultDesugar.ms` | 1:N expand | `const x = try f` → result check + value extract |
| 14 | resultFieldCheck | `desugar/resultFieldCheck.ms` | 1:1 visitor | `$result_N.value` → `{ check(r); r.value; }` |
| 15 | matchLower | `lowering/matchLower.ms` | 1:N expand | `match (x) { ... }` → if/else chain |
| 16 | tailCallLower | `lowering/tailCallLower.ms` | 1:1 visitor | Tail-recursive calls → while loop with param reassignment |
| 17 | asyncDesugar | `lowering/asyncDesugar.ms` | custom walk | `await` → `yield`, flip async → generator flag |
| 18 | generatorLower | `lowering/generatorLower.ms` | custom walk | `function*` → state machine returning iterator object |
| 19 | varHoist | `lowering/varHoist.ms` | custom walk | `var` declarations → hoisted to function scope top (JS semantics) |
| 20 | lambdaLifting | `lowering/lambdaLifting.ms` | custom walk | Closures with captures → lifted functions + env structs |
| 21 | rvalueLower | `lowering/rvalueLower.ms` | 1:N expand | `f().method(args)` → `{ const $rval = f(); $rval.method(args); }` — materialize rvalue receivers (evalOnce pattern) |
| 22 | extensionMethodLower | `lowering/extensionMethodLower.ms` | 1:1 visitor | `obj.method(args)` → `method(obj, args)` for UFCS extension methods |
| 23 | subscriptLower | `lowering/subscriptLower.ms` | 1:1 visitor | `obj[idx]` → `` `[]`(obj, idx) ``, `obj[idx]=v` → `` `[]=`(obj, idx, v) `` for custom subscript operators |
| 24 | conditionalExprLower | `lowering/conditionalExprLower.ms` | 1:1 visitor | `a ? b : c;` → `if (a) { b; } else { c; }` in statement position |
| 25 | updateExprLower | `lowering/updateExprLower.ms` | 1:1 visitor | `x++;` → `x = x + 1;` in statement position |
| 26 | dce | `analysis/dce.ms` | 2-tier | Dead code elimination: Level 1 statement-level (endsInNoReturn, dead branch/while) + Level 2 symbol-level mark-sweep reachability |
| 27 | destructorLifting | `lowering/destructorLifting.ms` | custom walk | Full Nim parity: 6 lifecycle hooks + TypeInfo per type (see below) |

Nim `transf.nim` coverage: `transformCase` (matchLower), `liftDeferAux` (deferLower), `transformFor` (forOfLower), `transformAsgn` (destructuringLower), `commonOptimizations` (constantFolding), `forceBool` (stringTruthiness), `lambdalifting.nim` (lambdaLifting), `closureiters.nim` (generatorLower), `liftdestructors.nim` (destructorLifting), `semstmts.nim:endsInNoReturn` + `ic/dce.nim:AliveSyms` (dce). Reference `normalize.zig` Pass 7 coverage: UFCS extension method rewriting (extensionMethodLower). Reference `subscript_lower.zig` coverage: custom `[]`/`[]=` operator lowering (subscriptLower). Reference `normalize.zig` conditionalExprLower + updateExprLower coverage: ternary→if and ++/-- → assignment in statement position. Reference `rvalue_lower.zig` coverage: rvalue receiver materialization (rvalueLower). Reference `array_map_lower.zig` + `array_method_inline.zig` coverage: map/filter/reduce inline expansion (arrayMethodInline). Reference `var_hoist.zig` coverage: JS-style var declaration hoisting to function scope (varHoist).

**Status: All 27 general transforms COMPLETE.** Full parity with Nim `transf.nim` and reference compiler `transform/pipeline.zig` for all transforms that apply to MetaScript's feature set. See §3d for intentionally skipped transforms.

#### Destructor Lifting — Nim `liftdestructors.nim` Parity

Generates up to 6 lifecycle hooks per type + `msTypeInfo` for ORC runtime:

| Hook | Signature | Purpose |
|------|-----------|---------|
| `=destroy` | `TypeName_destroy(self)` | Cleanup RC fields (reverse field order, then base class) |
| `=copy` | `TypeName_copy(dest, src)` | Deep copy (assign + incref), self-assignment guard |
| `=sink` | `TypeName_sink(dest, src)` | Move (transfer ownership), self-assignment guard |
| `=wasMoved` | `TypeName_wasMoved(self)` | Zero RC handles after move |
| `=dup` | `TypeName_dup(src): TypeName` | Clone (init + copy, return) |
| `=trace` | `TypeName_trace(self, callback)` | ORC cycle tracing (cyclic types only) |
| TypeInfo | `TypeName_typeInfo` | `msTypeInfo` struct (name, is_cyclic, trace_fn, destroy_fn) |

Key features matching Nim:
- **`fillBody` routing table** — dispatches TypeKind to 7 type family helpers (string, array, ref, closure, map, set, namedObj)
- **`cyclicType` detection** — memoized analysis determines if a type can form reference cycles (Ref/Ptr/Function/recursive Object)
- **Inheritance** — base class hook ordering (destroy: fields-first LIFO then base; copy/sink/trace: base-first then fields)
- **Distinct type delegation** — resolves to base type, shares hooks
- **Tuple field iteration** — per-field hook generation
- **`considerUserDefinedOp`** — user-defined `_onDestroy`/`_onCopy`/etc. override synthetic body
- **Self-assignment check** — `if (dest === src) return;` for copy/sink hooks

### 3b: C-Backend Transform Pipeline (4 transforms)

Run after general transforms, only when targeting C backend. Located in `transform/c/`.

| # | Transform | File | What it does | Status |
|---|-----------|------|-------------|--------|
| 1 | closureCallMarker | `c/closureCallMarker.ms` | Collect function names for closure vs direct call distinction | Complete |
| 2 | pointerParam | `c/pointerParam.ms` | Identify pointer-type parameters (interfaces/classes → T* in C), exports `isPrimitiveTypeName()` | Complete (heuristic + checker integration) |
| 3 | rangeCheckInject | `c/rangeCheckInject.ms` | `expr as int8` → `ms_chck_range_i8(expr, -128, 127)` for narrowing integer casts | Complete (parser now stores `asType` in TypeAssertionData) |
| 4 | optionalCoercion | `c/optionalCoercion.ms` | `return null` → `ms_optional_null()`, `return expr` → `ms_optional_wrap(expr)` in T\|null functions | Complete (wraps all returns, recurses into if/else branches) |

### 3c: Deferred Transforms (Future Phases)

| Transform | Why Deferred |
|-----------|-------------|
| locResolve | Needs codegen implementation |

### 3d: TODO — Needed Transforms Not Yet Implemented

| Transform | What | Why needed | Priority |
|-----------|------|-----------|----------|
| ~~recordToMap~~ | ~~`Record<K,V>` → `Map<K,V>`~~ | DONE — implemented in `resolvePass.ms` (Phase 2 type resolution, not a transform) | ~~High~~ |
| ~~extensionMethodLower~~ | ~~`obj.method(args)` → `method(obj, args)`~~ | DONE — added as step 19 in §3a | ~~High~~ |
| ~~subscriptLower~~ | ~~Custom `[]` operator → function call~~ | DONE — added as step 20 in §3a. Also added backtick-stropped function names in parser. | ~~Medium~~ |

### 3e: Correctly Skipped

| Transform | Reference has it | Reason |
|-----------|:---:|--------|
| dateLower | yes | Runtime-specific (Date → ms_date_now). Add when Date runtime exists |
| spreadLower | yes | Dynamic `f(...args)` — JS-only (f.apply pattern) |
| functionInlining | yes | Optimization, not correctness |
| constantPropagation | yes | Deprecated in reference compiler |
| logicalShortCircuit | yes | C handles `&&`/`\|\|` natively |

### 3f: ~~Maybe-Needed~~ — DONE

| Transform | What | Status |
|-----------|------|--------|
| ~~conditionalExprLower~~ | ~~ternary → if-stmt~~ | DONE — added as step 21 in §3a (statement position only) |
| ~~updateExprLower~~ | ~~`x++`/`x--` → assignment~~ | DONE — added as step 22 in §3a (statement position only) |

**Input:** Typed AST + symbol table
**Output:** Transformed AST + alive symbol set

---

## Phase 4: Analyzer — DRC Injection (C backend only)

Deterministic reference counting injection (Nim `injectdestructors` pattern). Direct AST rewrite — walks each function body with scope stack, inserting RC calls inline.

### 4a: Self-Hosted DRC Analyzer (`src/analyzer/`)

6 modular files, ~900 lines total:

| File | Lines | Purpose |
|------|-------|---------|
| `classify.ms` | ~195 | Type → RC classification: maps TypeKind to RcInfo (destroy/copy/wasMoved/sink function names) |
| `scope.ms` | ~185 | DrcScope/DrcContext: push/pop scope, track vars needing cleanup, move tracking, needsTry propagation |
| `lastRead.ms` | ~300 | isLastReadInBlock (forward scan) + nodeReferencesVar (recursive) + deepAliases (self-assignment safety) |
| `inject.ms` | ~370 | Main AST walker: per-statement dispatch, VarDecl/Assignment/Return/DiscardedCall processing |
| `optimize.ms` | ~210 | Post-optimizer: eliminate redundant `wasMoved(x); destroy(x)` pairs |
| `index.ms` | ~100 | Hub: `analyzeProgram` entry point, re-exports, integration tests |

**Architecture decisions:**
- **Direct AST rewrite** — no intermediate RcOp. Insert RC call nodes directly.
- **Scope-based cleanup** — push on block/function entry, track RC vars, emit `=destroy` LIFO on exit.
- **Conservative isLastRead** — forward scan within statement list. CFG upgrade deferred.
- **Post-optimizer** — eliminate `wasMoved(x); =destroy(x)` pairs.

**RC insertion points:**

| Context | RC Action |
|---------|-----------|
| `const x = fresh()` | SINK — ownership transfers |
| `const x = y` (last read) | MOVE — assign + `wasMoved(y)` |
| `const x = y` (not last) | COPY — assign + `incref(x)` |
| `x = fresh()` | Destroy old, assign |
| `return expr` | Cleanup scopes (exclude returned vars), return |
| Scope exit | `=destroy` all tracked vars LIFO |
| `break`/`continue` | Set `needsTry` to loop boundary |
| Discarded `f()` | Capture in temp for cleanup |

**Status: Phase 4 COMPLETE.** 67 tests across 16 test groups. 870 total tests pass.

### 4b: Deferred Steps

| Step | When needed |
|------|-------------|
| ~~Range check injection~~ | ~~TypeAssertionData enhanced~~ — DONE (asType field added, rangeCheckInject complete) |
| Loc flag resolution | Codegen implementation |
| CFG-based isLastRead | Phase 2 upgrade for cross-block moves |

**Input:** Transformed AST + symbol table + type registry
**Output:** AST with injected cleanup calls (ms_decref, ms_incref, ms_was_moved, T_destroy, T_copy)

---

## Phase 5: Backend Codegen

Read-only AST traversal. Emit target language code. No new AST nodes created.

| Backend | Output | Notes |
|---------|--------|-------|
| **C** | `_common.h` + per-module `.c` files + `_sources.txt` | Uses analyzer results, type registry, lifecycle hooks. Multi-module or single-file mode. Feature flags for conditional linking (`needs_tls`, `needs_crypto`, etc.) |
| **JavaScript** | Single `.js` file | Respects DCE alive symbols for tree-shaking |
| **Erlang** | Single `.erl` file | Respects DCE alive symbols |
| **Raiser** | Bytecode `.msb` file | Serialized module for VM execution |

Write-if-changed pattern (`equalsFile`): preserves mtime when output unchanged for incremental builds.

**Input:** Final AST + all analysis results from previous phases
**Output:** Target language source files or bytecode

---

## Phase 6: Stats (optional)

Print compilation statistics: timing per phase, analyzer metrics (variables analyzed, RC ops generated, elision rate), module counts.

---

## Trans-Am: Incremental Computation Engine

Cross-cutting query cache that sits **outside** the pipeline, not between phases. Any phase's result can be a cached query. Salsa-inspired (rust-analyzer pattern).

```
                          Trans-Am Query Cache
                    +-------------------------------+
                    |  file_text ──> parse ──> ...  |
  setFileText() ──>|  Red-Green verification layer  |──> executeQuery()
                    |  LRU (user) + Permanent (std) |
                    +-------------------------------+

  Without Trans-Am:  edit file_A.ms → re-check ALL files
  With Trans-Am:     edit file_A.ms → re-check ONLY affected queries
```

**Core idea**: Cache query results with content hashes. On input change, mark queries RED. On access, verify lazily via `tryMarkGreen()` — if a dependency was recomputed but produced identical output (e.g. comment-only edit), dependents stay GREEN without recomputation.

| Concept | What it does |
|---------|-------------|
| **Red-Green algorithm** | 3-state verification (GREEN=valid, RED=stale, YELLOW=cycle detection) |
| **Output hash comparison** | Dependency recomputed but output unchanged → dependents stay GREEN |
| **Durability** | LOW (user src), MEDIUM (config), HIGH (std/ — skip verification) |
| **Dependency stack** | Auto-tracks which queries call which via push/pop frames |
| **Per-query LRU** | parse:128, symbols:512, type_check:2048 (right-sized, not one global cache) |

**Queries**: `file_text` (input) → `parse` → `symbols` → `type_check` → `transform` → `analyze` → `codegen`

**When it matters**: LSP (incremental re-check on keystroke), watch mode, large multi-module projects. Batch `msc build` benefits from skipping unchanged modules. Invisible to single-file `msc run`.

**Self-hosted design**: `src/transam/` — 11 files, ~940 lines Phase 1. Module-per-concern (not god struct). Array-indexed LRU (DRC-safe). Full design doc: `src/transam/CLAUDE.md`.

---

## Data Flow Summary

```
Phase 1:  file.ms -----> tokens -----> AST[] (per module)
Phase 2:  AST[] --------> typed AST[] + SymbolTable + TypeRegistry
Phase 3:  typed AST[] --> transformed AST[] + AliveSyms
Phase 4:  transformed --> AST with ms_decref/ms_incref injected  (C only)
Phase 5:  final AST ----> .c / .js / .erl / .msb files
Phase 6:  (stats)
```

---

## Module Dependency Architecture

Strict 6-layer DAG — each layer only depends downward, never upward.

```
Layer 0: FOUNDATION (zero cross-directory deps)
  lexer/  (token, scanner, lexer, state, chars)
  utils/  (string)
         │
         ▼
Layer 1: AST + DIAGNOSTICS (depend on lexer only)
  ast/         (node, printer)        ← imports lexer/token
  diagnostics/ (diagnostics)          ← imports lexer/token
         │
         ▼
Layer 2: PARSER (depends on ast, lexer, utils)
  parser/  (26 files)                 ← imports ast/node, lexer/*, utils/string
           callbacks.ms breaks expression ↔ statement circular dep
         │
         ▼
Layer 3: MODULE SYSTEM (depends on ast, parser, utils)
  module/  (graph, resolver, loader)  ← imports parser/validation, ast/node
           Loader parses source → extracts imports → builds graph
           ASTs discarded (DRC bug). Checker re-parses from source.
         │
         ▼
Layer 4: CHECKER (depends on ast, module, parser, utils)
  checker/ (11 files)                 ← imports ast/node, module/graph, utils/string
           3-pass per module: collect → resolve → check
           ExportRegistry propagates types between modules

           File ↔ Pass mapping:
           ┌─────────────────────┬──────────────────────────────────────┐
           │ File                │ Role                                 │
           ├─────────────────────┼──────────────────────────────────────┤
           │ types.ms            │ Foundation: TypeKind, Type, ctors    │
           │ symbol.ms           │ Foundation: SymbolTable, Scope chain │
           │ context.ms          │ Foundation: CheckerContext, registries│
           │ compat.ms           │ Foundation: isAssignable, overloads  │
           │ collectPass.ms      │ Pass 1: collect declarations        │
           │ resolvePass.ms      │ Pass 2: resolve type annotations    │
           │ checkPass.ms        │ Pass 3: statement validation        │
           │ checkExprPass.ms    │ Pass 3: expression type inference   │
           │ checkerCallbacks.ms │ Infra: circular dep break (3↔3)     │
           │ orchestrator.ms     │ Infra: multi-module coordination    │
           │ index.ms            │ Hub: re-exports public API          │
           └─────────────────────┴──────────────────────────────────────┘
         │
         ▼
Layer 5: TRANSFORMS (depends on ast, checker, utils)
  transform/ (28 files, 27+4 passes) ← imports ast/node, checker/{context,types,symbol}
           Each pass: (Node, TransformContext) → Node
           destructorLifting has deep checker access for RC type analysis
         │
         ▼
Layer 5b: ANALYZER (depends on ast, checker, transform)
  analyzer/ (6 files, ~900 lines)    ← imports ast/node, checker/{context,types,symbol}, transform/{context,util}
           DRC injection: classify → scope → inject → optimize
         │
         ▼
Layer 5c: TRANS-AM (cross-cutting, depends on ast, checker, module)
  transam/ (11 files, ~940 lines)    ← imports ast/node, checker/{context,types}, module/graph
           Incremental query cache: red-green verification, LRU, dependency tracking
           Wraps phases 1-5 as cached queries. Design doc: src/transam/CLAUDE.md
         │
         ▼
Layer 6: ENTRY POINT (orchestrates all phases)
  src/index.ms                        ← imports from ALL layers
           Pipeline: parse → check → transform → analyze → (codegen: future)
```

### Critical Hub Files (most depended-upon)

| File | Importers | Role |
|------|-----------|------|
| `ast/node.ms` | 27 | Universal data type (Node, NodeKind, 37 node kinds) |
| `transform/context.ms` | 23 | TransformContext shared by all 20+ passes |
| `transform/util.ms` | 20 | AST builder helpers (makeIdent, makeCall, etc.) |
| `lexer/token.ms` | 18 | Token + TokenKind (80+ kinds) |
| `parser/context.ms` | 18 | ParserState (peek, advance, expect) |
| `checker/types.ms` | 9 | Type + TypeKind (27 kinds) |
| `checker/symbol.ms` | 7 | SymbolTable, Scope chain |

### Design Patterns

1. **Strict layering** — no upward dependencies (transform never imports index.ms, checker never imports transform)
2. **Hub re-exports** — each directory has `index.ms` re-exporting public API
3. **Callback injection** — `parser/callbacks.ms` breaks expression ↔ statement cycle with function pointer registration
4. **Data-only crossing** — lower layers export pure data types; upper layers import types but don't call lower functions in production (only in tests)
5. **DRC firewall** — Module interface is primitive-only (strings, not Node), preventing DRC lifecycle mangling across module boundaries
6. **Deep import exception** — `destructorLifting.ms` reaches directly into `checker/{types,symbol}` for RC type introspection (Nim-aligned pattern)
