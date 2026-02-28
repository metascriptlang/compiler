# Fix Workarounds — NodeData Copy Bugs (Now Fixed in Reference Compiler)

Catalog of workarounds in the self-hosted compiler for reference compiler codegen bugs related to NodeData copying. Each case: what the workaround is, where it lives, what the fix looks like.

---

## Case 1: Loop-var value copy — analyzer/optimize.ms

**Issue:** #15 — `const d = loopVar.data as XData` inside `for..of` generates VALUE COPY (`const struct`), not pointer. Mutations to `d` don't propagate.

**File:** `src/analyzer/optimize.ms:230-249`

**Workaround:** Three helper functions extracted from the `walkOptimize` match arms so `node` is a function parameter (generates pointer access) instead of a loop variable:

```ms
// line 230
function walkOptimizeSwitchCase(caseNode: Node): void {
    const d = caseNode.data as SwitchCaseData;  // pointer (param)
    d.caseStmts = optimizeBlock(d.caseStmts);
    ...
}
function walkOptimizeMethod(member: Node): void {
    const md = member.data as MethodDeclData;    // pointer (param)
    walkOptimize(md.methodBody);
}
function walkOptimizeCtor(member: Node): void {
    const cd = member.data as ConstructorDeclData; // pointer (param)
    walkOptimize(cd.ctorBody);
}
```

**Fix:** Inline the casts back into the match arms at lines 219-225. Remove the three helper functions.

```ms
// Before (workaround):
NodeKind.SwitchCase => { walkOptimizeSwitchCase(node); },
NodeKind.MethodDecl => { walkOptimizeMethod(node); },
NodeKind.ConstructorDecl => { walkOptimizeCtor(node); },

// After (direct):
NodeKind.SwitchCase => {
    const d = node.data as SwitchCaseData;
    d.caseStmts = optimizeBlock(d.caseStmts);
    let i = 0;
    while (i < d.caseStmts.length) { walkOptimize(d.caseStmts[i]); i += 1; }
},
NodeKind.MethodDecl => { walkOptimize((node.data as MethodDeclData).methodBody); },
NodeKind.ConstructorDecl => { walkOptimize((node.data as ConstructorDeclData).ctorBody); },
```

---

## Case 2: Loop-var value copy — raiser/module.ms

**Issue:** #15 — Same loop-var vs param codegen bug.

**File:** `src/raiser/module.ms:64-95`

**Workaround:** 7 accessor functions (`getFuncName`, `getFuncCodeLen`, `getFuncConstLen`, `getFuncInst`, `getFuncConst`, `getModuleFunc`, `getModuleEntry`) that take `RaiserFunction`/`RaiserModule` as parameter instead of accessing fields on loop variables.

```ms
// line 68
export function getFuncName(func: RaiserFunction): string { return func.name; }
export function getFuncCodeLen(func: RaiserFunction): number { return func.code.items.length; }
export function getFuncInst(func: RaiserFunction, idx: number): RaiserInstruction { ... }
// etc.
```

**Fix:** Callers can access fields directly on loop variables or local variables without the accessor indirection. Search all call sites first — these may be used from other files (cross-module, so check import sites).

---

## Case 3: ms_clone breaks with for..of over Node[] — monomorphize/collect.ms

**Issue:** #18 — Adding fields to NodeData union causes `for..of` over `Node[]` to emit broken `ms_clone` calls. Workaround: use `while` loops with index access.

**File:** `src/monomorphize/collect.ms` — ~15 while-loops across two walkers

**Workaround locations:**

### monoRewriteNode walker (lines 712-939):
- Line 738: `while (i < d.programStmts.length)` — Program
- Line 744: `while (i < d.statements.length)` — BlockStmt
- Line 848: `while (i < d.properties.length)` — ObjectLiteral
- Line 854: `while (i < d.elements.length)` — ArrayLiteral
- Line 883: `while (i < d.switchCases.length)` — SwitchStmt
- Line 889: `while (i < d.caseStmts.length)` — SwitchCase
- Line 896: `while (i < d.matchStmtCases.length)` — MatchStmt
- Line 903: `while (i < d.matchCases.length)` — MatchExpr
- Line 920: `while (i < d.newArguments.length)` — NewExpr
- Line 932: `while (i < d.classBody.length)` — ClassDecl

### clone helpers (lines 1025-1036):
- Line 1028: `while (i < nodes.length)` — cloneNodeArray
- Line 1035: `while (i < strs.length)` — cloneStringArray (not Node, but same pattern)

### instantiation (line 1274):
- Line 1274: `while (gi < generatedNodes.length)` — pushing generated nodes

**Fix:** Convert each `while (i < arr.length) { use(arr[i]); i += 1; }` to `for (const item of arr) { use(item); }` where the loop body doesn't need the index. Keep while-loops where index is needed (e.g., `arr[i]` passed to a function alongside `i`).

---

## Case 4: Union members as function params — analyzer/inject.ms

**Issue:** #20 — Passing `BinaryExprData` (union member) as function parameter causes double-free. The `as` cast creates a temporary copy freed at both call site and callee.

**File:** `src/analyzer/inject.ms:779-957`

**Workaround:** `processAssignment`, `processMemberAssignment`, `processArrayAssignment`, `processCompoundAssignment` all take `assignExpr: Node` and re-extract `BinaryExprData` inside:

```ms
// line 779-780
function processAssignment(stmt: Node, assignExpr: Node, ...): Node {
    // Re-extract BinaryExprData from assignExpr (not passed as param — DRC gotcha #2)
    const bd = assignExpr.data as BinaryExprData;
    ...
}
```

**Fix:** Pass `BinaryExprData` directly as parameter:

```ms
// Before (workaround):
function processAssignment(stmt: Node, assignExpr: Node, ...): Node {
    const bd = assignExpr.data as BinaryExprData;
    ...
}
// call: processAssignment(stmt, assignExpr, ...)

// After (direct):
function processAssignment(stmt: Node, bd: BinaryExprData, ...): Node {
    // use bd directly
    ...
}
// call: processAssignment(stmt, assignExpr.data as BinaryExprData, ...)
```

Same for `processMemberAssignment` (line 924), `processArrayAssignment` (line 941), `processCompoundAssignment` (line 962).

---

## Case 5: Union members as function params — transform/desugar/arrayMethodInline.ms

**Issue:** #20 — Same as Case 4 but for `CallExprData`.

**File:** `src/transform/desugar/arrayMethodInline.ms:123-139`

**Workaround:** Three accessor functions avoid passing `CallExprData` across function boundaries:

```ms
// line 123-139
function getCallArg0(callNode: Node): Node {
    const cd = callNode.data as CallExprData;
    return cd.arguments[0];
}
function getCallArg1(callNode: Node): Node {
    const cd = callNode.data as CallExprData;
    return cd.arguments[1];
}
function getCalleeObject(callNode: Node): Node {
    const cd = callNode.data as CallExprData;
    const md = cd.callee.data as MemberExprData;
    return md.object;
}
```

**Fix:** Callers can extract `CallExprData` once and access fields directly:

```ms
// Before (workaround):
const arrExpr = getCalleeObject(d.argument);
const callback = getCallArg0(d.argument);

// After (direct):
const cd = d.argument.data as CallExprData;
const arrExpr = (cd.callee.data as MemberExprData).object;
const callback = cd.arguments[0];
```

Remove the three helper functions.

---

## Case 6: Local Node var in return — analyzer/optimize.ms

**Issue:** #16 — `const arg = cd.arguments[0]; return (arg.data as X).name;` causes use-after-free (DRC destroys `arg` before extracting `name`).

**File:** `src/analyzer/optimize.ms:105-107`

**Workaround:** Access `cd.arguments[0]` inline, repeated twice:

```ms
// line 105-107
if (cd.arguments[0] === null || cd.arguments[0].kind !== NodeKind.Identifier) return "";
return (cd.arguments[0].data as IdentifierData).name;
```

**Fix:** Use a local variable:

```ms
const arg = cd.arguments[0];
if (arg === null || arg.kind !== NodeKind.Identifier) return "";
return (arg.data as IdentifierData).name;
```

---

## Case 7: Cross-module Node returns — checker/decoratorHelpers.ms

**Issue:** #22 — Returning `Node` or `Node[]` from a helper module causes ASan SEGV because each compilation unit generates different lifecycle hooks for NodeData.

**File:** `src/checker/decoratorHelpers.ms:1-35`

**Workaround:** `extractDecoratorInfo()` returns `DecoratorInfo` (string fields only) instead of returning `Node` references:

```ms
export interface DecoratorInfo {
    runtimeName: string;
    builtinKind: string;
}
export function extractDecoratorInfo(node: Node): DecoratorInfo { ... }
```

**Fix:** If callers need richer data (Node references, decorator nodes), the function can return `Node` or `Node[]` directly. Evaluate whether the primitive-only pattern is still needed per call site.

---

## Case 8: Cross-module Node in interface — monomorphize/collect.ms

**Issue:** #22 — Same cross-module lifecycle mismatch, applied to `MonoGenericDeclMap`.

**File:** `src/monomorphize/collect.ms:39-44`

**Workaround:** `MonoGenericDeclMap` stores only `string[]` fields (names, param names) rather than `Node[]`:

```ms
// line 39-40: comment
// Primitives only — no Node fields (DRC workaround #22)
export interface MonoGenericDeclMap {
    names: string[];
    paramNames: string[];
    ...
}
```

**Fix:** If storing `Node[]` (e.g., the original function declaration nodes) is more natural, the interface can hold Node references directly.

---

## Case 9: Incomplete interface literals create spurious anonymous types — codegen ordering

**Issue:** #34 — When an interface has a non-optional `unknown` field (maps to `void*` in C), constructing a literal without that field creates a separate anonymous object type (MsGen0). The reference compiler's `emitAnonObjectTypedefsPhase` emits this anonymous struct BEFORE `emitTaggedUnionTypedefs`, so if the struct contains a union field by value, the union type is referenced before it's defined. Compilation fails with `unknown type name 'ms_union_...'`.

**Root cause in reference compiler:** `cgen.zig:emitAnonObjectTypedefsPhase` emits anonymous object types (Phase 1) before tagged union typedefs. When a 3-field Node literal `{ kind, location, data }` is inferred as a separate anonymous type (not the 4-field Node interface), it gets registered in `anon_object_typedefs` as MsGen0 and emitted before the NodeData union it depends on.

**Affected files:**
- `src/ast/node.ms:232-238` — `createNode()`
- `src/monomorphize/collect.ms:1017-1082` — ~50 `monoCloneNode()` return statements
- `src/parser/expressions/util.ms:40,42` — error fallback literals
- `src/parser/statements/validation.ms:41` — error fallback literal
- `src/checker/resolvePass.ms:480-508` — test Node literals
- `src/checker/collectPass.ms:292` — test Node literal

**Constraint:** Every Node literal construction MUST include all non-optional fields. With `nodeType: unknown` on the Node interface, all literals must include `nodeType: null as unknown`.

**Self-hosted compiler fix:** The self-hosted compiler's codegen should ensure anonymous object types that contain union fields by value are emitted AFTER the union typedef. Either:
1. Skip anonymous objects whose signature matches a known interface (they'll be emitted by `emitInterfaceDecl`)
2. Defer anonymous objects containing union fields to after union typedef emission
3. Add forward declarations for union typedefs (not sufficient alone — union is by value, needs full definition)

---

## Status

| Case | Status | Notes |
|------|--------|-------|
| 1 | DONE | Helpers inlined into match arms |
| 2 | SKIP | Accessors are for interface types (already pointers), not union `as` casts — not a real #15 workaround |
| 3 | DONE | 15 while-loops converted to for..of, 92+989 tests pass |
| 4 | DONE | BinaryExprData passed directly as param, 989 tests pass |
| 5 | DONE | Helpers removed, CallExprData accessed inline |
| 6 | BLOCKED | Reference compiler still has #16 bug (local Node var in return = use-after-free) |
| 7 | SKIP | Primitive-only API is correct design — callers only need strings |
| 8 | SKIP | Primitive-only fields are correct design — Node[] adds no value |
