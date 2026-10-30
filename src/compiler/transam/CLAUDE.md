# Trans-Am — incremental query engine

Demand-driven cache of compilation results with red-green invalidation and change-revision early cutoff. Callers: `src/compiler/lsp/` and `checkModuleGraph` (`src/checker/orchestrator.ms`), the graph check of every batch command. Design, query DAG and the comparison with the reference: [`docs/TRANSAM.md`](../../../docs/TRANSAM.md).

## Rules

- **One concern per file, `index.ms` is the hub** — each store below is its own file with its inline tests; `TransAmDb` holds the stores beside the bound graph, the tree and context maps and the project's global-import state, so a new concern gets a file, not a field-by-field growth of `TransAmDb`.
- **Every exported type carries the `Ta` prefix** — interfaces share one global C namespace (`TaQueryKey`, `TaCacheStore`, `TaRevision`); `TransAmDb` is the one exception.
- **Arrays are bare `T[]` fields** — they pass by pointer, `push()` reaches the caller; no `interface FooList { items: Foo[] }` wrappers.
- **A query records its dependencies through the frame, never by hand at the call site** — `pushFrame`, compute, then `executeQueryWith` takes the frame's dependencies and minimum durability.
- **Every derived query passes the revision its output changed at** — `executeQueryWith` stores it as `changedAt`: the current revision, unless an exact comparison shows the output equals the previous one (`Preprocess` by its text, `Parse` by taking its `Preprocess`'s). Validity never rests on a hash, because two texts with one hash are not equal content.
- **A write records its own revision** — `setFileText` takes the revision of the write and sets the file's `changedAt` and the durability change markers itself; `dbSetFileText` passes the next revision and increments only when the text differs.
- **YELLOW means a cycle and answers false** — verification never recurses into an entry that is being verified.
- **HIGH durability is for the std root only** — such a dependency is not walked while no HIGH input changed since the entry was verified (`getLastChange`); it invalidates only when its `changedAt` is after the entry's `verifiedAt`, and a HIGH change walks it.
- **Cancellation is version-based** — a query captures the version at start and compares with `checkCancel`; no boolean flag.

## File map

| File | Key exports |
|------|-------------|
| `revision.ms` | `TaQueryKind`, `TaQueryState`, `TaDurability`, `TaRevision`, `TaQueryKey`, `createQueryKey`, `queryKeysEqual` |
| `query.ms` | `TaCacheEntry`, `TaDependencyStack`, `pushFrame`, `popFrame`, `recordDependency`, `recordDurability` |
| `cache.ms` | `TaCacheStore`, `cacheGet`, `cachePut`, `cacheRemove`, `markQueriesRedForFile` |
| `redGreen.ms` | `tryMarkGreen`, `executeQueryWith`, `invalidateFile` |
| `fileInput.ms` | `TaFileInputStore`, `setFileText`, `getFileText`, `getFileChangedAt`, `getFileId`, `getFileDurability`, `setFileDurability`, `getLastChange` |
| `moduleDeps.ms` | `TaModuleDepGraph`, `recordModuleImport`, `clearImportsFor`, `getTransitiveDependents`, `detectCycle` |
| `hash.ms` | `taHashString`, `transAmHashNode` |
| `cancel.ms` | `getCancelVersion`, `checkCancel`, `requestCancel`, `resetCancel` (`CancelCtx` lives in `src/checker/context.ms`) |
| `index.ms` | `TransAmDb`, `createTransAmDb`, `dbBindGraph`, `dbSetGlobalImports`, `dbSetFileText`, `dbPreprocess`, `dbParse`, `dbTypeCheck`, `dbCheckIsCurrent`, `dbLower`, `dbTransform`, `dbAnalyze`, `dbResolveImport`, `dbEnsureModuleExports` |

## Tests

```bash
msc test src/compiler/transam/index.ms
```
