# Transform Architecture

Phase 3 of the compilation pipeline. Rewrites the typed AST before codegen.

```
Phase 2 (typed AST) --> [General Transforms] --> [C-Backend Transforms] --> Phase 4 (Analyzer)
```

## Infrastructure

### Walker Modes (`src/transform/walker.ms`)

| Mode | Function | Use Case |
|------|----------|----------|
| **1:1 visitor** | `walkNode(node, visitor)` | Bottom-up: recurse children, then transform node. For coercions, folding. |
| **1:N expansion** | `walkBlockExpanding(stmts, expander)` | Statement list expansion. One stmt becomes N stmts. |
| **Block-expanding walk** | `walkExpandBlocks(node, expander, ctx)` | Combines 1:N expansion with recursive descent into function bodies/blocks. |

### Shared Context (`src/transform/context.ms`)

```
TransformContext { tempCounter, errors[], fnDeclNames[] }
```

- `freshTemp(ctx, prefix)` generates `$prefix_N` unique names
- `fnDeclNames` collected by closureCallMarker for C codegen

### Utilities (`src/transform/util.ms`)

Node builders: `makeIdent`, `makeNull`, `makeNumber`, `makeString`, `makeBool`, `makeBlock`, `makeVarDecl`, `makeExprStmt`, `makeReturn`, `makeIf`, `makeWhile`, `makeTryCatch`, `makeContinue`, `makeBinary`, `makeUnary`, `makeCall`, `makeMember`, `makeConditional`, `makeAssign`, `makeArrayAccess`, `makeSwitch`, `makeSwitchCase`, `makeFnDecl`, `makeInterfaceDecl`, `makeObjectLiteral`.

`evalOnce(expr, ctx, loc)` — capture expression in temp variable, returns `{ decl, ref }`.
`extractBodyStmts(body)` — unwrap BlockStmt to statement array.

---

## Implemented Transforms (24)

### General Pipeline (`src/transform/index.ms`)

Fixed order. Each may depend on results of earlier ones.

| # | Transform | File | Strategy | What It Does |
|---|-----------|------|----------|-------------|
| 1 | deferLower | `lowering/deferLower.ms` | 1:N expand | `defer f()` → try/finally wrapping |
| 2 | constantFolding | `coercion/constantFolding.ms` | 1:1 visitor | `2+3` → `5`, `"a"+"b"` → `"ab"`, `!true` → `false` |
| 3 | stringConcatFlatten | `coercion/stringConcatFlatten.ms` | 1:1 visitor | `"a" + x + "b"` → `ms_string_concat("a", x, "b")` |
| 4 | optionalChain | `coercion/optionalChain.ms` | 1:1 visitor | `a?.b` → `a != null ? a.b : null` |
| 5 | nullishCoalesce | `coercion/nullishCoalesce.ms` | 1:1 visitor | `x ?? 42` → `x != null ? x : 42` |
| 6 | typeCoercion | `coercion/typeCoercion.ms` | 1:1 visitor | `String(x)` → `x.toString()` |
| 7 | stringTruthiness | `coercion/stringTruthiness.ms` | 1:1 visitor | `if (str)` → `if (str.length > 0)` |
| 8 | destructuringLower | `desugar/destructuringLower.ms` | 1:N expand | `const [a,b] = f()` → temp + indexed access |
| 9 | spreadExpand | `desugar/spreadExpand.ms` | 1:1 visitor | `fn(...[a,b])` → `fn(a,b)` (array literal inline) |
| 10 | forLoopLower | `lowering/forLoopLower.ms` | 1:1 visitor | `for(init;cond;upd)` → `{ init; while(cond) { body; upd; } }` |
| 11 | forOfLower | `lowering/forOfLower.ms` | 1:N expand | `for (x of arr)` → while loop with iterator |
| 12 | resultDesugar | `desugar/resultDesugar.ms` | 1:N expand | `const x = try f` → result check + value extract |
| 13 | resultFieldCheck | `desugar/resultFieldCheck.ms` | 1:1 visitor | `$result_N.value` → `{ check(r); r.value; }` |
| 14 | matchLower | `lowering/matchLower.ms` | 1:N expand | `match (x) { ... }` → if/else chain |
| 15 | tailCallLower | `lowering/tailCallLower.ms` | 1:1 visitor | Tail-recursive calls → while loop with param reassign |
| 16 | asyncDesugar | `lowering/asyncDesugar.ms` | custom walk | `await` → `yield`, flip async → generator flag |
| 17 | generatorLower | `lowering/generatorLower.ms` | custom walk | `function*` → state machine returning iterator object |
| 18 | lambdaLifting | `lowering/lambdaLifting.ms` | custom walk | Closures with captures → lifted functions + env structs |
| 19 | dce | `analysis/dce.ms` | stub | Dead code elimination (stub: all symbols alive) |
| 20 | destructorLifting | `lowering/destructorLifting.ms` | custom walk | Generate per-type `_destroy`/`_copy` from field types |

### C-Backend Pipeline (`src/transform/c/index.ms`)

Run after general transforms, only for C target.

| # | Transform | File | What It Does |
|---|-----------|------|-------------|
| 1 | closureCallMarker | `c/closureCallMarker.ms` | Collect function names into ctx.fnDeclNames |
| 2 | pointerParam | `c/pointerParam.ms` | Exports `isPrimitiveTypeName` for C codegen |
| 3 | rangeCheckInject | `c/rangeCheckInject.ms` | Exports `makeRangeCheck` helper for C codegen |
| 4 | optionalCoercion | `c/optionalCoercion.ms` | `return null` → `return ms_optional_null()` for T|null fns |

---

## Pending Transforms: Architecture

Two transforms are deferred. This section defines their architecture based on Nim's proven patterns, adapted for MetaScript's self-hosted context.

### 1. Dead Code Elimination (DCE)

**What**: Compute the set of "alive" symbols so codegen can skip dead code.

**Nim reference**: `ic/dce.nim` (169 LOC). NOT an AST transform — it's an analysis pass that produces an `AliveSyms` set. Codegen queries `isAlive()` to skip dead symbols.

**MetaScript reference**: `dce.zig` (990 LOC). Same architecture but more complex due to string-based module system and lifecycle hook proactive marking.

#### Algorithm (Nim-aligned: worklist marking)

1. **Seed**: Walk all top-level code in all modules. Mark `main()`, exports, `@runtime` functions.
2. **Worklist**: For each alive symbol, walk its body. Any symbol it references → add to worklist.
3. **Cross-module**: When module A references a symbol from module B, follow the reference and mark it alive in B.
4. **Lifecycle hooks**: Mark ALL `_destroy`/`_copy`/`_was_moved` functions alive proactively (analyzer injection creates calls to them AFTER DCE runs).

#### Self-Hosted Design Decisions

- **NOT an AST transform**. Output is `AliveSyms: Set<string>` (or `Map<modulePath, Set<symbolName>>`). Codegen checks `isAlive(module, symbol)` before emitting.
- **Runs after all transforms, before codegen**. Sees the final AST.
- **Requires cross-module module graph**: Needs to follow imports/exports across modules. Deferred until multi-module pipeline lands.
- **Conservative for single-module**: For now, mark everything alive (no dead code in single file). DCE becomes valuable only with multi-module.

#### Dependencies

- **Requires**: Multi-module loading pipeline
- **Before**: Codegen (codegen queries alive set)
- **Independent of**: Analyzer (runs before analyzer, proactively marks lifecycle hooks)

#### Estimated Scope

Single-module stub: ~20 LOC (everything alive). Multi-module: ~200 LOC (worklist + cross-module tracking). Total with lifecycle proactive marking: ~300 LOC.

---

### 2. evalOnce / Rvalue Lowering

**What**: Prevent double-evaluation of expressions with side effects.

**Nim reference**: `lowerings.nim:evalOnce` (15 LOC). NOT a standalone pass — it's a utility function called ad-hoc by other transforms.

```
// Input (inside optionalChain transform):
a.b?.c.d
// Naive lowering would evaluate a.b twice:
a.b !== null ? a.b.c.d : null
// With evalOnce:
const $tmp = a.b; $tmp !== null ? $tmp.c.d : null
```

#### Self-Hosted Design Decision

**NOT a standalone transform pass**. It's a utility function in `transform/util.ms`:

```typescript
// Already partially implemented as freshTemp + makeVarDecl pattern.
// Formalize as:
export function evalOnce(expr: Node, ctx: TransformContext, loc: SourceLocation): { temp: Node, decl: Node } {
    const name = freshTemp(ctx, "tmp");
    return {
        temp: makeIdent(name, loc),
        decl: makeVarDecl(name, expr, true, loc),
    };
}
```

Transforms that need it (`optionalChain`, `destructuringLower`, `matchLower`) already use the `freshTemp + makeVarDecl` pattern manually. Formalizing into `evalOnce` is a DRY cleanup, not new functionality.

#### Estimated Scope

~10 LOC utility function. Used by 3+ existing transforms.

---

## Phase Dependencies

### Execution Order

```
                    ┌── General Transforms (20) ──────────┐
Phase 2             │  1-15. (see table above)             │
(typed AST)    ───► │  16. asyncDesugar ✓                  │
                    │  17. generatorLower ✓                │
                    │  18. lambdaLifting ✓                  │
                    │  19. dce (stub) ✓                     │
                    │  20. destructorLifting ✓              │
                    └──────────────┬───────────────────────┘
                                   │
                    ┌── C-Backend (4) ──┐
                    │  closureCallMarker │
                    │  pointerParam      │  ◄── C target only
                    │  rangeCheckInject  │
                    │  optionalCoercion  │
                    └────────┬──────────┘
                             │
              Phase 4: Analyzer       ◄── needs destructor hooks + alive set
                             │
              Phase 5: Codegen        ◄── reads AliveSyms, calls isPrimitiveTypeName, etc.
```

### What Phase 4 (Analyzer) Needs From Phase 3

| Requirement | Transform | Status |
|------------|-----------|--------|
| All defer → try/finally | deferLower | Done |
| All for → while | forLoopLower, forOfLower | Done |
| All match → if/else | matchLower | Done |
| All destructuring → explicit accesses | destructuringLower | Done |
| All try expressions → result checks | resultDesugar | Done |
| Closures converted to (fn, env) pairs | lambdaLifting | Done |
| Per-type _destroy/_copy bodies | destructorLifting | Done |
| Alive symbol set (for proactive marking) | DCE | Done (stub: all alive) |
| Generators desugared to state machines | generatorLower | Done |

### What Phase 5 (Codegen) Needs

| Requirement | Source | Status |
|------------|--------|--------|
| Function name list (closure vs direct call) | closureCallMarker | Done |
| Primitive type check utility | pointerParam | Done |
| Range check helper | rangeCheckInject | Done |
| Optional null coercion | optionalCoercion | Done |
| Alive symbol set | DCE | Done (stub) |

---

## Skipped Transforms (with rationale)

Compared against Nim's `transf.nim` which has only 7 essential transforms. These reference compiler transforms are overkill:

| Transform | Reason |
|-----------|--------|
| recordToMap | No `Record<K,V>` type in MetaScript |
| dateLower | Too specialized — one type doesn't justify a transform |
| subscriptLower | Needs custom `[]` infrastructure we don't have |
| methodCallLower | UFCS — Nim handles in semantic phase, not transforms |
| arrayMethodInline | Needs type info for correctness, marginal benefit |
| astValidator | Defensive — better to fix transforms than add post-validation |

---

## Implementation Priority

Based on Phase 4 requirements and dependencies:

1. ~~**evalOnce utility**~~ — Done. 10 LOC in `util.ms`.
2. ~~**Lambda lifting**~~ — Done. ~835 LOC in `lowering/lambdaLifting.ms`. Single-pass detect+lift with ScopeStack, 8 tests.
3. ~~**Generator**~~ — Done. ~500 LOC in `lowering/generatorLower.ms`. State machine with yield splitting, while/if handling, 8 tests.
4. ~~**DCE stub**~~ — Done. ~60 LOC in `analysis/dce.ms`. AliveSyms API, stub passthrough, 3 tests.
5. ~~**Async**~~ — Done. ~200 LOC in `lowering/asyncDesugar.ms`. Thin transform: `await` → `yield`, flip async → generator. 6 tests.
6. ~~**Destructor lifting**~~ — Done. ~250 LOC in `lowering/destructorLifting.ms`. Per-type `_destroy`/`_copy` generation from field types with cycle detection, 7 tests. Unblocked by threading CheckerContext through transform pipeline.
