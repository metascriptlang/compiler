# Phase 4: DRC Analyzer

Deterministic Reference Counting injection for the C backend. Walks the post-transform AST, inserts RC operation calls (`=destroy`, `=copy`, `=sink`, `=wasMoved`) at the right places.

Architecture: **direct AST rewrite** with **scope-based cleanup** and **conservative last-read analysis**.

---

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `classify.ms` | ~255 | Type -> RcInfo mapping (RcKind enum, destroy/copy/wasMoved/sink fn names, `isFreshExpr()`) |
| `scope.ms` | ~398 | DrcScope/DrcContext, push/pop, var registration, move tracking, needsTry, OuterStack |
| `lastRead.ms` | ~281 | `isLastReadInBlock` + `isLastReadInContext` (cross-scope), `nodeReferencesVar`, `deepAliases` |
| `inject.ms` | ~1390 | Main walker: all node kinds, assignment types, sink params, call arg copies, literal copies |
| `optimize.ms` | ~389 | Post-pass: set-based wasMoved tracking, branch-aware eliminate `wasMoved(x); destroy(x)` |
| `index.ms` | ~89 | Hub: `analyzeProgram` entry point, re-exports |

**Pipeline**: `analyzeProgram(program, checkerCtx)` -> `injectProgram(program, dctx)` -> `optimizeDrc(injected)`

---

## Three-Stage Pipeline

| Stage | Files | Does | Does NOT |
|-------|-------|------|----------|
| **Hook Lifting** | `transform/lowering/destructorLifting.ms` | Generate per-type lifecycle hooks | Decide when/where to call them |
| **Injection** | `inject.ms` + `classify.ms` + `scope.ms` + `lastRead.ms` | Insert calls at correct AST positions | Generate hook bodies or optimize |
| **Optimization** | `optimize.ms` | Eliminate redundant `wasMoved(x); destroy(x)` | Restructure code or add operations |

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

**Never seen**: DeferStmt, ForOfStmt, ForStmt, MatchExpr, DestructuringDecl, OptionalMemberExpr

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
| `break`/`continue` | Set `needsTry` to loop boundary |
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

### Post-Optimization: Set-Based wasMoved + destroy Elimination

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
| String | String | `ms_string_decref` | `ms_string_incref` | `ms_string_was_moved` | `ms_string_sink` |
| Array (number elem) | Array | `ms_array_destroy` | `ms_array_copy` | `ms_array_number_was_moved` | `ms_array_number_sink` |
| Array (string elem) | Array | `ms_array_string_destroy` | `ms_array_string_copy` | `ms_array_string_was_moved` | `ms_array_string_sink` |
| Array (ref elem) | Array | `MS_ARRAY_REF_DESTROY` | `MS_ARRAY_REF_COPY` | `MS_ARRAY_REF_WAS_MOVED` | `MS_ARRAY_REF_COPY` |
| Ref / Ptr | Ref | `ms_decref` | `ms_incref` | `ms_ptr_was_moved` | -- |
| Object (interface/class) | Ref | `ms_decref` | `ms_incref` | `ms_ptr_was_moved` | -- |
| Object (named value type) | Named | `T_destroy` | `T_copy` | `T_wasMoved` | `T_sink` |
| Function (closure) | Closure | `ms_closure_destroy` | `ms_closure_copy` | `ms_closure_was_moved` | `ms_closure_sink` |
| Map | Map | `ms_map_free` | `ms_map_copy` | `ms_map_was_moved` | `ms_map_sink` |
| Set | Set | `ms_set_free` | `ms_set_copy` | -- | -- |

---

## Parity Analysis vs Reference Compiler & Nim

### Overall Status: ~80-85% reference parity, ~75-80% Nim parity

### BETTER Than Both

1. **Clean modular architecture** -- 6 focused files vs 4,771-line monolith (reference) or scattered across many files (Nim). Each file has inline tests.
2. **Cross-scope last-read via OuterStack** -- Elegant forward-scan across nested blocks within a function. Neither reference (CFG per-function) nor Nim (CFG per-function) have this specific abstraction.
3. **Branch-aware optimizer** -- `collectIfMoved()` + `nameSetIntersect()` is cleaner than Nim's equivalent while achieving the same result.
4. **DRC-safe data structures** -- All arrays wrapped in interfaces (`VarInfoList`, `MovedVarList`, `StmtBuf`), preventing value-type array bugs.
5. **Compound assignment handling** -- Proper `x += y` desugaring for RC types, handled more cleanly than reference.
6. **Per-module inline tests** -- Comprehensive test groups per file. Neither reference nor Nim have this for the DRC layer.

### ON PAR

1. **Scope management** -- Push/pop stack, needsTry propagation, LIFO cleanup order. Architecturally equivalent.
2. **Type classification** -- Same RC kinds (String, Array, Ref, Closure, Map, Set, Named). Named hooks match liftdestructors.
3. **Fresh expression detection** -- `isFreshExpr()` matches Nim's `nkCallKinds`/`nkObjConstr` handling.
4. **Self-assignment safety** -- `deepAliases()` matches Nim's `deepAliases()`.
5. **try/finally wrapping** -- Hoist + null init + try + finally cleanup matches Nim's `processScope()`.
6. **wasMoved+destroy elimination** -- Same patterns as Nim's optimizer including branch intersection.
7. **Member/field & array element RC** -- `emitSaveAssignDestroy()` pattern.
8. **Call argument processing** -- Last-read check per RC arg, move or copy.
9. **Return value handling** -- Mark returned vars moved + borrowed return incref.
10. **Result field extraction** -- Null-out of `$result_N.value` after extraction.

### WORSE (Gaps)

| Priority | Gap | Impact | What Reference/Nim Does |
|----------|-----|--------|------------------------|
| **HIGH** | No CFG-based last-read | Missed move optimizations in branches/loops | Reference: Mohnen graph-free CFG + BFS. Nim: per-variable CFG + work-queue |
| **MED** | No cursor inference | Unnecessary RC ops on borrowed refs | Nim: Steensgaard union-find (`varpartitions.nim`). Reference: `isCursor()` |
| **MED** | No closure capture optimization | Extra copies on every closure creation | Reference: `processClosureCaptures()` checks isLastRead per capture |
| **LOW** | No generator/async awareness | Unnecessary try/finally in generators | Reference: `in_generator` flag skips wrapping |
| **LOW** | No cycle detection | No ORC cycle collection | Reference: `visited_types`. Nim: `cyclicType()` + `nimMarkCyclic()` |
| **LOW** | No first-write sink optimization | Extra destroy on uninitialized dest | Nim: `nkFastAsgn` (bitwise memcopy) for first writes |
| **LOW** | No finally-protected vars | Potential double-free with defer+return | Reference: `finally_protected_vars` tracking |
| **LOW** | No `=dup`/`=sink` operator | Less granular lifecycle control | Nim: full operator taxonomy (copy, dup, sink, wasMoved, destroy) |

### Key Insight

The conservative forward-scan last-read analysis is the primary architectural limitation. It works correctly (never produces false moves) but misses optimization opportunities that CFG-based analysis captures:

```
// Self-hosted: conservatively copies x (sees x in both branches)
if (cond) { use(x); } else { use(x); }
// ^ After this, x IS actually last-read but conservative scan can't prove it

// CFG-based: correctly identifies x as last-read (both paths consume it)
```

Adding a CFG builder (Mohnen graph-free approach) would be the single most impactful improvement. The rest of the infrastructure (scope management, type classification, optimization) is already solid.

---

## Future Work (Post-Phase 5)

These are optimization improvements -- the current analyzer is **correct** (conservative, never false moves). Defer until Phase 5 (Codegen) produces real C output so impact can be measured.

1. **CFG-based last-read** -- Mohnen graph-free CFG + BFS work-queue. Replaces conservative forward scan. Biggest win.
2. **Cursor inference** -- Steensgaard union-find to auto-detect borrowed refs. Eliminates unnecessary RC ops.
3. **Closure capture optimization** -- Check isLastRead per capture site. Move instead of copy when possible.
4. **First-write sink** -- Track uninitialized destinations, skip destroy on first assignment.
5. **Generator awareness** -- Skip try/finally for generator state machines.
6. **Finally-protected vars** -- Track vars referenced in enclosing finally blocks to prevent premature cleanup.
