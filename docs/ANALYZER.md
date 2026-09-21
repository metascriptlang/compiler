# ANALYZER — Phase 4, DRC injection

Deterministic reference counting for the C backend. `analyzeProgram(program, checkerCtx)` (`src/analyzer/index.ms`) walks the post-transform AST, inserts the lifecycle calls `=destroy`, `=copy`, `=sink`, `=wasMoved` and then removes the redundant ones: `injectProgram` → `optimizeDrc`. The design is a direct AST rewrite with scope-based cleanup and a conservative last-read analysis. The rules a change must hold are in [`src/analyzer/CLAUDE.md`](../src/analyzer/CLAUDE.md); where Phase 4 sits is in [`PIPELINE.md`](PIPELINE.md).

## Three stages

| Stage | Where | Does | Does not |
|-------|-------|------|----------|
| Hook lifting | `src/transform/lowering/destructorLifting.ms` | generates the per-type lifecycle hooks | decide when or where they are called |
| Injection | `inject.ms` with `classify.ms`, `scope.ms`, `lastRead.ms`, `cfg.ms`, `alias.ms`, `cursors.ms` | inserts the calls at the right AST positions | generate hook bodies, optimize |
| Optimization | `optimize.ms` | removes redundant operations | restructure code, add operations |

## What the injector sees

Earlier phases have already removed `defer`, `match` expressions, `try` expressions, `?.`, `??` and destructuring: `inject.ms` has no case for them. It does have cases for `ForStmt`, `ForOfStmt`, `MatchStmt`, `SwitchStmt` and `ArrowFunction`, so a description of Phase 4 input as "everything lowered to `while` and `if`" does not match the code.

## The decision at an assignment — `moveOrCopy` (`inject.ms`)

In this order:

1. The type needs no cleanup → the statement is left alone.
2. Destination and source are the same location → left alone.
3. The destination is a cursor (a borrow inferred by `cursors.ms`) → no RC.
4. Otherwise by the kind of the right-hand side:
   - **Call** — at a declaration the result is taken as is (SINK). At a reassignment, String and Named values hoist the result into a temp and call the sink hook (or the copy hook when the type has no sink), then `wasMoved` on the temp; Ref and Closure go through `genSink`: save old, assign, destroy old.
   - **Literal, `new`, arrow or function expression** — SINK.
   - **`move x`** — self-move is a no-op; a move that aliases the destination (`x = move x.field`) captures to a temp, zeroes the source, destroys the old destination, assigns from the temp; any other move is `wasMoved` on the source plus SINK.
   - **Identifier** — MOVE (`genSink` + `wasMoved`) when this is the last read of its symbol, else COPY.
   - **Member, index or hidden deref** — MOVE when the source owns the field, the type has a `wasMoved` hook and this is the field's last read; else COPY.
   - **Conditional** — becomes an `if` whose branches are each decided on their own where the arm can; else COPY.
   - **Anything else** — COPY.

At sink and return materialization points `sinkClassify` classifies a `Ptr<T>` whose pointee is a counted Ref as the pointee, so it is COPIED (incref) and the owning destination's decref stays balanced. A `Ptr` variable holds a borrow and is never moved into an owning slot; a `Ptr` to a non-Ref pointee (malloc, FFI) is untouched.

## Insertion points

| Context | What happens |
|---------|-------------|
| `const x = fresh()` | SINK — ownership transfer, no copy |
| `const x = y` | MOVE on the last read of `y` (assign + `wasMoved(y)`), else COPY |
| `const x = obj.field` | COPY, or a field-level MOVE under the conditions above |
| `x = …` (reassignment) | destroy the old value, then as for a declaration; a first write to an uninitialized `let x;` skips the destroy |
| `x = f(x)` (self-alias) | save old in a temp, assign, destroy the temp |
| `obj.field = expr`, `arr[i] = expr` | save the old slot, assign, destroy the old value |
| `x += y` on an RC type | save old, compute, assign, destroy old |
| `{ field: rcVar }`, `[a, b, c]` | incref or copy each RC field or element |
| `f(rcVar)` | incref before the call when it is not the last read, `wasMoved` after when it is; a `sink` parameter consumes its argument |
| `return expr` | returned variables are marked moved and excluded from cleanup |
| Scope exit | destroy the tracked variables in LIFO order |
| `break` / `continue` | cleanup runs up to the loop boundary |
| `throw` | marks `needsTry` on the enclosing scopes |
| Discarded `f()` result | captured in a temp and registered for cleanup |
| Variable read inside a `finally` | protected: never moved out before the `finally` runs |
| `__envP*` parameters | skipped — the closure machinery owns them |
| Generator state body | `needsTry` is forced off — no try/finally wrapper |

## Scope cleanup — `generateCleanup` (`inject.ms`)

1. Emit the pending `wasMoved` expressions of the scope.
2. Walk the tracked variables in reverse. Skip a cursor, a name in the exclude set (the returned expression), a type with no destroy hook. Emit `destroy` for the rest.
3. When the scope needs a `try` and the cleanup is not empty: hoist each RC declaration before the `try` with a null initializer, turn the original initializer into an assignment inside it, and wrap `try { body } finally { cleanup }`.

A moved variable still gets its `destroy` here; the optimizer removes it.

## Post-optimization — `optimizeDrc` (`optimize.ms`)

Per block it keeps the set of variables that are definitely moved: `wasMoved(x)` adds `x`; a later `destroy(x)` on a member of the set is dropped, adjacent or not; an `if` with an `else` contributes the intersection of its branches (`collectIfMoved`, `symListIntersect`); sub-blocks are walked recursively. A call is a `wasMoved` or `destroy` when its callee symbol carries `SymbolFlag.WasMovedOp` or `DestroyOp` — stamped where the op symbol is minted: `markLifecycleOp` in `destructorLifting.ms` for generated hooks, `opRef` in `transform/util.ms` for runtime ops — and variables are matched by symbol identity. Measured 2026-09-21: the self-host build and 223 corpus programs emit byte-identical C to the name-matching optimizer it replaced (119 destroys removed, all on runtime ops).

## Type classification

`classify.ms` maps a `Type` to an `RcInfo` — the RC kind plus the names of its destroy, copy, wasMoved and sink hooks; `isFreshExpr` decides what counts as a fresh value. The hook names per type are read from that file, not from a table here.

## Not verified here

- The decision list and the cleanup steps are read from `moveOrCopy` and `generateCleanup`; the rows of "Insertion points" are carried over from the earlier text with three corrections from the code (field-level move, conditional, `sink` parameter). No row was confirmed by emitting C.
- Which control kinds reach the analyzer, measured 2026-09-20 with a probe compiler that printed the kind at the top of `processStmt`: over corpus programs 000–307 (51 programs) and a program with `for`, `for..of` and an integer `match`, `ForStmt`, `ForOfStmt` and `MatchStmt` never arrived; `SwitchStmt` arrived about 380 times per program from std plus once for the integer `match` — the match engine emits it for ordinal discriminants and `switchLower` keeps ordinal user switches. So `processSwitch` is live, while `processFor` and the `ForStmt`/`ForOfStmt`/`MatchStmt` arms of `scanFinallyBlocks` were unreached on that set; they were not removed. Not measured: the other 169 corpus programs and the self-host build.
- `cfg.ms` builds one control-flow graph per root symbol per function, cached by symbol identity; a last-read query finds its use by node identity and walks forward with the `alias.ms` checks, for whole variables and field paths alike. Measured 2026-09-21 against the name-keyed graph it replaced: of 44 700 whole-variable queries (self-host + 223 corpus programs) 588 changed, all from copy to move, and in none of them was the blocking later use an identifier without a symbol or with another symbol: in 362 every later use was of the same symbol (the two graphs differ in defs or reachability, not in which identifiers count as uses), and 224 were queries the old graph could not find at all (222 of them `postBytes`, whose identifier is renamed away from its symbol). Not verified: which def or edge separates them in the 362. `alias.ms` (path aliasing) and `cursors.ms` (borrow inference with live ranges and mutation tracking) are named, not described: their internals were not read in this pass.
