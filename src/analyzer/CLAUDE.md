# Phase 4: DRC Analyzer

Deterministic reference counting for the C backend: `analyzeProgram(program, checkerCtx)` → `injectProgram` → `optimizeDrc`. It rewrites the post-transform AST in place, inserting `=destroy`, `=copy`, `=sink`, `=wasMoved` calls. The decision tree, the insertion points, scope cleanup and the optimizer: [`docs/ANALYZER.md`](../../docs/ANALYZER.md).

## Rules

- **Three stages, each with one job** — hook lifting (`src/transform/lowering/destructorLifting.ms`) generates the per-type hooks and never decides where they are called; injection inserts the calls and never generates a hook body or optimizes; optimization (`optimize.ms`) only removes redundant operations — it neither restructures code nor adds an operation.
- **The injector works on the post-transform AST** — `defer`, `match` expressions, `try` expressions, `?.`, `??` and destructuring are gone before Phase 4 and `inject.ms` has no case for them.
- **A fresh value is sunk, a last read is moved, everything else is copied** — fresh = call, literal, constructor, `move`; "last read" comes from the CFG analysis (`cfg.ms`), alias-aware (`alias.ms`); when in doubt the answer is COPY.
- **A cursor carries no RC** — a variable `cursors.ms` infers to be a borrow is neither copied, moved nor destroyed.
- **A `Ptr<T>` variable is never moved into an owning slot** — it holds a borrow; at sink and return materialization `sinkClassify` treats a `Ptr` to a counted Ref as the pointee, so it is copied (incref) and the destination's decref stays balanced. A `Ptr` to a non-Ref pointee (malloc, FFI) is untouched.
- **A variable read inside a `finally` is never moved out before it** — `collectFinallyVars` blocks the move.
- **Cleanup is scope-based and LIFO** — tracked variables are destroyed in reverse at scope exit; a scope that can throw wraps its body in `try/finally` with the RC declarations hoisted and null-initialized; a generator state body skips the wrapper.
- **`__envP*` parameters are left alone** — the closure machinery owns them.

## File map

| File | Key exports |
|------|-------------|
| `index.ms` | `analyzeProgram` |
| `inject.ms` | `injectProgram` — the walker: `moveOrCopy`, `genSink` / `genCopy`, `generateCleanup`, try/finally wrapping |
| `classify.ms` | `RcKind`, `RcInfo`, `classifyType`, `isFreshExpr`, `anonUnionOwnsRc` |
| `scope.ms` | `DrcContext`, `DrcScope`, `VarInfo`, `pushScope` / `popScope`, `registerVar`, `recordMove`, `markUninitialized`, `setNeedsTryAll` |
| `lastRead.ms` | `isLastReadInBlock`, `isLastReadInContext`, `nodeReferencesVar` |
| `cfg.ms` | `buildCfg`, `buildCfgForSym`, `isLastReadCfg`, `isLastReadCfgNode`, the cached variants, `CfgCache` |
| `alias.ms` | `AliasKind`, `aliases`, `deepAliases`, `isAnalysableFieldAccess`, `skipConvDfa`, `getRootSym` |
| `cursors.ms` | `inferCursors` |
| `optimize.ms` | `optimizeDrc` |

## Tests

```bash
msc test src/analyzer/index.ms
```

A passing `--gc=drc` probe says nothing about ORC: without `MSGC_ORC` the cycle collector is a no-op (`runtime/drc.h`). A DRC change is proven by the corpus, which builds every program under both `--gc=drc` and `--gc=orc`, not by small leak probes.
