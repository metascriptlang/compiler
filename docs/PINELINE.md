# Compilation Pipeline

6 phases from `compile.zig:295`. Phases 1-2 = frontend (shared with LSP). Phases 3-5 = backend (compilation only).

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer DRC] --> [5 Codegen] --> output
```

---

## Phase 1: Parse + Module Loading (src/parser,lexer,ast)

Lex source into tokens, parse tokens into AST, recursively load all imported modules.

| Step | What it does |
|------|-------------|
| Tokenize | Source text to token stream |
| Parse | Token stream to AST (recursive descent + Pratt) |
| Module load | Resolve imports, load dependencies, load std macros |

**Input:** `.ms` source file path
**Output:** Typed AST per module, module dependency graph

---

## Phase 2: Macro Expansion + Type Checking (src/checker)

Expand macros first (Hermes VM), then run 3-pass type checking.

                           ast/node.ms
                          (Node, NodeKind)
                               │
                ┌──────────────┼──────────────┐
                ▼              ▼              ▼
           types.ms       symbol.ms      context.ms
                │              │              │
                └──────┬───────┴──────┬───────┘
                       ▼              ▼
                collectPass.ms  resolvePass.ms
                       │              │
                       └──────┬───────┘
                              ▼
                        checkPass.ms ◄── compat.ms
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
| **2. Resolve** | Resolve type references, propagate import/export types cross-module | `propagateExports` + `TypeResolver.resolve()` | `resolveDeclarations()` (single-module done, cross-module TODO) |
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

Self-hosted status: All 3 passes implemented for single-module. Pass 2 cross-module
type propagation (import/export type flow) deferred until multi-module pipeline lands.

Trans-Am (Salsa-inspired incremental engine) is fully compatible with 3-pass.
The LSP uses single `checkFile()` queries -- Trans-Am's red-green algorithm,
macro firewall, and demand-driven queries work regardless of how many internal
passes the checker uses.

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

## Phase 3: Transforms + Normalization

Multiple sub-transforms that rewrite the typed AST before codegen.

| Step | What it does |
|------|-------------|
| 3a Transform pipeline | Run builtin + config transforms (type coercion, optional chain, nullish coalesce, result desugar, spread expand, for-of lowering) |
| 3b Normalization | Extension methods via UFCS (`arr.map(f)` to `Array_map(arr, f)`), object spread, closure inlining, lambda lifting (closures to env struct + function pointer) |
| 3c Lowering | Constant folding, defer to try/finally, match expression to switch/if chains |
| 3d DCE | Dead code elimination -- walk AST, mark alive symbols, codegen skips dead code |

**Input:** Typed AST + symbol table
**Output:** Transformed AST + alive symbol set

---

## Phase 4: DRC Analysis + Injection (C backend only)

Deterministic Reference Counting -- Lobster-style memory management. Most complex phase.

| Step | What it does |
|------|-------------|
| 4.1 String concat flatten | `a + b + c` chains to `string_assign_expr` / `string_append_expr` (DRC needs these forms) |
| 4.2 DRC analysis | Collect interface names (value types, no RC). Run `DrcAnalyzer` on all modules: compute variable lifetimes (`borrow`/`keep`/`any`), decide RC operations, detect move opportunities via CFG last-use analysis |
| 4.3 Range check injection | Insert `ms_chck_range()` for narrowing type assertions (e.g. `x as int8`) |
| 4.4 DRC injection | Physically insert `ms_decref()` / `ms_incref()` / `ms_was_moved()` into AST at scope exits, assignments, returns (`injectdestructors`) |
| 4.4b Pointer param transform | Set `loc_flags.indirect` on pointer parameters for C calling convention |
| 4.5 Loc flag resolution | Pre-resolve all location flags for codegen (no runtime HashMap lookups) |

**Key concepts:**
- **Lifetime** (Lobster-style): `borrow` (don't hold ref), `keep` (you own it), `any` (non-ref type)
- **Move optimization**: Elide RC ops on last use (`isLastUseCfg` with control flow graph)
- **Cycle detection**: Bacon-Rajan algorithm for deferred collection of cycle candidates

**Input:** Transformed AST + symbol table + type registry
**Output:** AST with injected cleanup calls, RC operation array, location flags

---

## Phase 5: Backend Codegen

Read-only AST traversal. Emit target language code. No new AST nodes created.

| Backend | Output | Notes |
|---------|--------|-------|
| **C** | `_common.h` + per-module `.c` files + `_sources.txt` | Uses DRC results, type registry, lifecycle hooks. Multi-module or single-file mode. Feature flags for conditional linking (`needs_tls`, `needs_crypto`, etc.) |
| **JavaScript** | Single `.js` file | Respects DCE alive symbols for tree-shaking |
| **Erlang** | Single `.erl` file | Respects DCE alive symbols |
| **Raiser** | Bytecode `.msb` file | Serialized module for VM execution |

Write-if-changed pattern (`equalsFile`): preserves mtime when output unchanged for incremental builds.

**Input:** Final AST + all analysis results from previous phases
**Output:** Target language source files or bytecode

---

## Phase 6: Stats (optional)

Print compilation statistics: timing per phase, DRC metrics (variables analyzed, RC ops generated, elision rate), module counts.

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
