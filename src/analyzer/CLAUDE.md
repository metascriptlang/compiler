# Phase 4: DRC Analyzer

Deterministic Reference Counting injection for the C backend. Walks the post-transform AST, inserts RC operation calls (`=destroy`, `=copy`, `=sink`, `=wasMoved`) at the right places.

Architecture: **direct AST rewrite** with **scope-based cleanup** and **conservative last-read analysis**.

---

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `alias.ms` | ~140 | `AliasKind` (yes/no/maybe), `aliases()` path-level comparison, `isAnalysableFieldAccess()` ownership gate, `deepAliases()`, `skipConvDfa()`, `getRootSym()` |
| `classify.ms` | ~255 | Type -> RcInfo mapping (RcKind enum, lifecycle hooks, `isFreshExpr()`, `canFormCycle()`) |
| `scope.ms` | ~420 | DrcScope/DrcContext, push/pop, var registration, move tracking, needsTry, OuterStack, VarInfo.isInitialized |
| `lastRead.ms` | ~270 | `isLastReadInBlock` + `isLastReadInContext` (cross-scope), `nodeReferencesVar` |
| `cfg.ms` | ~730 | CFG implementation: `buildCfg`/`buildCfgForSym`, `isLastReadCfg`/`isLastReadCfgNode` (alias-aware BFS), `isLastReadCfgNodeCached`, separate name/sym CfgCache |
| `cursors.ms` | ~550 | Cursor (borrow) inference: Steensgaard union-find algorithm with live ranges, mutation tracking, dangerousMutation safety check |
| `inject.ms` | ~2220 | Main walker: all node kinds, CFG last-read, field-level moves (alias-aware), finally-protected vars, cursor check, first-write opt, generator detection |
| `optimize.ms` | ~389 | Post-pass: set-based wasMoved tracking, branch-aware eliminate redundant operations |
| `index.ms` | ~89 | Hub: `analyzeProgram` entry point, re-exports |

**Pipeline**: `analyzeProgram(program, checkerCtx)` -> `injectProgram(program, dctx)` -> `optimizeDrc(injected)`

---

## Three-Stage Pipeline

| Stage | Files | Does | Does NOT |
|-------|-------|------|----------|
| **Hook Lifting** | `transform/lowering/destructorLifting.ms` | Generate per-type lifecycle hooks | Decide when/where to call them |
| **Injection** | `inject.ms` + `classify.ms` + `scope.ms` + `lastRead.ms` | Insert calls at correct AST positions | Generate hook bodies or optimize |
| **Optimization** | `optimize.ms` | Eliminate redundant operations | Restructure code or add operations |

---

## What the Analyzer Sees (Post-Transform AST)

By Phase 4, 22+ transforms have already executed. Many complex syntax forms are lowered:

| Original | Lowered To |
|----------|-----------|
| `defer` | `try/finally` |
| `match` | `if/else` chain |
| `for..of` | `while` + iterator |
| `for (let i…)` | `{ let i; while { } }` |
| `const x = try f()` | `const $r = f(); if (!$r.ok) return…` |
| `a?.b` | `a !== null ? a.b : null` |
| `x ?? y` | `x !== null ? x : y` |
| Destructuring | Multiple VariableDecl |
| Arrow with captures | Lifted function + env struct |
| Extension methods | Direct call |

---

## RC Insertion Points (All Implemented)

| Context | What happens |
|---------|-------------|
| `const x = fresh()` | SINK -- ownership transfer, no copy |
| `const x = y` (last read) | MOVE -- assign + `wasMoved(y)` |
| `const x = y` (not last read) | COPY -- assign + `incref(x)` or `copy(x)` |
| `const x = obj.field` | BORROW -- assign + `incref(x)` |
| `x = fresh()` (reassignment) | Destroy old, assign new |
| `x = y` (last/not last) | Destroy old + assign + move/copy |
| `x = f(x)` (self-alias) | Save old in temp, assign, destroy temp |
| `obj.field = expr` | Save old field, assign new, destroy old |
| `arr[i] = expr` | Same as member assignment |
| `x += y` (compound) | Save old, compute, assign, destroy old |
| `{ field: rcVar }` | incref/copy each RC field in literals |
| `[a, b, c]` | incref/copy each RC element |
| `f(rcVar)` (call arg) | incref before (not last-read) or wasMoved after (last-read) |
| `const x = c ? a : b` | Copy dest if either branch non-fresh |
| `return expr` | Mark returned vars moved; finally handles cleanup |
| Scope exit | `=destroy` tracked vars in LIFO order |
| `break`/`continue` | Set boundary to loop boundary |
| `throw` | Set `needsTry` on all scopes |
| Discarded `f()` | Capture in temp, register for cleanup |
| Sink params | Register RC-typed params for cleanup at scope exit |
| `__envP*` params | Skip (managed by closure infrastructure) |

---

## Key Algorithms

### moveOrCopy Decision Tree

```
1. rcInfo.needsCleanup is false -> pass through (primitive)
2. src is fresh (call/literal/constructor/move) -> SINK (no copy)
3. src is identifier:
   a. isLastRead(src) -> MOVE: assign + wasMoved(src)
   b. else -> COPY: assign + copyFn(dest)
4. src is member/index access -> COPY (conservative, borrow + incref)
5. src is conditional -> copy dest if either branch non-fresh
6. default -> COPY (conservative)
```

### Scope Cleanup Generation

```
On scope exit:
1. For each moved variable: emit wasMoved(var)
2. For each tracked variable in REVERSE (LIFO):
   - Skip if: cursor, excluded (return expr), already moved
   - Emit destroy(var)
3. If needsTry && cleanup non-empty:
   - Hoist RC decls before try (null init)
   - Original inits become assignments inside try
   - Wrap: try { body } finally { cleanup }
```

### Post-Optimization: Redundant Operation Elimination

```
For each block:
1. Track MovedSet of definitely-moved variables
2. wasMoved(x) -> add x to MovedSet
3. destroy(x) where x in MovedSet -> eliminate (even non-adjacent)
4. Exhaustive if/else -> intersect MovedSets from all branches
5. Recurse into sub-blocks
```

---

## Type Classification

| TypeKind | RcKind | destroy | copy | wasMoved | sink |
|----------|--------|---------|------|----------|------|
| Number/Bool/Void/Null/Int*/Enum | None | -- | -- | -- | -- |
| String | String | `msStringDecref` | `msStringIncref` | `msStringWasMoved` | `msStringSink` |
| Array (number elem) | Array | `msArrayDestroy` | `msArrayCopy` | `msArrayNumberWasMoved` | `msArrayNumberSink` |
| Array (string elem) | Array | `msArrayStringDestroy` | `msArrayStringCopy` | `msArrayStringWasMoved` | `msArrayStringSink` |
| Array (ref elem) | Array | `MS_ARRAY_REF_DESTROY` | `MS_ARRAY_REF_COPY` | `MS_ARRAY_REF_WAS_MOVED` | `MS_ARRAY_REF_COPY` |
| Ref / Ptr | Ref | `msDecref` | `msIncref` | `msPtrWasMoved` | -- |
| Object (interface/class) | Ref | `msDecref` | `msIncref` | `msPtrWasMoved` | -- |
| Object (named value type) | Named | `T_destroy` | `T_copy` | `T_wasMoved` | `T_sink` |
| Function (closure) | Closure | `msClosureDestroy` | `msClosureCopy` | `msClosureWasMoved` | `msClosureSink` |
| Map | Map | `msMapFree` | `msMapCopy` | `msMapWasMoved` | `msMapSink` |
| Set | Set | `msSetFree` | `msSetCopy` | -- | -- |

---

## Parity Analysis vs Reference Implementation

### Overall Status: ~100% implementation parity (all 7 gaps closed)

### BETTER Than Reference

1. **Clean modular architecture** -- 7 focused files vs multi-thousand line monoliths in other implementations. Each file has inline tests.
2. **Cross-scope last-read via OuterStack** -- Elegant forward-scan across nested blocks within a function.
3. **Branch-aware optimizer** -- `collectIfMoved()` + `nameSetIntersect()` is cleaner than standard equivalents while achieving the same result.
4. **Clean data structures** -- Bare `T[]` types throughout (no wrapper interfaces). Strings still value types.
5. **Compound assignment handling** -- Proper `x += y` desugaring for RC types, handled more cleanly than other references.
6. **Per-module inline tests** -- Comprehensive test groups per file.

### ON PAR

1. **Scope management** -- Push/pop stack, needsTry propagation, LIFO cleanup order. Architecturally equivalent.
2. **Type classification** -- Standard RC kinds (String, Array, Ref, Closure, Map, Set, Named).
3. **Fresh expression detection** -- `isFreshExpr()` matches standard call/constructor handling.
4. **Alias analysis** -- `alias.ms`: `AliasKind` (yes/no/maybe), `aliases()` path decomposition, `isAnalysableFieldAccess()` ownership gate, `deepAliases()` recursive self-alias check. Full parity with reference alias analysis.
5. **try/finally wrapping** -- Hoist + null init + try + finally cleanup matches standard scoped management.
6. **wasMoved+destroy elimination** -- Same patterns as standard optimizers including branch intersection.
7. **Member/field & array element RC** -- `emitSaveAssignDestroy()` pattern.
8. **Call argument processing** -- Last-read check per RC arg, move or copy.
9. **Return value handling** -- Mark returned vars moved + borrowed return incref.
10. **Result field extraction** -- Null-out of result values after extraction.

### CLOSED GAPS (All 7 gaps resolved — 2026-03-04)

| Phase | Gap | Resolution | Files |
|-------|-----|-----------|-------|
| **A** | Finally-protected variables | `collectFinallyVars` scans try/catch finallyBody, blocks moves on protected vars | inject.ms, scope.ms |
| **B** | Cursor inference | `inferCursors(body)` wired into `processFuncBodyWithParams`, `isCursorVar` check in `processVarDecl` | inject.ms, cursors.ms |
| **C** | CFG-based last-read | `isLastReadCfgCached` uses Mohnen graph-free CFG from cfg.ms, with per-function cache | inject.ms, cfg.ms, scope.ms |
| **D** | First-write optimization | `isInitialized` flag on VarInfo, `markUninitialized` for `let x;`, first assignment skips destroy | inject.ms, scope.ms |
| **E** | Sink parameter forwarding | SymbolFlag.Lent skip at call sites, sink-as-cursor for return-only params, CFG handles move detection | inject.ms (verified) |
| **F** | Closure capture DRC | Last-use captures wrapped in MoveExpr | lambdaLifting.ms, util.ms |
| **G** | Generator/async awareness | `isGeneratorBody` detects state pattern, forces `needsTry=false` to skip redundant try/finally | inject.ms |

Cycle detection was already implemented prior to this work (classify.ms `canFormCycle` + destructorLifting.ms trace hooks).

---

## Remaining Differences (by design)

| Item | Status | Rationale |
|------|--------|-----------|
| `=dup` operator | Not needed | `=copy` + temp achieves same result |
| Steensgaard union-find | Full parity | Two-pass algorithm with live ranges, union-find graphs, mutation tracking, dangerousMutation safety check |
