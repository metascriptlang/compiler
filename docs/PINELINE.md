# Compilation Pipeline

6 phases from `compile.zig:295`. Phases 1-2 = frontend (shared with LSP). Phases 3-5 = backend (compilation only).

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 DRC] --> [5 Codegen] --> output
```

---

## Phase 1: Parse + Module Loading

Lex source into tokens, parse tokens into AST, recursively load all imported modules.

| Step | What it does |
|------|-------------|
| Tokenize | Source text to token stream |
| Parse | Token stream to AST (recursive descent + Pratt) |
| Module load | Resolve imports, load dependencies, load std macros |

**Input:** `.ms` source file path
**Output:** Typed AST per module, module dependency graph

---

## Phase 2: Macro Expansion + Type Checking

Expand macros first (Hermes VM), then run 3-pass type checking (Nim-aligned).

### 2a: Macro Expansion

Hermes VM evaluates `@derive`, `@comptime`, custom `macro!()` invocations. Replaces `macro_invocation` nodes with generated AST subtrees.

### 2b: Type Checking (3-pass + discriminant)

| Pass | Purpose |
|------|---------|
| Pass 0 | **Canonicalize** -- assign stable `MsAnon*` names to anonymous types |
| Pass 1 | **Collect declarations** -- populate symbol table (functions, classes, types, imports) across all modules |
| Pass 2 | **Propagate exports** -- cross-module type flow: export types backfill into import symbols |
| Pass 2.5 | **Discriminant analysis** -- detect property-based and type-based discriminants for unions (needed for lifecycle hooks) |
| Pass 3 | **Infer + check** -- full type resolution/inference, fill `.type` on every AST node, report errors |

### 2c: Type Registration

Pre-compute all struct/array/tuple/Result type definitions into a `TypeRegistry` for fast codegen lookup. Eliminates runtime HashMap queries (Nim's `finishTypeDescriptions` pattern).

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

Deterministic Reference Counting -- Nim/Lobster-style memory management. Most complex phase.

| Step | What it does |
|------|-------------|
| 4.1 String concat flatten | `a + b + c` chains to `string_assign_expr` / `string_append_expr` (DRC needs these forms) |
| 4.2 DRC analysis | Collect interface names (value types, no RC). Run `DrcAnalyzer` on all modules: compute variable lifetimes (`borrow`/`keep`/`any`), decide RC operations, detect move opportunities via CFG last-use analysis |
| 4.3 Range check injection | Insert `ms_chck_range()` for narrowing type assertions (e.g. `x as int8`) |
| 4.4 DRC injection | Physically insert `ms_decref()` / `ms_incref()` / `ms_was_moved()` into AST at scope exits, assignments, returns (Nim's `injectdestructors.nim` pattern) |
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

Write-if-changed pattern (Nim's `equalsFile`): preserves mtime when output unchanged for incremental builds.

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
