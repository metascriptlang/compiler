# MetaScript LSP Roadmap: From Prototype to Production

This document outlines the strategy for evolving the MetaScript Language Server Protocol (LSP) implementation into a production-grade tool, leveraging the **Trans-Am** incremental query engine.

## 1. Current Status (March 2026)

### LSP Module (`src/compiler/lsp/`)
- **Status**: Production-Grade Engine (Phase 4 Complete).
- **Capabilities**: Semantic Tokens, Workspace-wide References/Rename, Cross-module Hover/Definition, Zero-lag Completion, Transitive Diagnostics, Doc Comment extraction.
- **Architecture**: "Thin Server" adapter (~1200 lines). Intelligence lives in the compiler (`src/checker/suggest.ms`). Integrated with **Trans-Am** for O(changed) performance.
- **Performance**: < 1ms for cached completions, < 10ms for workspace-wide reference indexing on typical projects.

### Trans-Am Engine (`src/compiler/transam/`)
- **Status**: Core Engine Complete (~940 lines).
- **Capabilities**: Red-Green query invalidation, content-addressed hashing (Salsa-inspired), LRU caching, dependency tracking.

### Intelligence (`src/checker/suggest.ms`)
- **Status**: Production-Ready (~2500 lines).
- **Capabilities**: Full AST semantic analysis, relative delta semantic tokens, workspace-wide usage tracking, rich markdown hovers.

---

## 2. Nim-Inspired Architecture: Phase Mapping

MetaScript follows Nim's pattern where the compiler is the primary source of truth for the IDE. We leverage information from each phase in `docs/PINELINE.md` to feed the LSP:

| Phase | LSP Usage | Nim Pattern (`suggest.nim`) |
|-------|-----------|---------------------------|
| **1. Parse** | `findNodeAtPosition`, `collectSymbolsInFile` | `findNode`, `ideOutline` |
| **2. TypeCheck** | `sgGetSymbolAtCursor`, `sgTypeToString` | `symToSuggest`, `forth` (type string) |
| **3. Transform** | Error mapping (if transforms fail) | `ideExpand` (macro expansion check) |
| **Trans-Am** | `markDirty`, `markClientsDirty`, `tryMarkGreen` | `ModuleGraph.markDirty` + Red-Green |

---

## 3. The Bridge: Trans-Am Integration

The primary goal is to replace `LspDocumentStore` with `TransAmDb`. This transforms the LSP from O(N) to O(changed).

### Implementation Strategy

1.  **Shared State**: Update `LspServerState` to hold `TransAmDb`. (DONE)
2.  **Input Synchronization**:
    - `textDocument/didChange` → `dbSetFileText(db, path, content)`. (DONE)
    - Trans-Am automatically increments the revision and invalidates dependent queries. (DONE)
3.  **Query Execution**:
    - Handlers use `dbParse` and `dbTypeCheck` queries. (DONE)
    - **Smart Ranking**: Steal Nim's `cmpSuggestions` ranking logic (Prefix > ContextFit > ScopeDepth > Quality). (DONE)

---

## 4. Production Roadmap

### Phase 1: Performance Parity (COMPLETE)
*   **Goal**: Match `typescript-go` responsiveness via Trans-Am.
*   **Tasks**:
    - [x] **DB Integration**: Swap document store for `TransAmDb` in `server.ms`.
    - [x] **Query Refactor**: Update all handlers to use `dbParse` and `dbTypeCheck`.
    - [x] **Smart Ranking**: Implement Nim-style multi-tier sorting in `sgGetCompletionCandidates`.
    - [x] **Token Accuracy**: Basic `getTokenLen` logic for definition/rename.

### Phase 2: Multi-Module & Workspace Intelligence (COMPLETE)
*   **Goal**: Full intelligence across project boundaries.
*   **Tasks**:
    - [x] **Cross-module Definition**: Leverage `ExportRegistry` via Trans-Am for cross-file navigation.
    - [x] **Incremental Diagnostics**: Implement `ideChk` (on-type diagnostics) that only re-checks affected modules using Trans-Am's `getTransitiveDependents`.
    - [x] **Doc Extraction**: Implement `extractDocComment` to pull markdown from AST nodes (matching Nim's recursive search).

### Phase 3: UX & Responsiveness (COMPLETE)
*   **Goal**: Non-blocking, smooth developer experience.
*   **Tasks**:
    - [x] **Cancellation**: Integrate `db.cancelCtx` to abort stale computations. Requires injecting `checkCancel` in checker hot loops.
    - [x] **Completion Session Cache**: Cache last completion result. If cursor is on same line and prefix matches, return cached results instantly.
    - [x] **Exception Hints**: Add `sgCollectExceptionHints` to show inferred propagated exceptions (Nim-parity).

### Phase 4: Reliability & Standards (COMPLETE)
*   **Goal**: Advanced features and protocol strictness from `vendor/typescript-go`.
*   **Tasks**:
    - [x] **Protocol Alignment**: Audit all JSON-RPC responses against `lsproto/lsp_generated.go`. Ensure `SymbolKind`, `CompletionItemKind`, and `DiagnosticSeverity` mappings are 1:1 with TypeScript-Go standards.
    - [x] **Semantic Tokens**: Server-side highlighting (distinguishing types, variables, and properties).
    - [x] **References/Rename**: Fast "Find Usages" across the entire workspace via Trans-Am iteration.
    - [x] **Markdown Polish**: Enhance `sgFormatHover` with rich markdown formatting (interface fields, enum members, bold badges).

### Phase 5: Parallel & Concurrent Evolution (FUTURE)
*   **Goal**: True background processing and zero-latency UI interaction.
*   **Note**: This phase is deferred until MetaScript supports native concurrency/parallelism.
*   **Potential Tasks**:
    - [ ] **Background Indexing**: Continuous background type-checking of the entire workspace on separate threads.
    - [ ] **Stale-While-Revalidate**: Return slightly stale results instantly while re-calculating on a worker thread.
    - [ ] **Thread-Safe Trans-Am**: Migrate Trans-Am query cache to a thread-safe, concurrent storage model.

---

## 5. Technical Comparison

| Feature | typescript-go | MetaScript (Nim-Style) |
|---------|---------------|-------------------------|
| **Core Engine** | V8 + Manual Cache | Trans-Am (Red-Green) |
| **Logic** | Heavy Server | Thin Adapter + Smart Compiler |
| **Invalidation** | Manual/Granular | Automatic BFS on Importers |
| **Ranking** | fit-based | prefix > context > scope > usage |

## 6. Implementation Guide: Trans-Am Queries for LSP

```ms
// Hover query — Lightning fast because parse/check are cached
export function handleHover(id: string, params: string, db: TransAmDb): string {
    const pos = lspExtractPosition(params);
    const path = lspUriToPath(pos.uri);
    
    checkCancel(db); // Abort if stale
    
    // Trans-Am handles the heavy lifting of determining what needs re-computation
    const program = dbParse(db, path);
    const ctx = dbTypeCheck(db, path);
    
    const suggest = sgGetSymbolAtCursor(ctx, program, pos.line, pos.col);
    if (suggest === null) return lspResponse(id, "null");

    return lspResponse(id, lspFmtHoverResult(sgFormatHover(suggest), sgFormatHoverDoc(suggest)));
}
```
