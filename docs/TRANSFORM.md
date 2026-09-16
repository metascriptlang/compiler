# Transform Architecture

Phase 3 of the compilation pipeline. Rewrites the typed AST before the analyzer + codegen.

```
Phase 2 (typed AST) --> [ one ordered transform pipeline, per-step backend flags ] --> Phase 4 (Analyzer)
```

The pipeline is a single fixed-order sequence in `src/transform/index.ms` (`transformProgram`).
Each step is gated for the active backend — many lowerings are C/Raiser-only because the JS backend
keeps high-level constructs native (`class`, `for..of`, ternary, etc.). The authoritative order +
backend gating is the `result = lowerXxx(result, ctx)` sequence in `index.ms` — this doc tracks it;
if they disagree, **`index.ms` wins**.

---

## Infrastructure

### Walker Modes (`src/transform/walker.ms`)

| Mode | Function | Use Case |
|------|----------|----------|
| 1:1 visitor | `walkNode(node, visitor)` | Bottom-up: recurse children, then transform node. Coercions, folding. |
| Children-only | `walkChildren(node, visitor)` | Recurse into children without transforming the node itself. |
| 1:N expansion | `walkBlockExpanding(stmts, expander)` | Statement-list expansion — one stmt becomes N stmts. |
| Block-expanding walk | `walkExpandBlocks(node, expander, ctx)` | 1:N expansion + recursive descent into function bodies/blocks. |
| Hooked block walk | `walkExpandBlocksHooked(node, expander, ctx, hook)` | `walkExpandBlocks` with an enter/exit hook (scope tracking). |

### Shared Context (`src/transform/context.ms`)

```
TransformContext { tempCounter, errors[], fnDeclNames[], jsBackend, keepBuiltinMemberCalls }
```

- `createTransformContextWithChecker(checkerCtx)` — build a context carrying the checker results.
- `freshTemp(ctx, prefix)` — generate `$prefix_N` unique names.
- `fnDeclNames` — collected by `closureCallMarker` for C codegen (closure vs direct call).
- `keepBuiltinMemberCalls` — backends that resolve builtins natively (Raiser's opcodes for
  `arr.push`/`console.*`/etc.) set this true so `extensionMethodLower` leaves those as member calls;
  mangled-name backends (C) keep it false and rewrite to direct calls. **Shared lowerings must gate on
  a capability flag like this, not a backend name** — a new backend just sets the flag, and a
  Raiser-only skip never silently breaks the C pipeline (which is exactly what happened when the skip
  was ungated).

### Utilities (`src/transform/util.ms`)

Node builders: `makeIdent` / `makeTypedIdent` / `makeIdentResolved`, `makeNull`, `makeNumber`,
`makeString`, `makeBool`, `makeDefaultValue`, `makeBlock`, `makeVarDecl`, `makeExprStmt`,
`makeReturn`, `makeIf`, `makeWhile`, `makeTryCatch`, `makeContinue`, `makeBreak`, `makeBinary`,
`makeUnary`, `makeMoveExpr`, `makeCall` / `makeCallResolved`, `makeMember`, `makeConditional`,
`makeAssign`, `makeArrayAccess`, `makeSwitch` / `makeSwitchCase`, `makeFnDecl`,
`makeInterfaceDeclFromTypes`, `makeObjectLiteral` / `makeTypedObjectLiteral`, and the C-backend
hidden-node builders `makeHiddenAddr` / `makeHiddenDeref` / `makeHiddenStdConv` / `makeHiddenSubConv`.

- `evalOnce(expr, ctx, loc)` — capture an expression in a temp (`{ decl, ref }`) to prevent
  double-evaluation. Used by `optionalChain`, `destructuringLower`, `matchLower`, etc.
- `extractBodyStmts(body)` — unwrap a `BlockStmt` to a statement array.

### Folders

```
src/transform/
  index.ms              -- the ordered pipeline (transformProgram)
  walker.ms context.ms util.ms
  coercion/             -- type/operator coercions (fold, optional chain, truthiness, ...)
  desugar/              -- syntactic sugar removal (destructuring, spread, result, ...)
  lowering/             -- high-level → low-level (for, match, async, actor, closures, ...)
  analysis/             -- non-rewriting analyses (dce)
  native/               -- C/Raiser emission helpers (builtins, cstring, span params, ...)
```

---

## Transform Pipeline (43)

Order is the exact `index.ms` sequence. **Backend**: `both` / `C` (C + Raiser, i.e. `!jsBackend`) /
`JS`.

| # | Transform | File | Backend | What It Does |
|---|-----------|------|---------|-------------|
| 1 | powerAssert | `powerAssert.ms` | JS | `assert(x === y)` → rewritten to report operand values on failure |
| 2 | deferLower | `lowering/deferLower.ms` | both | `defer f()` → try/finally wrapping (LIFO at scope exit) |
| 3 | constantFolding | `coercion/constantFolding.ms` | both | `2+3`→`5`, `"a"+"b"`→`"ab"`, `!true`→`false` |
| 4 | stringConcatFlatten | `coercion/stringConcatFlatten.ms` | both | `"a"+x+"b"` → single `ms_string_concat(...)` chain |
| 5 | optionalChain | `coercion/optionalChain.ms` | both | `a?.b` → `a != null ? a.b : null` |
| 6 | nullishCoalesce | `coercion/nullishCoalesce.ms` | both | `x ?? y` → `x != null ? x : y` |
| 7 | stringTruthiness | `coercion/stringTruthiness.ms` | both | `if (str)` → `if (str.length > 0)` |
| 8 | restParamLower | `lowering/restParamLower.ms` | both | rest param `...args` → call-site varargs array packing |
| 9 | destructuringLower | `desugar/destructuringLower.ms` | both | `const [a,b] = f()` → temp + indexed access |
| 10 | spreadExpand | `desugar/spreadExpand.ms` | both | `fn(...[a,b])` → `fn(a,b)` (array-literal spread inline) |
| 11 | arrayMethodInline | `desugar/arrayMethodInline.ms` | C | `arr.map/filter/reduce` → inline `while` loops |
| 12 | forLoopLower | `lowering/forLoopLower.ms` | C | `for(init;cond;upd)` → `{ init; while(cond){ body; upd; } }` |
| 13 | forOfLower | `lowering/forOfLower.ms` | C | `for (x of arr)` → `while` + iterator |
| 14 | resultDesugar (tryExpr) | `desugar/resultDesugar.ms` | C | `const x = try f` → result check + value extraction |
| 15 | resultConstructors | `desugar/resultDesugar.ms` | JS | `Result.ok()/err()` constructor shaping for JS |
| 16 | resultFieldCheck | `desugar/resultFieldCheck.ms` | JS | `$r.value/.error` → checked access (C skips — BlockStmt invalid in C expr position) |
| 17 | matchLower | `lowering/matchLower.ms` | both | `match (x) { ... }` → if/else chain |
| 18 | tailCallLower | `lowering/tailCallLower.ms` | both | self-tail-recursion → `while (1)` + loop-carried locals (`__tcp_N`) + `continue`; JS included — no engine but JSC has proper tail calls; covers return-position ternary/`&&`/`\|\|`/match and final-class (`OpenClass`-gated) methods; scanner+transformer share `tailOpaque` (TryCatch/Defer/fn-boundary only) and default-recurse; tail calls inside loops continue the labeled wrapper `__tcl`; const-bound arrows/function-exprs lower like declarations (guards 633-641) |
| 18b | paramReassignLower | `lowering/paramReassignLower.ms` | C | assigned params → owned shadow local (`__prs_N`); params are borrowed slots the analyzer never destroys |
| 19 | actorPre | `lowering/actorLower.ms` | C | actor pre-pass: extract async actor methods, set `methodFlags` |
| 20 | spawnGroupLower | `lowering/spawnGroupLower.ms` | C | `await Promise.all([spawn(f),spawn(g)])` → N-slot AwaitGroup |
| 21 | asyncDesugar | `lowering/asyncDesugar.ms` | C | `await` → `yield`; flip `async` → generator flag |
| 22 | asyncBridge | `lowering/asyncBridge.ms` | C | async functions → return `msFuture*` |
| 23 | generatorLower | `lowering/generatorLower.ms` | C | `function*` → state-machine iterator object |
| 24 | spawnLower | `lowering/spawnLower.ms` | C | box return values inside spawn closures |
| 25 | awaitLower | `lowering/awaitLower.ms` | C | sync-context `await` → typed future read or AwaitGroup |
| 26 | actorLower | `lowering/actorLower.ms` | C | `actor {}` → `msActorCreate`/`Register`/dispatch infrastructure |
| 27 | varHoist | `lowering/varHoist.ms` | C | hoist `var` decls to function-scope top (JS hoisting semantics in C) |
| 28 | extensionMethodLower | `lowering/extensionMethodLower.ms` | both | `obj.method(args)` → `method(obj, args)` (UFCS) |
| 29 | methodToFunction | `lowering/methodToFunction.ms` | C | class/actor methods → top-level `FunctionDecl` (uniform codegen shape) |
| 30 | lambdaLifting | `lowering/lambdaLifting.ms` | C | closures with captures → lifted functions + env structs |
| 31 | callHoist | `lowering/callHoist.ms` | C | hoist a fresh RC-returning call out of a non-RC binding so the analyzer cleans it |
| 32 | builtinLower | `native/builtinLower.ms` | both | `@builtin` calls + MemberExpr → direct call for extension methods |
| 33 | cstringConvLower | `native/cstringConvLower.ms` | both | cstring conversion — C emits `ms*` helpers, JS emits `toJSStr`/`fromJSStr` |
| 34 | operatorLower | `lowering/operatorLower.ms` | both | binary ops → function calls when an operator overload exists |
| 35 | stringOpLower | `native/stringOpLower.ms` | both | string operators → runtime function calls |
| 36 | subscriptLower | `lowering/subscriptLower.ms` | both | custom `obj[idx]` → `` `[]`(obj, idx) `` |
| 37 | spanLower | `lowering/spanLower.ms` | C | `HiddenStdConv` (Array → Span) → explicit struct initializers |
| 38 | spanParamExpand | `native/spanParamExpand.ms` | C | expand `Span<T>` params into `(ptr, len)` at call/decl sites |
| 39 | conditionalExprLower | `lowering/conditionalExprLower.ms` | C | ternary in statement position → if/else |
| 40 | updateExprLower | `lowering/updateExprLower.ms` | C | `x++` / `--x` in statement position → assignment |
| 41 | nullableLower | `native/nullableLower.ms` | C | `Maybe<T>` structural rewrites |
| 42 | dce | `analysis/dce.ms` | both | dead-code elimination — alive-symbol set (single-module stub: all alive) |
| 43 | liftDestructors | `lowering/destructorLifting.ms` | C | per-type `_destroy`/`_copy`/`_sink`/`_wasMoved` generated from field types (cycle-aware) |

> `dce` and `liftDestructors` are not AST rewrites in the usual sense — `dce` produces an
> alive-symbol set the codegen queries; `liftDestructors` emits per-type lifecycle hook functions
> the Phase-4 analyzer wires up.

---

## What Phase 4 (Analyzer) needs from Phase 3

The analyzer (DRC injection) assumes these lowerings have already run:

| Requirement | Transform |
|------------|-----------|
| `defer` → try/finally | deferLower |
| all `for` → `while` | forLoopLower, forOfLower |
| `match` → if/else | matchLower |
| destructuring → explicit accesses | destructuringLower |
| `try` expressions → result checks | resultDesugar |
| `async`/`await`/generators → state machines | asyncDesugar, generatorLower, asyncBridge, awaitLower |
| actors → dispatch + suspend infra | actorPre, actorLower |
| closures → (fn, env) pairs | lambdaLifting |
| fresh RC calls hoisted into analysable position | callHoist |
| per-type `_destroy`/`_copy`/`_sink` hook bodies | liftDestructors |

## What Phase 5 (Codegen) needs from Phase 3

| Requirement | Source |
|------------|--------|
| function-name list (closure vs direct call) | closureCallMarker / `ctx.fnDeclNames` |
| primitive-type check, range-check, optional-null helpers | `native/` emission helpers |
| span params expanded to `(ptr, len)` | spanParamExpand |
| alive-symbol set | dce |

---

## Skipped Transforms (with rationale)

Other compilers carry transforms MetaScript deliberately does NOT:

| Transform | Reason |
|-----------|--------|
| recordToMap | No `Record<K,V>` type in MetaScript |
| dateLower | Too specialized — one type doesn't justify a transform |
| astValidator | Defensive post-pass — better to fix transforms than validate after them |

(Earlier-skipped `subscriptLower`, `arrayMethodInline`, and method-call lowering have since been
implemented — see the pipeline table above.)
