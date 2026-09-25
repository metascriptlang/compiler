# Trans-Am: Incremental Computation Engine

Incremental query engine of the MetaScript compiler, in `src/compiler/transam/`. Inspired by Salsa / rust-analyzer. Two callers: the LSP (`src/compiler/lsp/`), which keeps one db across edits, and `checkModuleGraph` (`src/checker/orchestrator.ms`), the graph check every `build`, `check`, `test` and `run` goes through, which binds a fresh db to the module graph the loader built (§5, "Bound to a loaded graph").

Rules for editing the module: [`src/compiler/transam/CLAUDE.md`](../src/compiler/transam/CLAUDE.md). The code is the source of truth for types and signatures; this file holds the design and the reasons.

## 1. What it is

Trans-Am is a **demand-driven incremental computation framework**: it caches compilation results (preprocessed source, parse trees, type-check contexts, transformed and analyzed trees) and recomputes only what a change can reach.

- **LSP latency** — re-parsing and re-checking a project on every keystroke is too slow; a per-file edit costs O(changed) instead of O(project).
- **Correctness** — the red-green algorithm keeps every served result consistent with the current file contents.

**Core insight** (the Salsa early cutoff): when a dependency is recomputed, its dependents are not invalidated right away. The engine compares the dependency's **output hash** first. A comment-only edit produces the same parse output hash, so every downstream query stays GREEN.

## 2. Architecture

```
                    +-------------------------------------------------+
                    |                   TransAmDb                      |
                    |                                                 |
  LSP / loader ---->|  +----------+    +-----------+                  |
  dbSetFileText()   |  |  File    |--->| Red-Green |                  |
  dbParse()         |  |  Input   |    |  Engine   |                  |
  dbTypeCheck() ... |  +----------+    +-----+-----+                  |
                    |       |                |                        |
                    |       v                v                        |
                    |  +----------+    +----------+    +----------+   |
                    |  |  File    |    |  Cache   |    |  Module  |   |
                    |  |  Hashes  |    |  Store   |    |  Deps    |   |
                    |  +----------+    +----------+    +----------+   |
                    +-------------------------------------------------+

  Query DAG:
  +----------+    +------------+    +---------+    +-----------+    +-----------+
  | FileText |--->| Preprocess |--->|  Parse  |--->| TypeCheck |--->| Transform |
  | (input)  |    |  (cached)  |    | (cached)|    |  (cached) |    |  Analyze  |
  +----------+    +------------+    +---------+    +-----------+    +-----------+
                        |                |               |
                        +---- dependencies recorded by frame ----+
```

`TransAmDb` (`index.ms`) is a thin facade over one store per concern: revision, file input, dependency stack, cache, module dep graph, cancel context, interner, plus the checker's `ExportRegistry`, the resolver config, the prelude context and a preprocess cache.

`Node` and `CheckerContext` values are not held in the Trans-Am cache. Each db keeps them in its own maps (`TransAmDb` `trees`, `contexts`), keyed by `fileId` plus a per-query offset (`index.ms`, the `*Key` helpers). They are per db because file ids are per db: while they lived in process-wide caches, a db built inside another (the LSP prelude with extra `globalImports`) overwrote the outer db's entries for the same id. The Trans-Am cache holds the verification record: state, revisions, output hash, dependencies, durability.

## 3. Red-Green

Three states per cached query (`TaQueryState`, `revision.ms`):

| State | Meaning | Action |
|-------|---------|--------|
| GREEN | Verified current this revision | Serve the cached value |
| RED | Potentially stale | Verify or recompute |
| YELLOW | Being verified right now | Cycle detected: verification answers false |

`tryMarkGreen` (`redGreen.ms`) decides whether a cached entry can be served:

1. Verified at the current revision already: answer from its state.
2. YELLOW: a cycle, answer false. Otherwise mark YELLOW and walk the recorded dependencies.
3. A `FileText` dependency compares the file's current content hash with the hash recorded when the entry was computed.
4. A dependency of HIGH durability is not walked; it invalidates only when it was recomputed after this entry and its output hash differs.
5. Any other dependency is verified recursively, stamped as verified so shared subtrees are walked once, then the early cutoff applies: recomputed later than this entry and a different output hash means RED; recomputed with the same output hash stays GREEN.
6. Every dependency held: stamp `verifiedAt`, mark GREEN.

A query function in `index.ms` (`dbPreprocess`, `dbParse`, `dbTypeCheck`, `dbTransform`, `dbAnalyze`) follows one shape: `tryMarkGreen` and serve from the value cache, else `pushFrame`, compute while sub-queries record themselves into the frame (`recordDependency`, `recordDurability`), hash the output, then `executeQueryWith` stores the entry with the frame's dependencies and its minimum durability.

Dependency tracking is frame-based on purpose: a sub-query records itself into whatever frame is active, so a query cannot forget a dependency.

## 4. Query kinds

`TaQueryKind` (`revision.ms`). A query key is `{ queryKind, fileId }`; `fileId` is the sequential id the file input store assigns to a path.

| Kind | Role | Computed by |
|------|------|-------------|
| `FileText` | input: raw source, set by the caller | `dbSetFileText` |
| `Preprocess` | raw text to preprocessed source (`.h` translation, `.h` import inlining); in a graph-bound db, the graph module's `source` | `dbPreprocess` |
| `Parse` | source to AST | `dbParse` |
| `TypeCheck` | AST to `CheckerContext` | `dbTypeCheck` |
| `Transform` | typed AST to transformed AST | `dbTransform` |
| `Analyze` | transformed AST to DRC-injected AST | `dbAnalyze` |
| `FileHash`, `ModuleDeps` | declared, not executed as queries by the hub | — |

Import edges are recorded into the module dep graph while a module's exports are registered (`dbRecordDepImports`), not through a `ModuleDeps` query. `dbResolveImport` is a plain function, never cached.

## 5. How queries reach the compiler

| Query | Module | Function called |
|-------|--------|-----------------|
| `Parse` | `src/parser/statements/validation.ms` | `parseSourceLenient` (`parseSource` on the transform / analyze path) |
| export collection | `src/checker/collectPass.ms`, `src/checker/resolvePass.ms` | `collectTopLevelLocal`, `resolveDeclarations` |
| `TypeCheck` | `src/checker/checkPass.ms` | `checkProgramWithRegistryCancellable` |
| `Transform` | `src/transform/index.ms` | `transformProgram` |
| `Analyze` | `src/analyzer/index.ms` | `analyzeProgram` |

`ModuleGraph` (`src/module/graph.ms`) describes static structure. Trans-Am's `moduleDeps.ms` holds the importer edges used for invalidation.

`dbSetFileText(path, source)`:

1. `setFileText` compares content hashes; identical content returns false and nothing else happens.
2. The revision increments.
3. A path under the configured std root gets HIGH durability.
4. `invalidateFile` marks the file's queries RED, then those of every transitive importer (BFS with a visited set, so import cycles terminate).
5. The `ExportRegistry` entries of the file and its transitive importers are dropped; std paths are kept.
6. The next query call verifies lazily through `tryMarkGreen`.

A type check of a module whose dependency declares a macro runs a full check of that dependency first; `checkInProgress` guards that pre-check against cycles.

### Bound to a loaded graph

`dbBindGraph` gives a db the loader's module graph: each module's `rawSource` becomes its `FileText`, the loader's import edges its module deps, and `dbTypeCheck` checks against the graph's own `Module` (the imports the loader resolved, circular back edges included). Two queries then take what the loader already computed:

- `Preprocess` serves the graph module's `source`, the loader's header inlining, instead of inlining again. A bound db therefore records no dependency on a `.h` file: a header change reaches it only through module text the loader re-inlines, so a bound db kept across builds (`--watch`, [`HCR.md`](HCR.md)) has to rerun the loader for every build. The LSP keeps TransAm's own inlining; the test "an unbound db inlines a C header the way the loader does" pins that both produce the same text.
- A bound check stamps its module registered at the current revision, so a later dependent's export walk (`dbEnsureExportsRegistered`) stops at modules already checked. The walk still registers the collect-level exports of a dependency not checked yet, which is what an import cycle's back edge needs.

Kept on purpose: `checkModuleGraph` registers a clone of every parse before any check. The two-phase driver it replaced did the same so that a cross-module `@comptime` could reach a sibling's AST before that sibling's check (a race seen on Linux ARM, not reproducible on the host that measured this); it costs the 0.46–0.49 s clone below.

Self-host (`src/index.ms`, 353 modules), `msc build src/index.ms --gc=drc --danger --emit=c --time`, Windows x64, four interleaved rounds per session on a machine shared with other gates (68–76 % load of 32 threads), `graph load+check` in seconds:

| session | two-phase driver (tree `5cf5c51d`) | bound db |
|---|---|---|
| 1 | 8.2 / 9.0 / 8.2 / 9.6 | 13.4 / 11.1 / 12.0 / 13.2, re-inlining headers and re-walking exports (tree `111db8e3`) |
| 2 | 8.95 / 11.78 / 9.97 / 9.84 | 11.73 / 11.32 / 10.47 / 10.16, as described above (tree `8ae178d0`) |

Split on tree `8ae178d0` with temporary timers, two runs: loader half ~3.1 s (the same as the old driver); prelude 1.12–1.16 s; one parse per module 1.33 s (the old driver parsed twice, ~2.1 s); the pre-check clone 0.46–0.49 s and the per-check clone 0.57–0.58 s; export walk 0.011 s (0.83–1.08 s before the stamp); dependency recording 0.25 s; the checker itself 2.65–2.76 s. On tree `111db8e3` the header re-inlining cost 0.57–0.74 s. Peak working set, tree `111db8e3`: 1.86 GB bound vs 2.02 GB for the two-phase driver.

## 6. Design decisions

### Module per concern, not a god struct

The reference Zig implementation of this engine keeps 40+ fields in one `TransAmDatabase` struct (`transam.zig`). Here each concern is a file with its own inline tests, and `index.ms` is the hub that re-exports them.

| Aspect | Reference (god struct) | Self-hosted (module per concern) |
|--------|------------------------|----------------------------------|
| File size | one file, 800+ lines of fields alone | one store per file, the hub holds the queries |
| Memory | manual | DRC; arrays are passed by pointer, fields are bare `T[]` |
| Circular imports | one file, no problem | hub re-exports; callbacks are registered, not imported |
| Testing | hard to isolate | every module carries inline tests |

### Kept from the reference

| Pattern | Reference file | Why |
|---------|----------------|-----|
| Red-green algorithm | `red_green.zig` | Core correctness, Salsa-proven |
| Content-addressed output hashing | `red_green.zig` | No recomputation on semantics-preserving edits |
| Durability levels LOW / MEDIUM / HIGH | `types.zig` | Std files skip verification |
| BFS transitive invalidation | `module_graph.zig` | Correct propagation, cycle-safe |
| Dependency stack with push / pop frames | `types.zig` | Automatic dependency tracking |
| Version-based cancellation | `cancellation.zig` | Responsive LSP without boolean-flag races |
| String interner | `intern.zig` | Present as a module; the hub exercises it only in tests |

### Changed from the reference

| Change | Reference | Here | Why |
|--------|-----------|------|-----|
| Module per concern | god struct | 10 files | DRC safety, testability |
| Dependency tracking | manual `recordDependency()` at each site | frame-based scope | Cannot be forgotten |
| Cache | pointer-based doubly-linked LRU | one `TaCacheStore`: access-counter LRU with linear-scan eviction, plus a `fileId` index for invalidation | DRC does not manage arbitrary graph pointers; an O(1) list is an upgrade to make when a profile asks for it |
| Query results | `*anyopaque` + type id | typed value caches beside `Node` and `CheckerContext` | Type safety, destructors resolve in the owning module |
| Trivial derivations | all cached | `dbResolveImport` is a plain function | Less memory, less eviction |

### Left out

| Feature | Reference file | Why |
|---------|----------------|-----|
| Disk cache | `disk_cache.zig` | Batch builds do not need persistence; an LSP-startup concern |
| Network cache | `network_cache.zig` | Not built |
| Generic instance cache | `generic_cache.zig` | Not built; the hub caches per file, not per instance |
| Parallel / async expansion | `cancellation.zig` (atomics) | The engine runs single-threaded |
| Highlight, completion, format caches | `highlight.zig`, `completion.zig`, `format.zig` | LSP-side concerns, outside the engine |
| AST arena management | `transam.zig` | DRC owns the trees |

## 7. File cross-reference

| Self-hosted | Reference Zig | rust-analyzer |
|-------------|---------------|---------------|
| `revision.ms` | `types.zig` | `salsa::Revision` |
| `query.ms` | `types.zig` | `salsa::QueryValue` |
| `cache.ms` | `cache.zig` | `#[salsa::lru(N)]` |
| `redGreen.ms` | `red_green.zig` | `salsa::tryMarkGreen` (internal) |
| `fileInput.ms` | `input_queries.zig` | `base-db/src/lib.rs` |
| `moduleDeps.ms` | `module_graph.zig` | `hir-def/src/db.rs` (import tracking) |
| `intern.ms` | `intern.zig` | `#[salsa::interned]` |
| `cancel.ms` | `cancellation.zig` | `ide-db/src/apply_change.rs` |

## Not verified here

The "Reference" columns describe a Zig implementation that was not available when this file was written; its file names are carried over from the original design notes, its line numbers were dropped. Performance effects (the speedup from durability, eviction behaviour under load) are not measured in this document. The graph-bound timings in §5 come from one loaded Windows host; Linux and macOS were not measured, and the LSP path was not re-timed after the bound-db changes (they do not run there).
