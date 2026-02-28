# Move Semantics — Design & Implementation Phases

MetaScript's `move` keyword is an ownership transfer directive. It forces sink semantics (no copy) and zeroes the source to prevent double-free.

```ms
const y = move x;        // y owns the data, x is zeroed
y = move x;              // old y destroyed, y = x's value, x zeroed
return move data;         // caller takes ownership, local zeroed
consume(move buffer);     // callee takes ownership, caller's var zeroed
{ name: move s }          // literal takes ownership, s zeroed
[move a, move b]          // array takes ownership, a/b zeroed
```

## Compiler Equivalent

MetaScript `move x` = `ensureMove(x)` in production compilers.

Production compilers have TWO move mechanisms:

| | `move(x: var T)` | `ensureMove(x: T)` |
|---|---|---|
| Kind | Normal function | Magic directive |
| isLastRead check | YES — falls back to copy | BYPASSED — forces move |
| Error | None — silently copies | `errFailedMove` if copy would be needed |

MetaScript only has the keyword form (`move x`), which maps to `ensureMove`. The implicit move-on-last-read already handles the `move()` function equivalent via the analyzer's `isLastReadSafe` check.

## Current State: COMPLETE — 100% Reference Parity

All 7 code paths in the analyzer (`src/analyzer/inject.ms`) handle MoveExpr correctly:

| Path | Function | Example | Status |
|------|----------|---------|--------|
| ~~Var decl~~ | ~~`processVarDecl`~~ | ~~`const y = move x;`~~ | ~~DONE~~ |
| ~~Assignment~~ | ~~`processAssignment`~~ | ~~`y = move x;`~~ | ~~DONE~~ |
| ~~Call args~~ | ~~`processCallArgs`~~ | ~~`f(move x)`~~ | ~~DONE~~ |
| ~~Member assign~~ | ~~`emitSaveAssignDestroy`~~ | ~~`obj.f = move x;`~~ | ~~DONE~~ |
| ~~Return~~ | ~~`markReturnedVarsMoved`~~ | ~~`return move x;`~~ | ~~DONE~~ |
| ~~Literal field~~ | ~~`emitLiteralFieldCopies`~~ | ~~`{ f: move x }`~~ | ~~DONE~~ |
| ~~Array element~~ | ~~`emitArrayElementCopies`~~ | ~~`[move x]`~~ | ~~DONE~~ |

Additional completions:
- ~~**checkExprPass.ms**: MoveExpr returns inner type + operand validation~~
- ~~**sinkFn optimization**: `makeSinkCall()` in inject.ms replaces `destroy+assign` with `sink(dest,src)`~~
- ~~**Inline sink**: `destructorLifting.ms` `=sink` bodies emit `destroy(field) + assign` instead of runtime `_sink()` calls~~

---

## ~~Phase 1: Core Identifier Move (Correctness Fix)~~

**Status: DONE.**

### What

Emit `wasMoved(source)` + `recordMoveInContext(source)` when `move x` is used and x is an identifier.

### Where (5 insertion points)

1. **`processVarDecl`** — before `isFreshExpr` check (line 543):
   - `const y = move x;` → SINK (no copy) + pending `wasMoved(x)` + recordMove
   - No aliasing concern (y is new)

2. **`processAssignment`** — before `isFreshExpr` check (line 694):
   - `y = move x;` → `destroy(y); y = x; wasMoved(x);`
   - Self-move `x = move x` → no-op

3. **`processCallArgs`** — after Identifier block (line 334):
   - `f(move x)` → pending `wasMoved(x)` after call + recordMove

4. **`emitSaveAssignDestroy`** — before `isFreshExpr` check (line 733):
   - `obj.f = move x;` → save old, assign, `wasMoved(x)`, destroy old

5. **`markReturnedVarsMoved`** — add MoveExpr case (line 933):
   - `return move x;` → unwrap moveArg, recurse on inner identifier

### New Code

- Import `MoveExprData` from `../ast/node`
- Central helper: `emitMoveSourceWasMoved(moveArg, rcInfo, idx, stmts, dctx, loc, checkLastRead)`
  - Identifier path: `addPending(wasMoved) + recordMoveInContext`
  - Returns true if handled, false for fresh sources (call expr)

### Tests

- `move identifier in var decl emits wasMoved`
- `move identifier in assignment emits wasMoved`
- `move call expr is fresh` (no wasMoved)
- `return move marks source moved`

### Production Compiler Equivalent

`moveOrCopy()` → detects `ensureMove`, strips wrapper → `genSink(dest, ri) + genWasMoved(ri)` for `nkSym` (symbol/identifier).

---

## ~~Phase 2: Field & Array Element Source~~

**Status: DONE.**

### What

When moveArg is `MemberExpr` or `ArrayAccess`, emit `wasMoved(expr)` on the field/element itself. The parent object/array stays alive; only the moved field/element is zeroed.

### New Helpers

```ms
// RC call on arbitrary expression (not just varName)
function makeWasMovedOnExpr(argExpr: Node, rcInfo: RcInfo, loc: SourceLocation): Node

// Classify field type from parent object type
function classifyMemberFieldRc(memberExpr: Node, dctx: DrcContext): RcInfo

// Classify element type from array type
function classifyArrayElementRc(arrayExpr: Node, dctx: DrcContext): RcInfo
```

These reuse the pattern from `needsReturnIncref` (inject.ms lines 860-887) which already walks object types to find field RC info.

### Integration

Add MemberExpr and ArrayAccess cases to `emitMoveSourceWasMoved`:
- MemberExpr: `classifyMemberFieldRc` → `addPending(makeWasMovedOnExpr)`
- ArrayAccess: `classifyArrayElementRc` → `addPending(makeWasMovedOnExpr)`

No `recordMoveInContext` — the parent variable isn't moved, just one field/element.

### Production Compiler Equivalent

`isAnalysableFieldAccess()` in `aliasanalysis.nim` — traverses field access chain to root symbol, verifies root is local (not global/cursor/regular-param). Then `genWasMoved(ri)` on the field expression.

---

## ~~Phase 3: Aliased Move Protection~~

**Status: DONE.**

### The Problem

```ms
y = move x;         // Non-aliased: destroy(y); y = x; wasMoved(x); — SAFE
x = move x.field;   // Aliased: destroy(x) destroys x.field BEFORE reading it!
```

### Solution: Capture Pattern

Production compiler's `destructiveMoveVar()` generates: `let tmp = v; wasMoved(v); tmp`

Our equivalent for `x = move x.field`:
```
const $moveTmp = x.field;     // 1. Capture field value
wasMoved(x.field);            // 2. Zero field (so destroy(x) won't touch it)
destroy(x);                   // 3. Safe destroy (field zeroed)
x = $moveTmp;                 // 4. Assign captured value
```

### Detection

Use existing `deepAliases(leftD.name, md.moveArg)` — returns true when RHS references the dest variable. Already works for MemberExpr and ArrayAccess (via `nodeReferencesVar`).

### Special Cases

- **Self-move** `x = move x` → no-op (production compiler: `nkEmpty`)
- **Aliased identifier** `x = move x` → caught by self-move check above
- **Non-aliased** → standard path (Phase 1)

### Production Compiler Equivalent

`destructiveMoveVar(n)` in `injectdestructors.nim`:
```nim
proc destructiveMoveVar(n: PNode; c: var Con; s: var Scope): PNode =
  result = nkStmtListExpr(n.info, n.typ)
  var temp = newSym(skLet, "blitTmp")
  result.add nkLetSection(nkIdentDefs(temp, empty, n))  # let tmp = n
  result.add c.genWasMoved(n)                            # wasMoved(n)
  result.add tempAsNode                                   # return tmp
```

Used inside `moveOrCopy()` when `aliases(dest, ri) != no`:
```nim
result = c.genSink(s, dest, destructiveMoveVar(ri, c, s), flags)
```

---

## ~~Phase 4: errFailedMove Diagnostic~~

**Status: DONE.**

### What

When `move x` is used but x is NOT last-read (used again later), emit a compile error:
`"cannot move 'x': variable is still used after this point"`

This catches bugs where the user expects ownership transfer but the variable is still referenced.

### Implementation

In `emitMoveSourceWasMoved`, for identifier sources:
```ms
if (checkLastRead && !isLastReadSafe(srcName, idx, stmts, dctx)) {
    addError(dctx.ctx.checkerCtx, "cannot move '" + srcName + "': ...");
}
```

Still emit wasMoved regardless (the user explicitly requested the move — honor it but warn).

Import `addError` from `../checker/context`.

### Contexts Where checkLastRead = false

- `emitSaveAssignDestroy`: no valid `idx`/`stmts` context available
- Literal fields/elements: same

### Production Compiler Equivalent

`inEnsureMove` counter in `Con` struct:
```nim
if ri[0].sym.magic == mEnsureMove:
    isEnsureMove = 1

inc c.inEnsureMove, isEnsureMove
result = c.genCopy(dest, ri, flags)  # genCopy checks: if c.inEnsureMove > 0 → errFailedMove
dec c.inEnsureMove, isEnsureMove
```

The error says: `"cannot move 'x', which introduces an implicit copy"`.

---

## Phase 5: First-Write Sink Optimization

**Priority: LOW** — Performance optimization, not correctness.

### What

Skip `destroy(old)` when assigning to a variable that was declared without an initializer (null-init). The variable is zeroed — destroying it is a no-op.

```ms
let x: string;      // x is null/zeroed
x = move y;          // No destroy(x) needed — first write
x = move z;          // NOW destroy(x) needed — second write
```

### Implementation

**`src/analyzer/scope.ms`**: Add `NullInitVars` tracking:
```ms
export interface NullInitVars { names: string[]; }
// Add to DrcContext, createDrcContext
// Functions: markNullInit, isNullInit, clearNullInit
```

**`src/analyzer/inject.ms`**:
- `processVarDecl`: when `d.initializer === null`, call `markNullInit(dctx, d.declName)`
- `processAssignment`: ALL RHS paths (MoveExpr, isFreshExpr, Identifier) check `isNullInit(dctx, leftD.name)` → skip destroy, then `clearNullInit`

### Production Compiler Equivalent

`genSink()` in `injectdestructors.nim`:
```nim
if (c.inLoopCond == 0 and (IsDecl in flags or
    (isAnalysableFieldAccess(dest, c.owner) and isFirstWrite(dest, c)))) or
    isNoInit(dest) or IsReturn in flags:
  result = newTree(nkFastAsgn, dest, ri)  # Bitwise copy, no destroy
```

`nkFastAsgn` = bitwise memcopy without calling `=destroy` on old value.

---

## ~~Phase 6: Literal Construction Moves~~

**Status: DONE.**

### What

When constructing object literals or arrays with `move` expressions as field/element values, emit `wasMoved(source)` + `recordMove` instead of `incref(field)`.

### Where

1. **`emitLiteralFieldCopies`** (line 380): Add MoveExpr case after Identifier check
2. **`emitArrayElementCopies`** (line 406): Add MoveExpr case after Identifier check

### Pattern

```ms
if (prop !== null && prop.kind === NodeKind.MoveExpr) {
    const md = prop.data as MoveExprData;
    if (md.moveArg.kind === NodeKind.Identifier) {
        // Force move: wasMoved on source, no incref on field
        addPending(dctx, makeWasMovedCall(srcName, fieldRc, loc));
        recordMove(dctx, srcName);
    }
    // Non-identifier moveArg in literal: fresh, no action needed
}
```

### Production Compiler Equivalent

Object/array construction in `moveOrCopy()` handles each field/element through the same `genSink + genWasMoved` path. No special literal-specific code — the general move handling covers it.

---

## Implementation Order

| Phase | Effort | Impact | Status |
|-------|--------|--------|--------|
| ~~1. Core identifier~~ | ~~80 lines~~ | ~~Fixes all double-free bugs~~ | ~~DONE~~ |
| ~~2. Field/array source~~ | ~~50 lines~~ | ~~Complete source type coverage~~ | ~~DONE~~ |
| ~~3. Aliased move~~ | ~~30 lines~~ | ~~Prevents use-after-free edge case~~ | ~~DONE~~ |
| ~~4. errFailedMove~~ | ~~10 lines~~ | ~~Developer experience~~ | ~~DONE~~ |
| 5. First-write sink | ~40+20 lines | Performance optimization | Deferred (DRC gotcha #18) |
| ~~6. Literal moves~~ | ~~20 lines~~ | ~~Complete literal coverage~~ | ~~DONE~~ |

## Files Modified

| File | Phases | Changes |
|------|--------|---------|
| `src/analyzer/inject.ms` | 1-4, 6 | MoveExpr handling in 7 functions, new helpers, tests |
| `src/analyzer/scope.ms` | 5 | NullInitVars tracking (interface + 3 functions) |
| `docs/CODEGEN-GAP.md` | All | Mark Gap 15 as DONE |
