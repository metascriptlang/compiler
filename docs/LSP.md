# MetaScript LSP Roadmap: From Prototype to Production

This document outlines the strategy for evolving the MetaScript Language Server Protocol (LSP) implementation into a production-grade tool, leveraging the **Trans-Am** incremental query engine and aligning with the **Multi-Module Build Specification**.

## 1. Current Status (March 2026)

### LSP Module (`src/compiler/lsp/`)
- **Status**: Production-Ready Core, Cross-Module Aware.
- **Capabilities**: Semantic Tokens, Cross-module Hover/Definition, Zero-lag Completion, Transitive Diagnostics, Circular Dep Warnings, Doc Comment extraction, Request Queue with stdin drain + coalescing.
- **Architecture**: "Thin Server" adapter (~1600 lines). Intelligence lives in the compiler (`src/checker/suggest.ms`). Single-threaded with `select()`-based message draining.

### Trans-Am Engine (`src/compiler/transam/`)
- **Status**: Core Engine Complete (~3,300 lines across 11 modules). Durability + stdlib optimizations landed.
- **Capabilities**: Red-Green query invalidation, content-addressed hashing, dependency tracking, ExportRegistry integration, version-based cancellation, module dep graph with cycle detection, stdlib durability (G2-G5).

### Intelligence (`src/checker/suggest.ms`)
- **Status**: Production-Ready (~2500 lines).
- **Capabilities**: AST semantic analysis, relative delta semantic tokens, workspace-wide usage tracking, rich markdown hovers.

---

## 2. Reference-Inspired Architecture: Phase Mapping

MetaScript follows standard reference patterns where the compiler is the primary source of truth for the IDE.

| Phase | LSP Usage | Reference Pattern (`suggest.ms` equivalent) |
|-------|-----------|---------------------------|
| **1. Parse** | `findNodeAtPosition`, `collectSymbolsInFile` | `findNode`, `ideOutline` |
| **2. TypeCheck** | `sgGetSymbolAtCursor`, `sgTypeToString` | `symToSuggest`, `forth` |
| **3. Transform** | HCR Visibility, Move Semantics Hints | `ideExpand` (macro expansion) |
| **Trans-Am** | Incremental Invalidation | `ModuleGraph.markDirty` |

---

## 3. Production Roadmap

### Phase 1-3: Core Responsiveness (COMPLETE)
*   ~~[x] **Trans-Am Integration**: Swapped document store for incremental query engine.~~
*   ~~[x] **Cancellation**: Integrated `db.cancelCtx` to abort stale computations on keystroke.~~
*   ~~[x] **Completion Cache**: Zero-lag filtering for character-by-character typing.~~
*   ~~[x] **Request Queue + stdin Drain**: `select()`-based non-blocking stdin check drains all buffered messages before processing. Coalesces auto-fired requests (inlayHint, semanticTokens, documentHighlight) per file. Supersede detection skips requests invalidated by later `didChange`. `setvbuf(stdin, _IONBF)` ensures `select()` accuracy. Eager `dbTypeCheck` on `didOpen` warms cache so auto-fired requests return correct results immediately.~~

### Phase 4: Reliability & Standards (IN PROGRESS)
*   **Goal**: Full protocol alignment and workspace-wide coverage.
*   **Tasks**:
    - ~~[x] **Protocol Alignment**: Audit `SymbolKind` and `DiagnosticSeverity` against industry standards.~~
    - ~~[x] **Semantic Tokens**: Server-side highlighting for types vs variables.~~
    - [ ] **Global References**: Expand `textDocument/references` to use a background-indexed Trans-Am store instead of just open files.
    - [ ] **Safe Rename**: Project-wide rename validation using the global index.

### Phase 5: Multi-Module Fidelity (COMPLETE)
*   **Goal**: Eliminate `unknown` types on imports and enable member completion for external modules.
*   **Tasks**:
    - ~~[x] **Incremental Export Registry**: `ExportRegistry` on `TransAmDb`, lazily populated via `dbEnsureExportsRegistered`. Phase 1 (`collectTopLevelLocal`) runs on-demand for unregistered dependencies. Invalidated on file change + transitive dependents.~~
    - ~~[x] **Dependency-Aware Type Checking**: `dbTypeCheck` builds `ImportEntry[]` from AST + dep edges, creates synthetic `Module`/`ModuleGraph`, calls `checkProgramWithRegistryCancellable` with full cross-module visibility.~~
    - ~~[x] **Circular Dependency Warnings**: Native LSP diagnostics at import lines. `detectCycle` in moduleDeps.ms. `CircularDep` carries `importLine` + `importNames`.~~
    - [ ] **Project-Wide Indexing (Background)**: On startup, crawl the `loadOrder` (from the Pillar A build graph) to populate the Trans-Am cache with `dbGetExports` for the entire project. Blocked by G6 (async infrastructure).

### Phase 5.5: Incremental Performance (MOSTLY COMPLETE)
*   **Goal**: Close gaps found via audit against standard references and rust-analyzer (Salsa, DefMap, PrimeCaches).
*   **Audit date**: 2026-03-07. Compared against standard reference compilers and `~/projects/rust/src/tools/rust-analyzer/`.
*   **Tasks**:
    - [ ] **G1: Output-Hash Early Cutoff** — When parse output hash is unchanged after re-parse (e.g., comment-only edit), dependents stay GREEN. Implements the core Salsa "backdating" optimization. Requires `taHashNode` for AST content hashing + comparison in `tryMarkGreen`. *(High impact, Medium effort)*
    - ~~[x] **G2: Durability for Stdlib** — Mark std/ files as `TaDurability.High` via `dbSetStdPath` prefix matching. Skip `tryMarkGreen` recursive verification for High-durability entries (they never change during a session). HIGH durability skip still checks `computedAt` for safety. Standard reference: `belongsToStdlib`. rust-analyzer: 3-tier version vector skips sysroot.~~
    - ~~[x] **G3: Stdlib Export Freeze** — Skip re-registration in `dbInvalidateExports` for std/ paths (prefix-matched via `db.stdPath`). Once registered, std exports are immutable for the session.~~
    - ~~[x] **G4: Stale Edge Cleanup** — Verified `clearImportsFor` is called before `recordImportsForFile` re-records edges, preventing phantom dependencies from deleted imports.~~
    - ~~[x] **G5: Cancel in Export Registration** — `checkCancel` calls in `dbEnsureExportsRegistered` loop so long transitive dep walks don't block LSP responsiveness. Uses `startVersion` captured before the walk.~~
    - [ ] **G6: Background Cache Priming** — Pre-warm parse/exports/type-check for all project files during idle time (rust-analyzer: `parallel_prime_caches`). *(Medium impact, High effort — needs async infrastructure)*
    - [ ] **G7: Persistent Disk Cache** — Serialize Trans-Am cache to `.metascript-cache` for fast cold start (Standard reference cache). *(Low impact now, High effort)*
    - [ ] **G8: Per-Query LRU Tuning** — Profile and tune cache capacities per query type (parse:128, typecheck:2048, etc.). *(Low impact, Low effort — profile first)*
*   **Bugs fixed during implementation** (2026-03-07):
    - `recordDurability` was never called for Low-durability (user) files — frames stayed at High, causing user file queries to skip verification. Fixed: always call `recordDurability`.
    - `tryMarkGreen` HIGH durability skip bypassed `computedAt > entry.computedAt` recomputation check. Fixed: HIGH skip still checks `computedAt`.
    - `isStdPath` used substring match (`/std/` anywhere in path). Fixed: prefix match against `db.stdPath` set via `dbSetStdPath()`. Empty stdPath = no files get High durability (safe default).
*   **LSP wiring note**: `dbSetStdPath` is exported but not yet called from `server.ms`. When LSP gets `stdPath` config (via init params or env var), wire it to `dbSetStdPath(db, stdPath)` to enable stdlib durability optimization.

### Phase 6: Live-Coding & HCR Intelligence (The Pillar D Alignment)
*   **Goal**: Support the "Elite" tier features from `MULTI-MODULE.md`.
*   **Tasks**:
    - [ ] **@stable Contract Validation**: Real-time diagnostics if a user modifies a `@stable` class/interface in a way that violates Pillar D3 (e.g., field reordering).
    - [ ] **HCR Visibility**: Inlay Hints marking variables "LIFTED" to Global State Structs (Pillar D1) and Hover showing if a call is "INDIRECTED" via the Module VTable (Pillar D2).
    - [ ] **Safe-Point Diagnostics**: Warn if code inside a "Safe Point" (Pillar D4) performs operations that could block the HCR handover.

### Phase 7: Advanced IDE Experience (Parity with `typescript-go`)
*   **Goal**: Reach professional ergonomics and refactoring maturity.
*   **Tasks**:
    - [ ] **Global Auto-Imports**: Suggest symbols from un-imported modules with "Auto-import" Code Actions when no local matches are found.
    - [ ] **Smart Code Actions (Refactoring)**: "Implement Interface" stubs, "Exhaustiveness Fix" for enums, and "Extract to Variable/Function".
    - [ ] **Semantic Search**: `workspace/symbol` support searching all symbols in the project using the Trans-Am index.

### Phase 8: Hardening & Performance
*   **Goal**: 99.9th percentile reliability.
*   **Tasks**:
    - [ ] **Partial Check Recovery**: Ensure a type error in `module_a.ms` does not return `unknown` for symbols in `module_b.ms` using Trans-Am red-green isolation.
    - [ ] **Memory Cap**: Implement a memory-aware LRU for `TransAmDb` to prevent memory ballooning on massive projects.
    - [ ] **Stale-While-Revalidate**: Return the last known "Green" result from Trans-Am immediately while background re-computation runs.
    - [ ] **Cancellation Depth**: Propagate `checkCancel` into parser/checker/codegen inner loops (currently only at query boundaries). Single-threaded, so acceptable for now. rust-analyzer uses unwinding `salsa::Cancelled` for automatic propagation — not feasible without exception support.
    - [ ] **Transaction Semantics on Cancel**: If `dbEnsureExportsRegistered` is cancelled mid-loop, partial exports remain registered. Next query re-registers missing ones, but a brief window of inconsistency exists. Consider batch-commit pattern if this causes issues.
    - [ ] **Multi-Threaded LSP Server**: The current server is single-threaded with blocking I/O. Eager `dbTypeCheck` on `didOpen` blocks all request processing for 1-3s on cold files. The `select()`-based drain + coalesce mitigates this by batching requests, but true concurrent processing requires: (1) separate stdin reader thread (like nimsuggest's `replStdin` + Channel pattern), (2) request priority queue with preemption (user-initiated > auto-fired), (3) snapshot isolation for concurrent queries (rust-analyzer's `AnalysisHost` pattern), (4) mid-computation cancellation via `doStopCompile`-style voluntary abort (nimsuggest checks `requests.peek() > 0` during compilation). **Blocked by**: MetaScript threading/async primitives in the runtime. When available, this eliminates the ~1s didOpen freeze entirely — stdin reader thread feeds a channel, main thread processes with priority ordering and voluntary yield points in `dbTypeCheck`.

---

## 4. Implementation Priority for the Next Sprint

1. ~~**P0: Bridge dbTypeCheck to the ExportRegistry** so imports actually resolve.~~ DONE
2. ~~**P0: G2+G3+G4+G5** — Stdlib durability, export freeze, stale edge cleanup, cancel in export reg.~~ DONE
3. **P1: G1** — Output-hash early cutoff (the Salsa signature optimization).
4. **P1: Wire `dbSetStdPath` in LSP** — Pass `stdPath` from init config to `dbSetStdPath(db, path)` to activate stdlib durability.
5. **P1: Add @stable validation** to support the HCR development workflow.
6. **P2: Implement "Auto-Import" completions** to match the TypeScript developer experience.

---

## 5. Technical Comparison

| Feature | typescript-go | Reference | rust-analyzer | MetaScript |
|---------|---------------|------------------|---------------|------------|
| **Core Engine** | V8 + Manual Cache | ModuleGraph + cached artifacts | Salsa (Red-Green) | Trans-Am (Red-Green) |
| **Logic** | Heavy Server | Compiler-as-IDE | Compiler-as-IDE | Thin Adapter + Smart Compiler |
| **Multi-Module** | Full Symbol Index | markDirty + markClientsDirty | DefMap + Durability | ExportRegistry + BFS invalidation |
| **Dirty Propagation** | File watcher | dirty flags + transitive closure | Salsa version vectors | RED marking + getTransitiveDependents |
| **Stdlib Caching** | Bundled .d.ts | Aggressive caching | Durable tier (skip validation) | TaDurability.High + prefix match |
| **Early Cutoff** | N/A | N/A | Output hash backdating | Stubbed (G1) |
| **Request Queue** | Async event loop | Channel + tryRecv | crossbeam channel | `select()` drain + coalesce |
| **Cancellation** | Async/Promise | doStopCompile hook | salsa::Cancelled (unwinding) | Version-based checkCancel (loop boundary) |
| **Circular Deps** | Error | recursiveDep warning | DefMap handles | detectCycle + LSP Warning |
| **Live Coding** | N/A | N/A | N/A | HCR Contract Validation |
| **Stdlib Detection** | Package manifest | Package-ID based | SourceRoot kind | Path prefix (`db.stdPath`) |

## 6. Reference: Standard Implementation/rust-analyzer Audit (2026-03-07)

### Standard Key Patterns
- **markDirty + markClientsDirty**: Sets dirty flag on module, clears suggested symbols/errors, cascades via transitive closure of dependencies.
- **Artifact caching**: Serialized AST/metadata. Stdlib aggressively cached, never re-checked unless manifest changes.
- **Circular imports**: Detected via importStack. Self-import is an error; circular import is allowed.
- **Cancellation**: Cancellation hooks exist but are not always implemented for all IDE commands.
- **IDE commands**: Enum covering suggestions, definitions, usage tracking, highlighting, outlining, inlay hints, etc.
- **belongsToStdlib**: Uses package-ID comparison or path matching for robust stdlib detection.

### rust-analyzer Key Patterns (~/projects/rust/src/tools/rust-analyzer/)
- **Salsa red-green**: Query dependencies tracked automatically. On re-request, validate each dependency's revision. GREEN = return cached. RED = recompute.
- **Early cutoff (backdating)**: If re-executed query produces same output hash, it's "backdated" — blocks cascading to all transitive dependents. Comment-only edits: parse re-runs, AST unchanged, type-check stays cached. **This is our G1 — highest-impact remaining optimization.**
- **3-tier durability**: Volatile (open files), Normal (project code), Durable (external crates/sysroot). Version vector `[volatile, normal, durable]` — editing user file only bumps volatile counter, skips all durable query verification.
- **DefMap**: Per-module name resolution (`hir_def/nameres`). Incrementally rebuilt. Import changes invalidate dependents; no-change early-cuts.
- **Cancellation**: `salsa::Cancelled` propagated via `check_canceled()` in long loops. Partial results discarded; next request starts fresh. Uses unwinding (Rust panics) for automatic propagation — not feasible in MetaScript without exception support. Our loop-boundary `checkCancel` is acceptable for single-threaded operation.
- **PrimeCaches**: Background thread pre-warm parse/DefMap/inference for all open/recent files during idle. Parallel execution. **This is our G6.**
- **No disk cache**: Intentionally skipped — forces optimization of initial analysis speed.
- **Snapshot isolation**: `apply_change()` on `AnalysisHost` cancels all in-flight `Analysis` queries. Each snapshot is a clone. Not needed for single-threaded MetaScript, but relevant if we add async LSP.
