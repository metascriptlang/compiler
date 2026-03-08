# Trans-Am: Incremental Computation Engine

Self-hosted incremental query engine for the MetaScript compiler. Inspired by Salsa/rust-analyzer (`~/projects/rust/src/tools/rust-analyzer/`). Powers LSP responsiveness and incremental compilation.

## 1. Executive Summary

Trans-Am is a **demand-driven incremental computation framework** that caches compilation results (parse trees, symbol tables, type check results) and efficiently invalidates/recomputes only what changed.

**Why it exists:**
- **LSP latency**: Re-parsing/re-checking entire projects on every keystroke is too slow. Trans-Am makes per-file edits O(changed) instead of O(project).
- **Batch compilation**: Even batch builds benefit -- unchanged modules skip all phases.
- **Correctness**: The red-green algorithm guarantees results are always consistent with current file contents.

**Core insight** (the "Salsa optimization"): When a dependency is recomputed, don't immediately invalidate all dependents. Instead, check if the dependency's **output actually changed** (content-addressed hash). If a comment-only edit produces identical parse output, all downstream queries stay GREEN.

## 2. Architecture Overview

```
                    +-------------------------------------------------+
                    |              Trans-Am Database                   |
                    |                                                 |
  LSP/CLI -------->|  +----------+    +----------+                   |
  setFileText()    |  |  Input   |--->| Red-Green |                  |
  executeQuery()   |  |  Layer   |    |  Engine   |                  |
                    |  +----------+    +-----+----+                   |
                    |       |              |                          |
                    |       v              v                          |
                    |  +----------+  +----------+  +----------+      |
                    |  |  File    |  |  Query   |  |  Module  |      |
                    |  |  Hashes  |  |  Cache   |  |  Deps    |      |
                    |  +----------+  +----------+  +----------+      |
                    |                     |                           |
                    |              +------+------+                    |
                    |              v             v                    |
                    |         +--------+   +---------+               |
                    |         |  LRU   |   |Permanent|               |
                    |         | (user) |   | (stdlib)|               |
                    |         +--------+   +---------+               |
                    +-------------------------------------------------+

  Query DAG:
  +----------+     +----------+     +----------+     +----------+
  |file_text |---->|  parse   |---->| symbols  |---->|type_check|
  | (input)  |     | (cached) |     | (cached) |     | (cached) |
  +----------+     +----------+     +----------+     +----------+
                        |                |                |
                        +--- Dependencies auto-tracked ---+
```

## 3. Core Algorithm: Red-Green

Three states per cached query:

| State | Meaning | Action |
|-------|---------|--------|
| GREEN | Verified current this revision | Return cached value |
| RED | Potentially stale | Needs verification or recomputation |
| YELLOW | Currently being verified | Cycle detection -- return fallback |

### tryMarkGreen (ref: `red_green.zig:38-130`)

```ms
function tryMarkGreen(db: TransAmDb, key: QueryKey): boolean {
    const entry = lookupCache(db, key);
    if (entry === null) return false;

    // Fast path: already verified this revision
    if (entry.verifiedAt === db.revision.value) {
        return entry.state === QueryState.Green;
    }

    // Cycle detection
    if (entry.state === QueryState.Yellow) return false;
    entry.state = QueryState.Yellow;

    // Check each dependency
    let i = 0;
    while (i < entry.dependencies.items.length) {
        const dep = entry.dependencies.items[i];

        if (dep.key.queryKind === QueryKind.FileText) {
            // Input query: compare content hash directly
            const currentHash = getFileHash(db, dep.key.inputHash);
            if (currentHash !== dep.expectedOutputHash) {
                entry.state = QueryState.Red;
                return false;
            }
            i = i + 1;
            continue;
        }

        // HIGH durability: skip verification (stdlib assumed stable)
        const depEntry = lookupCache(db, dep.key);
        if (depEntry !== null) {
            if (depEntry.durability === Durability.High) {
                i = i + 1;
                continue;
            }
        }

        // Recursively verify dependency
        if (!tryMarkGreen(db, dep.key)) {
            entry.state = QueryState.Red;
            return false;
        }

        // KEY SALSA INSIGHT: dependency recomputed but output unchanged?
        if (depEntry !== null) {
            if (depEntry.computedAt > entry.computedAt) {
                if (depEntry.outputHash !== dep.expectedOutputHash) {
                    entry.state = QueryState.Red;
                    return false;  // semantic change
                }
                // Output unchanged -- comment edit, whitespace, etc.
            }
        }

        i = i + 1;
    }

    // All deps verified
    entry.verifiedAt = db.revision.value;
    entry.state = QueryState.Green;
    return true;
}
```

### executeQuery

```ms
function executeQuery(db: TransAmDb, key: QueryKey): QueryValue {
    // 1. Try cache
    if (tryMarkGreen(db, key)) {
        return getCachedValue(db, key);
    }

    // 2. Push dependency frame (automatic tracking begins)
    pushFrame(db.depStack, key);

    // 3. Execute query function (sub-queries auto-recorded in frame)
    const result = dispatchQuery(db, key);

    // 4. Pop frame, collect dependencies
    const frame = popFrame(db.depStack);

    // 5. Content-address the output
    const outputHash = hashQueryResult(result);

    // 6. Store with dependencies
    storeQueryResult(db, key, result, outputHash, frame.deps, frame.minDurability);
    return result;
}
```

## 4. Query Types

Query types for the self-hosted compiler's incremental pipeline.

### Active Queries

| Query | Kind | Input | Output | LRU | Notes |
|-------|------|-------|--------|-----|-------|
| `file_text` | Input | file path | source string | n/a | Set by LSP/CLI, never cached |
| `file_hash` | Input | file path | content hash | n/a | Computed on setFileText |
| `parse` | Derived | file_text | Node (program) | 128 | Re-parsing is fast, small cache |
| `symbols` | Derived | parse | SymbolTable | 512 | 3-pass collect+resolve |
| `type_check` | Derived | symbols + imports | CheckerContext | 2048 | Most expensive, large cache |
| `transform` | Derived | type_check | Node (transformed) | 256 | 27 transform passes |
| `analyze` | Derived | transform + type_check | Node (DRC-injected) | 256 | C backend only |
| `module_deps` | Derived | parse | ImportEntry[] | 512 | Extract import declarations |

### Transparent Queries (never cached)

- `file_exists` -- checks SourceProvider, trivial
- `resolve_import` -- specifier to path, pure function

### Deferred Queries (Phase 3+)

- `codegen` -- C/JS output
- `diagnostics` -- aggregated errors
- `completions` -- stale-while-revalidate (LSP)

## 5. Data Structures

All containers wrapped in interfaces (DRC value-type workaround). Follows `src/analyzer/scope.ms` patterns.

### Core Types

```ms
interface Revision {
    value: number;
}

export enum QueryKind {
    FileText, FileHash, Parse, Symbols,
    TypeCheck, Transform, Analyze, ModuleDeps,
}

export enum QueryState {
    Green, Red, Yellow,
}

export enum Durability {
    Low,     // user src/*.ms
    Medium,  // config files
    High,    // std/, node_modules/
}

interface QueryKey {
    queryKind: QueryKind;
    inputHash: number;
}

interface DependencyWithHash {
    key: QueryKey;
    expectedOutputHash: number;
}

interface DependencyList {
    items: DependencyWithHash[];
}

interface QueryValue {
    outputHash: number;
    state: QueryState;
    computedAt: number;
    verifiedAt: number;
    dependencies: DependencyList;
    durability: Durability;
}
```

### Dependency Stack

```ms
interface DependencyFrame {
    queryKey: QueryKey;
    deps: DependencyList;
    minDurability: Durability;
}

interface FrameStack {
    items: DependencyFrame[];
}

interface DependencyStack {
    frames: FrameStack;
}
```

### LRU Cache (Array-Indexed)

```ms
// Array-indexed doubly-linked list -- NOT pointer-based.
// DRC cannot safely manage arbitrary graph pointers.
// Reference uses *Node prev/next (cache.zig:17-163).
// We use index-based: each node stores indices into parallel arrays.

interface LruNode {
    key: number;
    prev: number;    // index, -1 = none
    next: number;    // index, -1 = none
    occupied: boolean;
}

interface LruNodeList {
    items: LruNode[];
}

interface LruCache {
    nodes: LruNodeList;
    head: number;      // MRU index
    tail: number;      // LRU index
    count: number;
    capacity: number;
}
```

### TransAmDb (Thin Facade)

```ms
// All fields are interface-typed (pointer in C). No raw arrays.
interface TransAmDb {
    revision: Revision;
    fileInput: FileInputStore;
    depStack: DependencyStack;
    queryCache: LruCache;          // LOW/MEDIUM durability
    permanentCache: CacheStore;    // HIGH durability, never evicted
    moduleDeps: ModuleDepGraph;
    interner: StringInterner;
    cancelVersion: number;
}
```

## 6. Module Design

Module-per-concern, NOT a god struct. Reference `TransAmDatabase` has 40+ fields in one struct (`transam.zig:186-309`). We split into focused files following the `src/analyzer/` pattern.

```
src/transam/
  revision.ms       ~80 lines   Revision, QueryState, Durability, QueryKind, QueryKey
  query.ms          ~120 lines  QueryValue, DependencyWithHash, DependencyFrame, DependencyStack
  cache.ms          ~200 lines  LruCache (array-indexed), get/put/evict
  red_green.ms      ~180 lines  tryMarkGreen, executeQuery, storeQueryResult
  file_input.ms     ~80 lines   FileInputStore, setFileText, getFileText, getFileHash
  module_deps.ms    ~120 lines  recordModuleImport, getImporters, invalidateDependents (BFS)
  hash.ms           ~60 lines   hashString, hashNode (content-addressed AST hashing)
  intern.ms         ~80 lines   StringInterner (symbol name deduplication)
  cancel.ms         ~60 lines   getCancelVersion, checkCancel (version-based)
  index.ms          ~100 lines  TransAmDb constructor, hub re-exports, integration tests
  queries/
    parse_query.ms   ~80 lines  parse query implementation
    symbols_query.ms ~100 lines symbol table query
    check_query.ms   ~120 lines type check query
```

### Why NOT God Struct

| Aspect | Reference (God Struct) | Self-Hosted (Module-per-Concern) |
|--------|----------------------|--------------------------------|
| File size | `transam.zig`: 800+ lines just for fields | ~80-200 lines per file |
| DRC safety | N/A (Zig manual memory) | Arrays passed by pointer; bare `T[]` types (wrappers removed) |
| Circular imports | One file, no problem | Hub re-exports, callback injection |
| Testing | Hard to isolate | Each module has inline tests |
| Compilation | Recompiles everything | Smaller files = faster incremental |

## 7. Integration Points

### How Queries Map to Existing Modules

| Query | Existing Module | Function Called |
|-------|----------------|----------------|
| `parse` | `src/parser/statements/validation.ms` | `parseSource(input)` |
| `symbols` | `src/checker/collectPass.ms + resolvePass.ms` | `collectTopLevel()`, `resolveDeclarations()` |
| `type_check` | `src/checker/checkPass.ms` | `checkProgramBody()` |
| `transform` | `src/transform/index.ms` | `transformProgram(program, checkerCtx)` |
| `analyze` | `src/analyzer/index.ms` | `analyzeProgram(transformed, checkerCtx)` |
| `module_deps` | `src/module/loader.ms` | Extract import declarations from parsed AST |

### Batch vs LSP Mode

```ms
// Batch build: full pipeline, no cancellation
function compileBatch(db: TransAmDb, entryPath: string): Node {
    return executeQuery(db, makeKey(QueryKind.Analyze, entryPath));
}

// LSP: on-demand queries with cancellation
function handleHover(db: TransAmDb, filePath: string, pos: number): string {
    checkCancel(db);
    const symbols = executeQuery(db, makeKey(QueryKind.Symbols, filePath));
    return lookupSymbolAtPosition(symbols, pos);
}
```

### Cross-Module Integration

Existing `ModuleGraph` (`src/module/graph.ms`) tracks static structure. Trans-Am's `module_deps.ms` tracks **runtime dependency edges** for incremental invalidation.

When `setFileText(path, newSource)` is called:
1. Compute `file_hash(path)` -- content changed?
2. If unchanged (same hash), return false -- no work needed
3. If changed: increment revision, mark all cached queries RED
4. `invalidateDependents(path)` -- BFS through module importer graph
5. Next query access triggers lazy `tryMarkGreen` verification

## 8. What We Keep from Reference

| Pattern | Ref File | Why Keep |
|---------|----------|----------|
| Red-green algorithm | `red_green.zig:38-130` | Core correctness -- Salsa-proven |
| Content-addressed output hashing | `red_green.zig:105-123` | Avoids recomputation on semantic-preserving changes |
| Durability levels (LOW/MEDIUM/HIGH) | `types.zig:68-104` | Skip verification for stdlib (5-10% speedup) |
| BFS transitive invalidation | `module_graph.zig:119-158` | Correct dependency propagation with cycle safety |
| DependencyStack push/pop frames | `types.zig:150-202` | Clean automatic dependency tracking |
| Separate LRU + permanent cache | `transam.zig:200-203` | Stdlib entries never evicted |
| StringInterner deduplication | `intern.zig:12-58` | Reduces string allocation pressure |
| Version-based cancellation | `cancellation.zig:44-68` | Responsive LSP without boolean flag races |

## 9. What We Improve Over Reference

| Improvement | Reference | Ours | Rationale |
|------------|-----------|------|-----------|
| Module-per-concern | God struct (40+ fields) | 11 focused files | DRC safety, testability |
| Array-indexed LRU | Pointer-based linked list (`cache.zig:17`) | Index-based | DRC can't track graph pointers |
| Automatic dep tracking | Manual `recordDependency()` calls | Frame-based push/pop scope | Impossible to forget |
| Per-query LRU sizing | Single 10k cache | parse:128, symbols:512, type_check:2048 | Right-sized, less eviction churn |
| Cycle recovery | Error return | Return `unknownType()` / empty results | Graceful degradation (Salsa pattern, `hir-ty/src/infer.rs`) |
| Interface-wrapped containers | Raw arrays/slices | All `Foo[]` in `interface FooList` | DRC value-type workaround |
| Typed query results | `*anyopaque` + `type_id: u64` | Per-QueryKind result interfaces | Type safety, no runtime checks |
| Transparent queries | All queries cached | Trivial derivations skip cache | Less memory, less eviction |

### Typed Query Results (No anyopaque)

```ms
interface ParseResult {
    program: Node;
}

interface SymbolsResult {
    table: SymbolTable;
    exports: ExportedSymInfoList;
}

interface CheckResult {
    checkerCtx: CheckerContext;
}
```

## 10. What We Skip

| Feature | Ref File | Why Skip |
|---------|----------|----------|
| Disk cache (`.metascript-cache`) | `disk_cache.zig` | Batch doesn't need persistence. Add for LSP startup. |
| Network cache | `network_cache.zig` | No `@comptime fetch()` in self-hosted yet |
| Generic instance cache | `generic_cache.zig` | Generics not monomorphized yet. Add with codegen. |
| Parallel/async expansion | `cancellation.zig` (atomics) | MetaScript is single-threaded |
| Macro queries (3 types) | `macro_queries.zig` | No macro system in self-hosted yet |
| Syntax/semantic highlighting | `highlight.zig` | LSP-only, not needed for compiler |
| Completion cache | `completion.zig` | LSP Phase 3+ |
| Format cache | `format.zig` | Formatter not implemented |
| Operator index | `transam.zig:300-302` | Custom operators not in self-hosted |
| AST arena management | `transam.zig:277-281` | Self-hosted uses DRC, not arenas |
| Global imports from `build.ms` | `transam.zig:304-308` | Build system integration deferred |

## 11. DRC Constraints

Every data structure must respect MetaScript DRC workarounds. Violating these causes use-after-free, double-free, or silent corruption.

### Mandatory Patterns

| # | Constraint | Impact on Trans-Am |
|---|-----------|-------------------|
| 1 | `string[]` is VALUE TYPE | Every `string[]` field becomes `interface StringList { items: string[] }` |
| 2 | NEVER pass fresh interface as function arg | All QueryKey, QueryValue stored in `const` before passing |
| 3 | `const x = try f();` with immediate use | All fallible operations use this pattern |
| 4 | Circular imports silently drop | Mutually recursive functions in SAME FILE. Callback injection for cross-file. |
| 5 | Interface = pointer type in C | TransAmDb, LruCache, DependencyStack -- no `&` needed |
| 6 | No try in match arms | Use if-else for query dispatch involving try |
| 7 | Interface name collision (global C namespace) | Prefix all names: `TaQueryKey`, `TaRevision`, `TaLruNode`, etc. |
| 8 | No indexOf/includes on strings | Use `slice`, `length`, `findChar` from `utils/string.ms` |
| 9 | Loop-var vs param codegen | Extract mutation of loop-iterated nodes into separate functions |
| 10 | No C-style for in match arms | Use while or for..of inside match blocks |

### Array Parameter Passing

Arrays are now passed by pointer (hidden_addr/hidden_deref). No wrapper interfaces needed:

```ms
// Arrays use bare T[] types — push() propagates to caller
interface GoodCache {
    keys: string[];
}
```

### Callback Injection for Cross-File Dependencies

Following `src/parser/statements/callbacks.ms`:

```ms
// transam/callbacks.ms
export let parseQueryFn: (db: TransAmDb, path: string) => ParseResult =
    null as unknown as (db: TransAmDb, path: string) => ParseResult;

export function registerParseQuery(
    fn: (db: TransAmDb, path: string) => ParseResult
): void {
    parseQueryFn = fn;
}

// queries/parse_query.ms
import { registerParseQuery } from "../callbacks";
registerParseQuery(actualParseQuery);
```

## 12. Implementation Priority

### Phase 1: Core Engine (~940 lines, 8 files)

**Goal**: Query-based pipeline. Files parsed/checked only when content changes.

| Step | File | Lines | Deps |
|------|------|-------|------|
| 1.1 | `revision.ms` | ~80 | None |
| 1.2 | `hash.ms` | ~60 | None |
| 1.3 | `query.ms` | ~120 | revision |
| 1.4 | `cache.ms` | ~200 | query, hash |
| 1.5 | `file_input.ms` | ~80 | revision, hash |
| 1.6 | `red_green.ms` | ~180 | query, cache |
| 1.7 | `module_deps.ms` | ~120 | hash |
| 1.8 | `index.ms` | ~100 | all above |

**Integration**: Modify `src/index.ms` to create TransAmDb, use setFileText + query-based compileSource.

### Phase 2: LSP Foundation (~440 lines, 5 files)

| Step | File | Lines | Deps |
|------|------|-------|------|
| 2.1 | `cancel.ms` | ~60 | revision |
| 2.2 | `intern.ms` | ~80 | hash |
| 2.3 | `queries/parse_query.ms` | ~80 | parser integration |
| 2.4 | `queries/symbols_query.ms` | ~100 | checker integration |
| 2.5 | `queries/check_query.ms` | ~120 | checker integration |

### Phase 3: Advanced (as needed)

- Disk cache for LSP startup latency
- Stale-while-revalidate completions
- Generic instance cache (when monomorphization lands)
- Diagnostics aggregation query

## 13. Testing Strategy

### Inline Tests per Module

```ms
// revision.ms
testGroup("TaRevision", () => {
    test("init starts at zero", () => {
        const rev = createRevision();
        check(rev.value === 0);
    });
    test("increment advances", () => {
        const rev = createRevision();
        incrementRevision(rev);
        check(rev.value === 1);
    });
});
```

### Key Test Scenarios

| Test Group | What It Validates |
|-----------|------------------|
| Revision tracking | increment, comparison, init |
| QueryKey hashing | equality, hash stability, different kinds produce different hashes |
| LRU cache | insert, get, eviction at capacity, LRU ordering |
| DependencyStack | push/pop, dependency recording, cycle detection (YELLOW) |
| Red-green core | GREEN path (no change), RED path (input changed), output-hash optimization |
| File input | setFileText change detection, hash-based no-op on identical content |
| Module deps | recordImport, getImporters, BFS invalidation, cycle handling |
| Integration | Full pipeline: setFileText -> parse -> symbols -> verify cache hit |

### Critical Integration Test

```ms
testGroup("Trans-Am Integration", () => {
    test("comment-only change keeps dependents GREEN", () => {
        const db = createTransAmDb();
        setFileText(db, "test.ms", "const x = 1;");
        const r1 = executeQuery(db, makeKey(QueryKind.Parse, "test.ms"));

        // Change only a comment -- parse output hash unchanged
        setFileText(db, "test.ms", "const x = 1; // comment");

        // symbols query should stay GREEN (parse output semantically identical)
        // This validates the core Salsa insight
        const symbolsKey = makeKey(QueryKind.Symbols, "test.ms");
        check(tryMarkGreen(db, symbolsKey));
    });
});
```

### Test Execution

```bash
rm -rf out && bun run test-ms src/compiler/transam/index.ms    # Trans-Am tests only
rm -rf out && bun run test-ms src/index.ms                     # Full compiler suite
```

---

## Quick Reference

### File Map

| File | Key Exports |
|------|-------------|
| `revision.ms` | `TaRevision`, `QueryState`, `Durability`, `QueryKind`, `TaQueryKey` |
| `query.ms` | `TaQueryValue`, `TaDependencyWithHash`, `TaDependencyStack` |
| `cache.ms` | `TaLruCache`, `createLruCache`, `cacheGet`, `cachePut` |
| `red_green.ms` | `tryMarkGreen`, `executeQuery`, `storeQueryResult` |
| `file_input.ms` | `TaFileInputStore`, `setFileText`, `getFileText`, `getFileHash` |
| `module_deps.ms` | `TaModuleDepGraph`, `recordModuleImport`, `invalidateDependents` |
| `hash.ms` | `hashString`, `hashNode` |
| `intern.ms` | `TaStringInterner`, `internString`, `lookupInterned` |
| `cancel.ms` | `getCancelVersion`, `checkCancel` |
| `index.ms` | `TransAmDb`, `createTransAmDb` |

### Reference Cross-Reference

| Self-Hosted | Reference Zig | rust-analyzer |
|------------|--------------|---------------|
| `revision.ms` | `types.zig:12-66` | `salsa::Revision` |
| `query.ms` | `types.zig:107-202` | `salsa::QueryValue` |
| `cache.ms` | `cache.zig:17-163` | `#[salsa::lru(N)]` |
| `red_green.ms` | `red_green.zig:38-293` | `salsa::tryMarkGreen` (internal) |
| `file_input.ms` | `input_queries.zig:42-128` | `base-db/src/lib.rs:262-306` |
| `module_deps.ms` | `module_graph.zig:22-158` | `hir-def/src/db.rs` (import tracking) |
| `intern.ms` | `intern.zig:12-58` | `#[salsa::interned]` |
| `cancel.ms` | `cancellation.zig:44-68` | `ide-db/src/apply_change.rs:13-22` |
