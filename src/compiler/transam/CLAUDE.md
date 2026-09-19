# Trans-Am — incremental query engine

Demand-driven cache of compilation results with red-green invalidation and output-hash early cutoff. Callers: `src/compiler/lsp/`, `src/module/loader.ms`. Design, query DAG and the comparison with the reference: [`docs/TRANSAM.md`](../../../docs/TRANSAM.md).

## Rules

- **One concern per file, `index.ms` is the hub** — no god struct; `TransAmDb` is a thin facade whose fields are the stores below, and each store keeps its inline tests.
- **Every exported type carries the `Ta` prefix** — interfaces share one global C namespace (`TaQueryKey`, `TaCacheStore`, `TaRevision`); `TransAmDb` is the one exception.
- **Arrays are bare `T[]` fields** — they pass by pointer, `push()` reaches the caller; no `interface FooList { items: Foo[] }` wrappers.
- **A query records its dependencies through the frame, never by hand at the call site** — `pushFrame`, compute, then `executeQueryWith` takes the frame's dependencies and minimum durability.
- **Every derived query supplies an output hash** — early cutoff compares it: a dependency recomputed with the same hash leaves its dependents GREEN.
- **YELLOW means a cycle and answers false** — verification never recurses into an entry that is being verified.
- **HIGH durability is for the std root only** — such a dependency is not walked; it invalidates only when recomputed with a different output hash.
- **Cancellation is version-based** — a query captures the version at start and compares with `checkCancel`; no boolean flag.

## File map

| File | Key exports |
|------|-------------|
| `revision.ms` | `TaQueryKind`, `TaQueryState`, `TaDurability`, `TaRevision`, `TaQueryKey`, `createQueryKey`, `queryKeysEqual` |
| `query.ms` | `TaCacheEntry`, `TaDependencyEntry`, `TaDependencyStack`, `pushFrame`, `popFrame`, `recordDependency`, `recordDurability` |
| `cache.ms` | `TaCacheStore`, `cacheGet`, `cachePut`, `cacheRemove`, `markAllRed`, `markQueriesRedForFile` |
| `redGreen.ms` | `tryMarkGreen`, `executeQueryWith`, `invalidateFile` |
| `fileInput.ms` | `TaFileInputStore`, `setFileText`, `getFileText`, `getFileHash`, `getFileId`, `getFileDurability`, `setFileDurability` |
| `moduleDeps.ms` | `TaModuleDepGraph`, `recordModuleImport`, `clearImportsFor`, `getTransitiveDependents`, `detectCycle` |
| `hash.ms` | `taHashString`, `taHashKey`, `transAmHashNode` |
| `intern.ms` | `TaStringInterner`, `internString`, `lookupInterned` |
| `cancel.ms` | `getCancelVersion`, `checkCancel`, `requestCancel`, `resetCancel` (`CancelCtx` lives in `src/checker/context.ms`) |
| `index.ms` | `TransAmDb`, `createTransAmDb`, `dbSetFileText`, `dbPreprocess`, `dbParse`, `dbTypeCheck`, `dbTransform`, `dbAnalyze`, `dbResolveImport`, `dbEnsureModuleExports` |

## Tests

```bash
msc test src/compiler/transam/index.ms
```
