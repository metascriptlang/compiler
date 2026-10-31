# Trans-Am: Incremental Computation Engine

Incremental query engine of the MetaScript compiler, in `src/compiler/transam/`. Inspired by Salsa / rust-analyzer. Two callers: the LSP (`src/compiler/lsp/`), which keeps one db across edits, and `checkModuleGraph` (`src/checker/orchestrator.ms`), the graph check every `build`, `check`, `test` and `run` goes through, which binds a fresh db to the module graph the loader built (§5, "Bound to a loaded graph").

Rules for editing the module: [`src/compiler/transam/CLAUDE.md`](../src/compiler/transam/CLAUDE.md). The code is the source of truth for types and signatures; this file holds the design and the reasons.

## 1. What it is

Trans-Am is a **demand-driven incremental computation framework**: it caches compilation results (preprocessed source, parse trees, type-check contexts, transformed and analyzed trees) and recomputes only what a change can reach.

- **LSP latency** — re-parsing and re-checking a project on every keystroke is too slow; a per-file edit costs O(changed) instead of O(project).
- **Correctness** — the red-green algorithm keeps every served result consistent with the current file contents.

**Core insight** (the Salsa early cutoff): validity follows change revisions, not hashes. Every input file and every cache entry records `changedAt`, the revision at which its content last differed, and every entry records `verifiedAt`, the revision it was last known current. An entry stays valid while each dependency is current and none changed after the entry's `verifiedAt`. Equal content is established by comparing the content, never an equal hash: `setFileText` compares the two source strings and moves `changedAt` only on a real difference, `Preprocess` compares its new output with the cached output and keeps its old `changedAt` when they match, and `Parse`, a pure function of that text, takes its `changedAt` from `Preprocess`. A parse changes with its text because positions and comments reach diagnostics, `#line` and hover. A recomputed check keeps its old `changedAt` when its **interface** (`digest.ms`: exported declarations with routine bodies masked, checked types, error count) equals the previous one exactly and no direct import's check changed since it was last verified (`outputs.ms`); otherwise it is changed at the current revision, so an importer is rechecked when a dependency's interface moves, transitively, and stays green for a comment or body edit. A module that reads another's bodies (generic instantiation, template, macro, borrow and effect summaries, inlined iterators) records an `Impl` dependency on it through the body-read sink (`src/checker/bodyReads.ms`), and is rechecked when that module's implementation changes. `Lower`, `Transform` and `Analyze` also depend on the module's own text. The pins are in `src/compiler/transam/cutoff.ms`. That is the reference's rule for a kept graph (nimsuggest `markDirtyIfNeeded` → `markDirty` + `markClientsDirty`, `modulegraphs.nim`), narrowed to what an importer reads. Before the change-revision model every decision rested on a 32-bit DJB2 string hash or a fold of such hashes, so two different texts with the same hash (`Az` and `BY`) were taken for equal and renaming an export kept the old checked symbols.

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
                    |  |  Changes |    |  Store   |    |  Deps    |   |
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

`TransAmDb` (`index.ms`) is a thin facade over one store per concern: revision, file input, dependency stack, cache, module dep graph, cancel context, plus the checker's `ExportRegistry`, the resolver config, the prelude context and a preprocess cache.

`Node` and `CheckerContext` values are not held in the Trans-Am cache. Each db keeps them in its own maps (`TransAmDb` `trees`, `contexts`), keyed by `fileId` plus a per-query offset (`index.ms`, the `*Key` helpers). They are per db because file ids are per db: while they lived in process-wide caches, a db built inside another (the LSP prelude db) overwrote the outer db's entries for the same id. The Trans-Am cache holds the verification record: state, revisions (`computedAt`, `verifiedAt`, `changedAt`), dependencies, durability.

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
3. A `FileText` dependency is current when the file's `changedAt` is not after the entry's `verifiedAt`.
4. A dependency of HIGH durability is not walked while no HIGH input has changed since this entry was last verified (`getLastChange`, `fileInput.ms`); then it invalidates only when its `changedAt` is after the entry's `verifiedAt`. A write at durability D moves the change marker of every durability up to D, and changing a file's durability counts as a write at its old durability. When a HIGH input changed after the entry's last verification, the dependency is walked like any other.
5. Any other dependency is verified recursively. A `Preprocess` or `Parse` dependency that fails is executed again (`refreshInput`, `index.ms`) before the comparison, as Salsa's deep verify does; `TypeCheck` and `Impl` dependencies are rechecked by `recheckImports` before the second verification. Then the early cutoff applies: a `changedAt` after this entry's `verifiedAt` means RED; a dependency recomputed to the same output kept its old `changedAt`, so this entry stays GREEN.
6. Every dependency held: stamp `verifiedAt`, refresh the entry's durability from its inputs, mark GREEN.

A dependency records only its key; the revisions on both sides decide. A header edit that leaves the header's module text equal rechecks none of its importers, and a signature edit rechecks the importer and the module above it once each (pinned in `index.ms` tests).

A query function in `index.ms` (`dbPreprocess`, `dbParse`, `dbTypeCheck`, `dbTransform`, `dbAnalyze`) follows one shape: `tryMarkGreen` and serve from the value cache, else `pushFrame`, compute while sub-queries record themselves into the frame (`recordDependency`, `recordDurability`), then `executeQueryWith` stores the entry with the frame's dependencies, its minimum durability and the revision its output changed at.

Dependency tracking is frame-based on purpose: a sub-query records itself into whatever frame is active, so a query cannot forget a dependency.

A frame starts at HIGH durability and only `recordDurability` lowers it. A query records its own file's durability (`dbParse`, `dbTypeCheck`, `dbLower`); before 2026-09-25 `dbTypeCheck` did not, so every check of a user file claimed HIGH and a dependent verified before that check was recomputed skipped it.

## 4. Query kinds

`TaQueryKind` (`revision.ms`). A query key is `{ queryKind, fileId }`; `fileId` is the sequential id the file input store assigns to a path.

| Kind | Role | Computed by |
|------|------|-------------|
| `FileText` | input: raw source, set by the caller | `dbSetFileText` |
| `Preprocess` | raw text to module source: a `.h` file becomes its translated module (`headerModuleSource`); in a graph-bound db, the graph module's `source` | `dbPreprocess` |
| `Parse` | source to AST | `dbParse` |
| `TypeCheck` | AST to `CheckerContext` | `dbTypeCheck` |
| `Transform` | typed AST to transformed AST | `dbTransform` |
| `Analyze` | transformed AST to DRC-injected AST | `dbAnalyze` |
| `Lower` | checked AST to the build's native lowering (the A2 chain), cached by a kept build session; depends on the module's check only, the build compares the inputs that come from other modules ([`HCR.md`](HCR.md) "Watch builds") | `dbLower` |
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

1. `setFileText` compares the two texts; identical content returns false and nothing else happens. A difference records the file's `changedAt` and moves the durability change markers at the revision of the write, the next revision.
2. The revision increments.
3. A path under the configured std root gets HIGH durability.
4. The `ExportRegistry` entries of the file and its transitive importers are dropped; std paths are kept.
5. The next query call verifies lazily through `tryMarkGreen`.

A type check of a module whose dependency declares a macro runs a full check of that dependency first; `checkInProgress` guards that pre-check against cycles.

An import a db only binds, outside a loaded graph (`db.bound`), is reused while its import closure lists the same files in the same order and every `Parse` and `TypeCheck` entry in it has the `changedAt` it had at bind. A bound-only module has no `TypeCheck` entry, so an entry absent at bind must still be absent.

An import resolves by resolver priority every time (`dbResolveImport`), whichever candidate the db already holds. A candidate path with no file is an input of its own (`getInputId`, absent until a write): the check that resolved an import, and the `Preprocess` that probed a header's companion `.c`, depend on each such path, so creating a file at a higher-priority path changes what they read. An empty file is a file.

A changed `globalImports` list takes a revision, drops the bound units and the registered exports of every non-std module, and forgets their checks, because the layer they were checked under is gone.

A cancelled check returns its partial context to `dbTypeCheck`'s caller but caches nothing, and `dbTransform`, `dbAnalyze` and `dbLower` return null for it instead of lowering it; the two tree queries parse the `Preprocess` output the check read. Recording a dependency or storing a query with no matching frame is an internal error.

A check that is cancelled or throws stores nothing: its frames are popped, its in-progress mark, `_checkingDb` and the body-read sink are restored, its bound unit is discarded and the checks of its transitive readers are dropped, because they may hold that unit's Symbols. A throw then propagates; the LSP publishes it as an internal-error diagnostic on the file instead of an empty list.

### Bound to a loaded graph

`dbBindGraph` gives a db the loader's module graph: each module's `rawSource` becomes its `FileText`, the loader's import edges its module deps, and `dbTypeCheck` checks against the graph's own `Module` (the imports the loader resolved, circular back edges included). Two queries then take what the loader already computed:

- `Preprocess` serves the graph module's `source`, the loader's header inlining, instead of inlining again. A bound db therefore records no dependency on a `.h` file: a header change reaches it only through module text the loader re-inlines, so a bound db kept across builds (`--watch`, [`HCR.md`](HCR.md)) has to rerun the loader for every build. The LSP keeps TransAm's own inlining; the test "an unbound db inlines a C header the way the loader does" pins that both produce the same text.
- A bound check stamps its module registered at the current revision, so a later dependent's export walk (`dbEnsureExportsRegistered`) stops at modules already checked. The walk still registers the collect-level exports of a dependency not checked yet, which is what an import cycle's back edge needs.

A build session (`msc build --hcr --watch`) keeps one bound db across builds: `checkModuleGraph` takes the session's db and prelude context, binds the new graph (changed `FileText` inputs bump the revision), registers a module's kept checked tree when its check is still current, and records per module the check it produced and the generic instances that check created ([`HCR.md`](HCR.md) "Watch builds").

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
| Durability levels LOW / MEDIUM / HIGH | `types.zig` | Std files skip verification |
| BFS transitive invalidation | `module_graph.zig` | Correct propagation, cycle-safe |
| Dependency stack with push / pop frames | `types.zig` | Automatic dependency tracking |
| Version-based cancellation | `cancellation.zig` | Responsive LSP: a query that began before a keystroke sees the version change |

### Changed from the reference

| Change | Reference | Here | Why |
|--------|-----------|------|-----|
| Module per concern | god struct | 9 files | DRC safety, testability |
| Dependency tracking | manual `recordDependency()` at each site | frame-based scope | Cannot be forgotten |
| Cache | pointer-based doubly-linked LRU | one `TaCacheStore`: lookup and invalidation through a `fileId` index, access-clock LRU with linear-scan eviction | DRC does not manage arbitrary graph pointers; an O(1) eviction list is an upgrade to make when a profile asks for it |
| Early cutoff | output hash per entry, compared with the hash a dependent recorded | `changedAt` revision per entry and per input file, kept by `Preprocess` and `Parse` when an exact comparison shows no change | An equal hash is not equal content: `Az` and `BY` share a hash, and a hash fold only makes a collision rarer |
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
| String interner | `intern.zig` | Query keys are sequential file ids; nothing reads an interned id |

## 7. File cross-reference

| Self-hosted | Reference Zig | rust-analyzer |
|-------------|---------------|---------------|
| `revision.ms` | `types.zig` | `salsa::Revision` |
| `query.ms` | `types.zig` | `salsa::QueryValue` |
| `cache.ms` | `cache.zig` | `#[salsa::lru(N)]` |
| `redGreen.ms` | `red_green.zig` | `salsa::tryMarkGreen` (internal) |
| `fileInput.ms` | `input_queries.zig` | `base-db/src/lib.rs` |
| `moduleDeps.ms` | `module_graph.zig` | `hir-def/src/db.rs` (import tracking) |
| `cancel.ms` | `cancellation.zig` | `ide-db/src/apply_change.rs` |

## Not verified here

The "Reference" columns describe a Zig implementation that was not available when this file was written; its file names are carried over from the original design notes, its line numbers were dropped. Performance effects (the speedup from durability, eviction behaviour under load) are not measured in this document. The graph-bound timings in §5 come from one loaded Windows host; Linux and macOS were not measured, and the LSP path was not re-timed after the bound-db changes (they do not run there).
