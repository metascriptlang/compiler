# MetaScript Metaprogramming

Compile-time code execution and AST manipulation. Macros are **normal MetaScript code** that imports from `std/meta` and runs in the Raiser bytecode VM during compilation. No special macro API — the compiler's own typed AST is the macro author's API.

## Core Principle: `Node` is Compile-Time Only

`Node` (from `std/meta`) is a **compile-time-only type** — like standard reference AST node implementations. Values of type `Node` exist only during compilation and are erased before codegen. Any `Node` remaining in the AST at codegen is a compile error.

Multiple sources produce `Node` values — all follow the same rules:

```ms
import { Node, NodeKind, createNode } from "std/meta";

// All of these produce Node — all compile-time only:
const el = <View><Text>hello</Text></View>;           // JSX → Node
const tmpl = quote { const x = 42; };                 // quote → Node
const node = createNode(NodeKind.BinaryExpr, ...);    // manual → Node

// Macros consume Node and return runtime AST. Macros are called BARE —
// `@name(...)` in expression position is a parse error (measured 2026-09-08):
const app = jsx(el);               // Node → runtime code
const code = inject(tmpl);         // Node → runtime code

// Same Node, different macros, different output:
const webApp = webJsx(el);         // → DOM calls
const nativeApp = nativeJsx(el);   // → UIKit calls

// Direct application (most common):
const app = jsx(<View><Text>hello</Text></View>);

// Macro pipelines — a macro can return Node (still compile-time), not just runtime:
const raw = <View><Text>{count()}</Text></View>;   // Node
const validated = addAria(raw);                     // macro returns modified JSX → still Node
const optimized = staticAnalysis(validated);        // macro returns modified JSX → still Node
const app = render(optimized);                      // macro returns runtime code → Element
```

`@name` is reserved for two other things: decorators on a declaration (see "Decorators" below) and compiler directives (`@include("x");`, see Tier 3).

**One invariant: zero `Node` at codegen.** Everything else is free.

### How it works

1. **Checker** recognizes `Node` type as compile-time only (like in standard reference implementations)
2. **Propagation** — any function/interface containing `Node` in its signature becomes compile-time only
3. **Macro expansion** (top-to-bottom) — when a macro argument is a const identifier whose initializer is a `Node` value, the initializer AST is inlined as the macro's argument
4. **Chaining** — if a macro returns a `Node` value (e.g. modified JSX), the result stays as a Node const, available for the next macro. If it returns runtime code, the result becomes runtime.
5. **Re-expansion** — after each macro expansion, the output is re-walked for nested macros/JSX (depth-limited)
6. **Erasure** — after all macros expand, `Node`-only const declarations are erased from the AST
7. **Safety net** — any `Node` surviving to codegen = compile error: *"compile-time Node not consumed by a macro"*

**Ordering**: a module-level Node const (`const el = <View/>`) is classified when declarations are collected, so a macro argument may name one declared later in the module. Inside a function body declarations are checked in source order, so a local Node const must precede the macro call that consumes it.

### Standard Reference comparison

| | Reference | MetaScript |
|--|-----|-----------|
| Compile-time AST type | `ReferenceNode` | `Node` |
| Enforcement | compile-time flag propagates to containers/procs | Checker flag, same propagation |
| Backend safety | C/JS codegen emits hard error if Node leaks | Same |
| Storage scope | Only inside macros/`static` blocks | Also at module scope (const only) — slightly more permissive |
| Erasure | Implicit (macro bodies only generate VM bytecode) | Explicit (Node consts erased after expansion) |

The module-scope extension enables the "store and reuse" pattern (`const el = <View/>; @jsx(el); @native(el);`) that some reference models don't support. Cost: ~15 lines of const-inlining logic in macro expansion.

## Architecture

```
macro.ms  -> [Parse] -> [Check] -> [Transform] -> Raiser VM (compile-time)
                                                       |
                                                 receives target Node
                                                 returns modified Node
                                                       |
app.ms    -> [Parse] -> [Check] -> [MacroExpand] -> [Transform] -> [Analyze] -> [Codegen]
                                       ^
                                  find @macroName on declaration
                                  inline Node const arguments
                                  load macro .ms -> eval in Raiser
                                  pass target Node -> get back modified Node
                                  splice result into AST
                                  erase consumed Node consts
```

Macros live in **phases 1-3 only**. Fully type-checked MetaScript, never reaches C/JS codegen. The Raiser VM is dynamically typed at runtime, but the source was already validated by the checker — same model as TypeScript (and Haxe).

`std/meta/node.ms` is the **source of truth** for `Node`, `NodeKind`, `NodeData`, all `*Data` type aliases, `Type`, `TypeKind`, `Symbol`, `SymbolKind`. The compiler's `src/ast/node.ms` re-exports from it via `export * from "../../std/meta/node"`. Macro authors import from `std/meta` (which re-exports `./node` plus compile-time builtins like `currentFile`, `readFile`, `error`).

This direction (std/meta → src/ast) means the AST type definitions ship with the compiler distribution — `src/` is not deployed.

## Tier 1: @comptime — Compile-Time Evaluation

**Status: DONE (MVP)**

Evaluate a block at compile time; the result replaces the block in the AST as a literal.

```ms
const SIZE = @comptime { return 4 * 1024; };           // -> 4096
const GREETING = @comptime { return "hello world"; };  // -> "hello world"

const TABLE = @comptime {
    const items: number[] = [];
    let i = 0;
    while (i < 10) { items.push(i * i); i = i + 1; }
    return items;
};
// -> [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]
```

Supports: number, string, boolean, null, array, object returns. Each maps to the corresponding literal AST node.

A `@comptime` block also gets the checker context a macro body gets, so the typed queries of Tier 2 answer inside one (landed 2026-09-12). Measured 2026-09-13 against a class `Later` declared in the same module: `getTypeImpl(bindSym("Later"))` → `Struct` (the `Ref` is peeled), `getImpl(bindSym("Later"))` → its `ClassDecl`, `resolveType("Later | null")` → `TypeUnion`, and `typeKind(resolveType("int32"))` → `Int32`.

### Planned enhancements

1. **Scope capture** — read surrounding `const` declarations (immutable values only)
2. **@comptime functions** — `@comptime function f(): number { ... }` evaluated at every call site
3. **Type inference** — propagate result type back to checker
4. **Statement-position** — `@comptime { assert(SIZE > 0); }` as compile-time assertions
5. **@compileError** — static error reporting from compile-time code

## Tier 2: Macros — Typed AST Manipulation

**Status: DONE** — parsing + eager expansion in `checkCallExpr`, cross-module macros, `quote`/splice, and JSX consumption all landed. JSX macros are verified end-to-end to native (`jsxMacroNative.ms` / `jsxDomNative.ms`, `std/meta/jsxDom.ms`); macro bodies navigate JSX array fields (`for..of`, indexing, `.length`).

Macros receive `Node` values (AST), walk them node-by-node, analyze/reclassify/restructure, and return transformed AST. The compiler's own typed `Node` is the macro's input and output. `node.nodeType` gives type info after phase 2. Exception: a bare module-level statement that calls a macro imported from an already-checked module expands while declarations are collected, so the declarations it emits are visible everywhere in the module; its arguments arrive untyped (no `nodeType`, no `resolvedSym`). Read types there through `getTypeImpl`, `getType` or `bindSym`, and literal values through `intValue` / `floatValue` / `stringValue`.

### The Core Concept: AST In -> Manipulate -> AST Out

A macro is a function that receives `Node`, inspects it however it wants, builds new `Node` trees, and returns the result. The returned AST replaces the original in the compilation pipeline.

```
User writes:        const el = <View style={s}><Text>hello</Text></View>;
                    const app = @jsx(el);
                                      |
                              Macro expansion inlines el's JSX AST
                                      |
                                      v
                    +-------------------------------------------+
                    | User's macro receives JSXElement node     |
                    |                                           |
                    |  1. Walk JSX children                     |
                    |  2. Identify <View> -> platform element   |
                    |  3. Extract style attribute                |
                    |  4. Detect "hello" is static text         |
                    |  5. Build: makeElement("View")            |
                    |     + bindProps(el, {style: s})           |
                    |     + insertChild(Text, el)               |
                    |  6. Return non-JSX AST (runtime code)     |
                    +-------------------------------------------+
                                      |
                              el const erased (was only macro input)
                                      |
                                      v
Compiler continues: [Transform] -> [Analyze] -> [Codegen]
                    (zero Node values remain)
```

### Macro Invocation Forms

Macros can receive any `Node` type as argument — functions, expressions, JSX. Every form is a bare call:

| Form | User writes | Macro receives |
|------|------------|----------------|
| Function | `effect(() => { body })` | `ArrowFunction` node (params + body) |
| Expression | `validate(x + y)` | `BinaryExpr` node |
| JSX | `jsx(<View>...</View>)` | `JSXElement` node |
| Const ref | `jsx(el)` where `const el = <View/>` | `JSXElement` node (inlined) |

Two forms that older revisions of this table listed do **not** exist (measured 2026-09-08): `@log class Foo {}` does not pass the class to `log` (`Macro 'log' expects 1 args, got 0`), and `@routes { … }` parses as a decorator on a block statement and passes nothing. Attaching behaviour to a declaration is the job of decorators, below.

The function form is particularly useful — the macro gets **parameter context** along with the body:

```ms
effect((count: number) => {
    console.log("Count changed: " + String(count));
    document.title = String(count);
});
// Macro sees: arrowParams = ["count"], arrowParamTypes = ["number"]
//             arrowBody = the two statements
// -> analyzes body for reactive deps on `count`
// -> wraps in createEffect with dependency tracking on the count signal
```

### Full Example: JSX Transform Macro

JSX in MetaScript is **pure AST** (`Node` values) — the compiler produces JSXElement/JSXText/etc. nodes but does NOT transform them. The developer writes a macro that decides what JSX means. This is more powerful than JavaScript, where the compiler hardcodes `React.createElement`.

**The developer defines a macro:**

```ms
import { Node, NodeKind, createNode, JSXElementData } from "std/meta";

// This macro receives JSX AST and returns imperative code AST
macro jsx(node: Node): Node { /* see "How it works internally" below */ }
```

**What the user writes:**

```ms
// Store as compile-time Node (reusable template)
const ui = <View style={styles.container}>
    <Text>Count: {String(count())}</Text>
    <Button onPress={increment}>
        <Text>Add</Text>
    </Button>
</View>;

// Transform for different targets
const webApp = @webJsx(ui);      // → DOM manipulation code
const nativeApp = @nativeJsx(ui); // → UIKit calls

// Or direct (most common)
const app = @jsx <View><Text>hello</Text></View>;
```

**What the macro produces (returned AST, before later pipeline phases):**

```ms
const app = () => {
    const el = makeElement("View");
    bindProps(el, { style: styles.container });

    // {String(count())} — detected as REACTIVE (contains count() call)
    // -> wrapped in createEffect for automatic re-render
    const textEl = makeElement("Text");
    const dispose = createEffect(() => {
        updateTextContent(textEl, "Count: " + String(count()));
    });
    onCleanup(dispose);
    insertChild(textEl, el);

    // <Button> with static <Text>Add</Text> — no effect wrapper needed
    const btnEl = makeElement("Button");
    bindProps(btnEl, { onPress: increment });
    const btnText = makeElement("Text");
    updateTextContent(btnText, "Add");
    insertChild(btnText, btnEl);
    insertChild(btnEl, el);

    return el;
};
```

### How it works internally

The reference JSX consumer ships as **`std/meta/jsxDom.ms`** — a macro that rewrites JSX into `el()/txt()/attr()` runtime calls, verified end-to-end to native (`src/test/native/programs/jsxMacroNative.ms`, `jsxDomNative.ms`). Two constraints are load-bearing; both fall out of the compile-time-`Node` model:

**1. Flat field access.** Inside a macro, JSX data is read as flat fields directly on the `Node` — `node.jsxTag`, `node.jsxAttrs`, `node.jsxChildren`, and on children `child.jsxText` / `child.jsxExpr`. There is no `node.data as JSXElementData` step; `for..of`, indexing, and `.length` over the arrays all work.

```ms
export macro jsxDom(node: Node): Node {
    let kids: Node[] = [];
    for (const c of node.jsxChildren) {
        if (c.kind === NodeKind.JSXText) {
            kids.push(/* build a txt(c.jsxText) CallExpr node */);
        } else if (c.kind === NodeKind.JSXElement) {
            // nested element — recurse via RE-EXPANSION (constraint 2)
            kids.push(/* build a jsxDom(c) CallExpr node */);
        }
    }
    return /* build an el(node.jsxTag, [...attrs], kids) CallExpr node */;
}
```

**2. Navigation only in the macro body → recursion via re-expansion.** Only the macro body's return position is special-typed to build flat `Node` literals. A helper function cannot navigate JSX or build node literals, so a `processJSXElement(child, ...)`-style helper recursion does **not** type-check. Nested elements recurse by emitting a fresh `jsxDom(child)` call that the expander re-walks (depth-limited). See `std/meta/jsxDom.ms` for the full, compiling source.

Because the macro sees `{expr}` containers as AST (not runtime values), a richer target can do selective compile-time analysis — e.g. detect that `{String(count())}` contains a reactive `count()` call and wrap it in `createEffect`, while leaving static `"Add"` text with zero overhead.

### Why this can't be done with functions

- **AST access**: The macro sees `count()` as a `CallExpr` node. A runtime function only sees `"Count: 5"` — can't know which parts are reactive.
- **Selective wrapping**: Static children get zero overhead. Reactive children get `createEffect`. Requires compile-time analysis.
- **Attribute reclassification**: `style`, `onPress`, `opacity` silently route to different runtime APIs. A function can't restructure the call site.
- **Zero-cost abstraction**: JSX compiles away entirely into `makeElement`/`insertChild`/`bindProps` calls. No virtual DOM, no diffing.
- **Developer control**: Unlike JS where the compiler decides JSX semantics, in MetaScript the developer writes the macro — same JSX syntax can target React-style vDOM, SolidJS-style reactivity, native platform calls, or anything else.

### quote / unquote (syntactic sugar)

Building AST manually via `createNode()` is verbose. `quote { }` provides a template shorthand:

```ms
// Manual:
createNodeAt(NodeKind.VariableDecl, { declName: "x", declKind: DeclKind.Const, ... }, loc);

// quote — parsed into AST template, ${} splices values:
const node = quote { const ${varName} = ${initValue}; };
```

`quote` produces a `Node` value (compile-time only, same as JSX and `createNode`). Everything it does can be done with `createNode()` directly. `${}` interpolation splices computed Node values into the template.

## Decorators — TypeScript-compatible, compile-time

**Status: IMPLEMENTED** — symbol model 2026-09-09, typed queries and declarations nested in function bodies 2026-09-10, decorators on actors and typed queries inside `@comptime` 2026-09-12, inherited metadata and the isolation intrinsic as an imported symbol 2026-09-13. Every row below was re-measured on 2026-09-13 with a compiler built from the tree; the probes are pinned in `src/test/c/typeIntrospection.ms` (E2E), `src/test/guard/decorator*.ms`, `src/test/guard/nonisolated*.ms` and corpus `760-decoratorNested`.

### Boundary (TypeScript measured with tsc 5.9.2 on 2026-09-08; MetaScript re-measured 2026-09-13)

Not re-measured on 2026-09-13, and carried over from the 2026-09-10 pass: the `7` / `1` / `1` outputs in the first three rows, and the tsc side of every row — the TypeScript column is the 2026-09-08 tsc 5.9.2 measurement throughout, including the static ordering quoted under Contract.

Every position where MetaScript accepts `@` and TypeScript does not is a TypeScript **syntax error**. A valid TypeScript program can therefore never reach a MetaScript-only path, and only the TS-valid positions have to match TS semantics exactly.

| Position | TypeScript | MetaScript (measured output) |
|---|---|---|
| `@x class`, `@x method()`, `@x field`, `@x static field` | valid | applied at compile time — static field + method probe prints `7` |
| `export @x class` and `@x export class` | valid (TS 5.0+) | both orders apply (`1` / `1`) |
| `@ns.x` | valid | applies (`1`) |
| `@(expr)` | valid | `Parse: Unexpected token: )` — still open |
| `@x class` inside a function, a method or an arrow body | valid | applied where the declaration is checked, in the enclosing scope — corpus 760 prints `extra=43 twice=42 counted=5,5 hits=2 scoped=4 method=45 arrow=49` |
| `@x actor` and `@x` on an actor member | no `actor` in TypeScript | applied like a class: `context.kind` is `"class"`, the decorator may push members onto `actorBody`, and a member decorator still rewrites the initializer — guard `decoratorActor` prints `GUARD-OK decoratorActor`. `context.addInitializer` is the one refusal: `addInitializer on actor members is not supported` |
| `@nonisolated` on an actor field | no analogue | the isolation intrinsic — a symbol imported from `std/actor`, see the Contract below |
| `const A = @x class {}` | valid | no class expressions at all |
| getter / setter / `accessor` kinds | valid | no getters, setters or `accessor` at all |
| `@x function` / `const` / `enum` (top level or nested) | **TS1206** Decorators are not valid here | `Decorators are not valid here` — the positions are **reserved for compiler intrinsics** (`@builtin`, the FFI pragmas) |
| `@x(...);` standalone | **TS1146** Declaration expected | directive statement (`@include`, `@passC`, …), never a decorator |
| `@x` on a parameter | TS1206 | `Parse: Expected '{'` (TC39 dropped parameter decorators) |
| `const v = @x(1)` (expression position) | error | parse error; macros are bare calls |
| unknown name `@nope class` | **TS2304** Cannot find name | `Cannot find name 'nope'` |

### Contract

A decorator is an ordinary function found by normal scoping: `@x` is an identifier lookup. Two compiler-recognised groups sit beside user decorators, and the two are recognised by opposite mechanisms — measured 2026-09-13.

**Directives** (`emit`, `include`, `compile`, `link`, `passC`, `passL`, `import`, `comptime`, `builtin`) are matched by **spelling** against a fixed list (`isBuiltinDirective`, `src/checker/decoratorHelpers.ms`). There is no symbol behind them, nothing to import, and a local binding does **not** shadow them: `import { include } from "./mine"` followed by `@include("stdio.h")` still runs the directive and reports `'include' is imported but never used`.

**The isolation intrinsic** `nonisolated` is the opposite. It is a symbol exported by `std/actor` (`@builtin("nonisolated") export extern function nonisolated(): void`) and recognised by `sym.builtinKind`, so it must be imported — without the import the actor field is a hard error, `Cannot find name 'nonisolated'`. Because recognition is by symbol it survives renaming (`import { nonisolated as noniso }` is accepted), and a same-named local function is *not* it: a hand-written `export function nonisolated()` imported from a user module is run as an ordinary decorator and fails with `decorator 'nonisolated': Too many arguments: expected at most 0, got 1`. `std/actor` is not in the prelude — `globalImports` is `std/core/*` — so the import is always explicit.

Signature: `(value: Node, context) => Node | void`, where TS has `(value, context) => value | void`. `@f(args)` calls `f(args)` first and uses the result as the decorator, the TS factory rule. The Raiser VM already runs closures and closure-returning factories, so this rule is implemented literally. The body runs at compile time.

`context` is `{ kind: "class" | "method" | "field", name: string, static: boolean, private: boolean, access, addInitializer, metadata }`, the TC39 field names verbatim (`static` and `private` are legal field names in MetaScript, measured). `private` is always `false` while there is no `#x`. `access.get(recv)` / `set(recv, v)` / `has(recv)` return `Node` expressions against a receiver Node instead of touching a runtime object. `metadata` is one object per class shared by every decorator on that class, and a subclass reads its parent's. Measured 2026-09-13: `metadata.keys` lists only what the class itself wrote — a grandchild whose own decorators write nothing reads `keys.length == 0` while still resolving its grandparent's key — and `metadataGet` / `metadataHas` fall through the chain, nearest class first, so a key rewritten by the middle class answers `9` rather than the root's `1`. A parent declared *after* the subclass answers the same, because its decorators are applied on demand when the subclass asks rather than in source order. Inheritance is same-module only: `class K extends P` with `P` imported fails earlier, in class inheritance itself — `cannot declare 'P_init': the parent constructor signature is not reachable from this module`, measured identical on a decorator-free program. It exists **only during compilation** and is never emitted.

Return rules follow TS ("replace only with the same kind") plus MetaScript's superset: class → a `ClassDecl` Node, which may rewrite fields, types and members (the checker runs on the result); method → a method Node (the original is lifted to a hidden member, and `value` spliced in expression position calls it); field → `(init: Node) => Node` as in TS, or a replacement field Node.

Order, measured with tsc: decorator expressions evaluate top-to-bottom, once. Application order is static methods, instance methods, static fields, instance fields, then the class; on one element bottom-to-top.

`addInitializer` emits statements where TS would run the callback **for instance members**: instance method → start of the constructor before any field init; field → right after that field's own init. Guard `decoratorInitializerOrder` pins that trace exactly: `P-ctor,m-init,init-a,init-b,fb-extra,init-c,fc-extra,init-d,K-body`.

**Static placement diverges deliberately.** Static work was deferred when the instance order landed, so every static extra runs *after all static field initializers*, in application order, rather than at its TS position. Measured 2026-09-13 on a class with static fields `a,b,c`, an `addInitializer` on decorated static field `b`, one on a static method and one on the class:

```
STATIC PHASE: sfield-a,sfield-b,sfield-c,SM-init,SF-extra,CLASS-init,
CTOR PHASE:   ifield,
```

tsc runs `SM-init` *before* `sfield-a` and `SF-extra` immediately after `sfield-b`. Only the class extra — after all static fields — matches TS. No guard pins the static order yet; `decoratorReplace` pins only that a static initializer lands at module init at all.

Deliberate divergences: decorator expressions must be compile-time evaluable (`@(isDev ? a : b)` is an error); no runtime `Symbol.metadata`; decorators return AST, not values, so a TypeScript decorator *library* does not drop in. Only decorator *use sites* are source-compatible.

Decorator ≠ macro ≠ directive. Macros are bare calls and may emit new top-level declarations. Directives are `@name(args);` statements that decorate nothing.

### Measured contract (2026-09-10; "Still open" re-measured 2026-09-13)

- **Order.** `@tagA @tagB class X {}` where each decorator appends a field initialised to the member count it sees prints `a=1 b=0`: `tagB` ran first (bottom-to-top), `tagA` saw its field.
- **Same kind.** A class decorator returning a field: `decorator 'toField' on a class must return a class or nothing, got field`. A replacement class must keep its name: `decorator replacement must keep the name 'Local'` — top level and nested alike.
- **Symbol model.** The class symbol is created in source order during collection and filled in after its decorators ran, so exports, the extension registry and every `resolvedSym` point at one object. A class whose decorators have not finished is still forward: asking for its type from its own decorator (`getTypeImpl(bindSym("Wid" + "get"))` inside `@selfQuery class Widget`) is a compile error `'Widget' is still being decorated - its type is not available until its decorators finish`; seen through another type (`Holder { w: Widget }`) it renders as the name-only `Identifier "Widget"` and the field added by its decorator type-checks afterwards (`h.w.extra`).
- **Nested declarations.** A decorated class inside a function, method or arrow body is decorated where the statement is checked: the class and member decorators rewrite it, `context.addInitializer` statements are checked and hoisted into the enclosing block, and they run each time the definition is evaluated (`hits=2` after two calls of the enclosing function). The decorator resolves in the enclosing scope, so a dynamic `bindSym` sees the enclosing function's locals (`scoped=4`).
- **What a decorator reads.** `value` is the declaration AST as written; `propType`, `fnReturnType` and parameter types arrive as strings. `resolveType("Later | null")` turns such a string into the type-AST through the checker's own annotation resolver (`TypeUnion`; `resolveType("int32")` → `Identifier int32`). `getImpl(bindSym("Later"))` returns a copy of the declaration (`ClassDecl` with its members). `error("boom", value)` inside a decorator body is reported as `decorator 'check': boom` at the decorator's location.
- **Queries chain.** Every query takes `Node | null`, so `typeKind(getType(bindSym("Color")))` type-checks without narrowing (measured 2026-09-11): `getType`, `getTypeImpl` and `getImpl` pass a `null` node through as `null`, while `typeKind`, `symKind` and `sameType` keep a non-null result and report it — `node carries no type`, `node is not a symbol`, `sameType needs two type nodes`. Pinned in `src/test/c/typeIntrospection.ms`.
- **A `@comptime` block reports its own checker errors (2026-09-14).** A key that exists on no `NodeData` variant is rejected inside a `@comptime` block (`@comptime block: 'bogusKey' does not exist in type 'Node'`); it was silent before, and is pinned by the proven-red guard `comptimeBogusField`. Checking a macro's *nested* literals to the same depth landed 2026-09-15 (below); checking its *return* literal is still not landed.
- **Nested literals are checked; the first attempt was reverted for the wrong reason (2026-09-15).** A key that exists on no `NodeData` variant is now rejected at every depth, not only in the outermost literal — `Macro 'blk' body: 'bogusKid' does not exist in type 'Node'` fires for a key two levels down and for one inside an array element. Pinned by the proven-red guard `macroNestedBogusField`. The check shipped 2026-09-14, was reverted the same day after it rejected `caseGuard: null` in a real macro (a downstream UI library's style macros), and returned once the cause was measured — the cause was **not** the check. `MatchCaseData` declared `caseGuard: Node` while a guardless match arm carries no guard, so the record type rejected a value the wire legitimately produces: `addNodeField` always emits the key, and a null child marshals through `nodeToASTLiteral` to `mkNull`. The declaration now reads `caseGuard: Node | null`; nothing else changed, and the two downstream lines compile unmodified. **An earlier version of this bullet claimed the fix had to make `null` acceptable for a `Node`-declared field in engine-check mode, over "98 plain `: Node` fields against 9 nullable". Both halves were wrong** — the table really holds **155 plain `: Node` slots (77 distinct names) against 9 nullable (6 distinct)**, and no checker change was needed at all. Measured cost of the declaration change: `OK no type errors in 336 module(s)`, zero errors, with the method calibrated first by flipping a field that genuinely is never null (`left` → 110 errors). Bare `null` written into a wire Node slot, scanned across every downstream `.ms` tree: two sites, the ones above. Carrying the macro's declared *return* type into the body wrapper is a separate change and is **not landed** — it rejected the compiler's own `error()` sentinel and every macro whose declared return type is not `Node`.
- **Gate for the nested check.** Build 308 modules, self-check `OK no type errors in 336 module(s)`, suite `179 files / 3693 tests`, guard lane all green, and a downstream UI library's browser lane `Tests 75 passed (75)` with the library unmodified. Seven macro-related `fixedbugs` files pass individually; `fixedbugs/index.ms` stops earlier on a pre-existing `new Box() requires explicit type arguments`, identical on the parent commit. **NOT verified:** the full corpus lane, other downstream projects, and whether the other 53 fields the compiler null-checks are genuinely nullable — of those, only four flip at zero cost (`caseGuard`, `typExprIndexKey`, `typExprIndexValue`, `typExprReturn`) and only `caseGuard` has a producer that assigns a nullable value (`parser/expressions/match.ms:102`).
- **Still open.** `@(expr)` — re-measured 2026-09-13, still `Parse: Unexpected token: )`. User decorators on functions, enums and constants. `getType` on an enum and on a tuple alias answers with the name only — measured `enum=Identifier tuple=Identifier fn=TypeFunction`, so a function does render as a `TypeFunction`. A null node into `typeKind` / `symKind` / `sameType` is an error rather than a "none" kind, because the macro engine boxes a value-or-null result (`TypeKind | null` comes back as an object). Static `addInitializer` placement, above. And `@nonisolated` outside its one meaningful position is accepted with no effect and no diagnostic: on a plain class field and on an actor *method* the program compiles and runs silently (measured 2026-09-13) — the intrinsic is only consumed on an actor field.

## Tier 3: Directives — Backend-Specific Control

**Status: DONE** (`@emit` expansion verified 2026-08-10, see table below)

```ms
when (c) { extern function malloc(size: number): number; }
when (js) { function allocate(size: number): number { return 0; } }
@emit("#include <stdio.h>");
@emit("#include <stdio.h>");
@include("mylib.h");
@compile("mylib.h");
@link("libcrypto.a");
@passC("-DDEBUG=1");
@passL("-lssl");
```

| Directive | Status |
|-----------|--------|
| `@include` / `@link` / `@passC` / `@passL` | DONE |
| `@target("backend")` | RETIRED 2026-08-09 — use `when (c) { … }` |
| `@emit("code")` | DONE — top-level via `genTopLevelEmit` + `emitToSection` (`src/codegen/c/declarations.ms:578-603`), in-function via `src/codegen/c/statements.ms:237`, JS backend at `src/codegen/js/statements.ms:188` |

`@emit` at top level routes each line by section marker (`emitToSection`): `/*TYPESECTION*/` → Types, `/*VARSECTION*/` → GlobalVars, `/*INCLUDESECTION*/` → Headers, otherwise ProcHeaders. Arbitrary C attributes survive to the object file — verified 2026-08-10 by emitting `__attribute__((import_module(...), import_name(...)))` / `__attribute__((export_name(...)))` and reading them back out of the linked `--os=emcc` wasm:

```wasm
(import "spacetime_10.0" "console_log" (func $fimport$0 (param i32 i32 i32)))
(export "__describe_module__" (func $2))
```

This is what makes custom-host wasm ABIs (SpacetimeDB modules, wasm component hosts) reachable without a compiler patch.

## Tier 4: Intrinsics & Runtime Mapping

**Status: DONE**

While Tier 2 macros are user-defined, Tier 4 handles **compiler-intrinsic** logic and direct backend symbol mapping. This layer ensures that high-level MetaScript constructs are lowered into backend-primitive structures before reaching the "DUMB" codegen layer.

### @runtime("symbol") — REMOVED 2026-09-10

`@runtime` never mapped a function to a backend symbol: `@runtime("myHelloSym") function hello()` built and ran with the normal mangled name, zero `myHelloSym` in the emitted C, and no compiler pass consuming the name. It was only whitelisted for pass-through (`isBuiltinDirective`), the same way `@target` looked supported for months. The whitelist entry was removed, so `@runtime` is now an unknown-name error. The working mechanism for symbol mapping is `extern function f(): T from "symbol"` / `static extern log(...): void from "msPrintln"` (see `std/core/system/index.ms`).

### @builtin("kind") — Structural Intrinsics

Identifies "magic" functions that require structural AST transformation rather than simple renaming.

- **Behavior**: `builtinLower` checks the `builtinKind` on the resolved symbol and performs a complex AST rewrite.
- **Example**: `Result.ok(val)` is marked `@builtin("msResultOk")`. The transformer expands this into an `ObjectLiteral` node: `{ ok: true, value: val }`.
- **Implementation parity**: Equivalent to standard reference `magic` system (e.g., `mResultOk`).

### Builtin Lowering (`src/transform/native/builtinLower.ms`)

The "Magic" expansion pass. It is the primary bridge between high-level semantics and backend primitives.

1. **Renaming**: not done here — `extern … from "sym"` stores `nativeName` on the symbol and C codegen (`src/codegen/c/declarations.ms`) emits it directly.
2. **Normalization**: Flattens extension methods (`obj.method()` → `method(obj)`) via UFCS.
3. **Structural Expansion**: Inlines specialized AST structures for `@builtin` calls.

By performing these rewrites in the **Transform** phase (AST-to-AST), we keep the **Codegen** layer strictly "DUMB"—it only needs to know how to emit syntax for basic nodes like `CallExpr` or `ObjectLiteral`, without needing to understand high-level types like `Result`.

## Node Serialization — The Bridge

Macros run in the Raiser VM but manipulate compiler `Node` structs. Bidirectional conversion:

```
Node  --nodeToValue()-->  RaiserValue (Object with named fields)
      <--valueToNode()--  (extends existing comptime.ms literal converter)
```

The checker validates macro code statically. The Raiser executes it dynamically with field access. Type safety at compile time, not runtime.

### nodeToValue() — DONE

`nodeToValue(node, objHeap, arrHeap)` in `src/compiler/comptime.ms` serializes any `Node` into a `RaiserValue` Object on the Raiser heap. Covers all 62 NodeKinds: literals (6), identifier (1), expressions (24), patterns (4), statements (19), declarations (14), testing (2), program (1).

Each Node becomes an Object with fields:
- `kind` — integer (NodeKind enum ordinal)
- `line` / `column` — source location
- Kind-specific data fields (matching NodeData type aliases)
- Child nodes serialized recursively, arrays via `heapAllocArray`/`heapArrayPush`

DRC-safe helpers: `serializeNodes`, `serializeStrings`, `setStr`, `setBool`, `setNode`, `setNodes`, `setStrs`.

## Phased Implementation Plan

### Phase 0: Module System Foundation — DONE

Prerequisite for `std/meta` re-exports and clean macro authoring.

| Task | Description | Status |
|------|-------------|--------|
| 0.1 | `export * from "path"` — re-export all symbols from another module | **DONE** |
| 0.2 | `import * as ns from "path"` — namespace import (qualified lookup) | **DONE** |
| 0.3 | `SymbolKind.Module` — namespace symbol kind for `ns.X` resolution via ExportRegistry | **DONE** |
| 0.4 | C codegen Module MemberExpr handler (mangled names + cross-module forward decls) | **DONE** |
| 0.5 | JS codegen native ES6 emission (`import * as`, `export *`) | **DONE** |
| 0.6 | `closureCallMarker` exception for `ns.func()` (always direct call, never closure) | **DONE** |
| 0.7 | `expandStarExports` + `isTypeExport` follow-through for re-export chains | **DONE** |
| 0.8 | Move `Node` definitions to `std/meta/node.ms`, `src/ast/node.ms` re-exports | **DONE** |

### Phase A: Node Serialization (Node <-> RaiserValue) — DONE

**Prerequisite for all macro expansion. Load-bearing for macro chaining** — without complete round-trip serialization, macros that return modified AST (not just runtime code) silently corrupt the tree.

| Task | Description | Status |
|------|-------------|--------|
| A1 | `nodeToValue()` — recursive Node -> RaiserObject for all NodeKinds | **DONE** |
| A2 | `valueToNode()` — full reverse of A1, all 68 NodeKinds | **DONE** |
| A3 | Round-trip tests: node -> value -> node preserves structure | **DONE** (~15 tests) |
| A4 | `typeToValue()` — READ path: `node.nodeType` + `getTypeImpl(T)` in macro bodies | **DONE** (2026-07-27). `valueToType()` (write path) still unscheduled — macros consume type info, they cannot synthesize types. |
| A5 | Extract bridge into `src/compiler/meta/bridge.ms` (split from comptime.ms) | **DONE** |
| A6 | Move comptime evaluator into `src/compiler/meta/comptime.ms` | **DONE** |
| A7 | Audit fix: serialize `MatchCase.caseGuard` (was silently dropped) | **DONE** |
| A8 | Audit fix: handle null Node fields safely in `setNode` | **DONE** |
| A9 | Maintenance comments at both dispatcher entry points | **DONE** |

**Files:** `src/compiler/meta/bridge.ms`, `src/compiler/meta/comptime.ms`

### Phase B v1: Macro Expansion Pass — DONE

**Core macro execution. Depends on Phase A. Working end-to-end.**

| Task | Description | Status |
|------|-------------|--------|
| B1 | Macro registry: store body + params on CheckerContext, populated by collectMacro | **DONE** |
| B2 | `expandMacros(program, ctx)` — public entry point | **DONE** |
| B3 | `walkExpand` — recursive AST walker covering 30+ NodeKinds (in-place mutation) | **DONE** |
| B4 | `hasUserMacroInvocation` — quick predicate to skip pass when no macros present | **DONE** |
| B5 | `expandMacroInvocation` — build wrapper Program, run in Raiser VM, deserialize | **DONE** |
| B6 | `nodeToASTLiteral` — Node → ObjectLiteral AST for parameter binding | **PARTIAL** (~14 of 68 NodeKinds; sufficient for simple macros) |
| B7 | Re-expansion with depth limit (=16) — macros generating macros | **DONE** |
| B8 | Built-in directive pass-through (`@emit`, `@include`, etc.) | **DONE** |
| B9 | Heap cleanup after each macro (clearObjectHeap/clearArrayHeap) | **DONE** |
| B10 | Pipeline integration: 4 call sites in compile.ms before evaluateComptimeBlocks | **DONE** |
| B11 | Audit fixes: walker coverage for IfStmt cond, WhileStmt cond, For, Switch, TryCatch, Match, Class, Method, etc. | **DONE** |

**Files:** `src/compiler/meta/expand.ms`, `src/checker/context.ms` (registry), `src/checker/collectPass.ms` (population), `src/compiler/compile.ms` (pipeline)

**v1 limitations**:
- Macro body must produce results as object literals matching Node serialization shape (no `createNodeAt(...)` calls — Raiser doesn't import std/meta yet)
- Macros invoked via `@name(...)` only — bare `name(...)` invocation comes in Phase B+
- Macros can only be defined and used in the same file (cross-module deferred to Phase E)

### Phase B+: Bare-Call Macro Invocation with Eager Inline Expansion — DONE

**Drop the `@` prefix for user macros in expression/statement position.** Macros are called like normal functions, the compiler runs them inline during semantic analysis (semMacroExpr → semAfterMacroCall flow).

| Task | Description | Status |
|------|-------------|--------|
| B+.1 | Add `SymbolKind.Macro` to std/meta/node.ms | **DONE** |
| B+.2 | `collectMacro` sets symbol kind to `Macro` | **DONE** |
| B+.3 | `checkCallExpr` detects callee = Macro → eagerly expand inline via `expandMacroInvocation`, mutate node to be the result, re-check for type | **DONE** |
| B+.4 | Add `macroExpansionDepth: int32` to CheckerContext to bound recursion (limit 16) | **DONE** |
| B+.5 | Export `expandMacroInvocation` from `src/compiler/meta/expand.ms` so the checker can call it | **DONE** |
| B+.6 | E2E tests: `const x = answer()` (no annotation), `const y = echoBack(99)` (no annotation), macro returning BinaryExpr | **DONE** |

**Why eager inline expansion?** The deferred (post-check) expand pass had a fatal flaw: variables initialized by macro calls were typed as `unknown` during checkVariableDecl (because the checker couldn't predict the macro's return type). The post-check expansion replaced the AST node with the expanded result, but the variable's symbol type was already fossilized as `unknown`, leading to `void* x = 42` in C codegen. Eager expansion fixes this by running the macro DURING checking — the type is inferred from the actual expansion result, not the placeholder.

**Decoder rule** (unchanged): `@name` is **only** used in decorator position before a declaration (`@log class Foo {}`, see "Decorators") and for built-in directives (`@emit`, `@include`). Everywhere else, macros are called as `name(args)`. `@derive` appears in older notes but is not implemented.

**Files**: `std/meta/node.ms` (1 line), `src/checker/collectPass.ms` (1 line), `src/checker/context.ms` (2 lines), `src/compiler/meta/expand.ms` (1 line: export), `src/checker/checkExprPass.ms` (~50 lines for eager expansion + import)

**Recursion safety**: `macroExpansionDepth` on CheckerContext bounds eager expansion. If a macro returns a call to another macro that returns another, etc., the depth limit (16) catches infinite recursion with a clear error.

**Post-check `expandMacros` pass still runs** — needed for `@`-prefixed macros (decorator position, standalone directives) that don't go through `checkCallExpr`.

### Phase C: quote / unquote Interpolation

| Task | Description |
|------|-------------|
| C1 | Parser: `quote { ... }` block, parse `${ expr }` as interpolation hole | **DONE** |
| C2 | Lower `quote { ... }` → `nodeToASTLiteral` AST at expansion time | **DONE** |
| C3 | Substitute `${expr}` placeholders with evaluated expressions at expansion time | **DONE** |
| C4 | Test: `return quote { ${left} + ${right} };` produces a BinaryExpr | **DONE** |

### Phase D: Macro-Author Sugar — DONE

**The problem**: macro bodies execute in the Raiser VM, which only sees the wrapper Program built by `expandMacroInvocation`. The VM doesn't have access to `std/meta/node.ms` exports — so macro authors couldn't use `NodeKind.X` constants from inside macro bodies. They had to write raw integer ordinals: `return { kind: 7, ... };`.

**Note**: `createNodeAt` is NOT a Raiser-specific function. It's the same `createNodeAt` defined in `std/meta/node.ms` that the compiler itself uses. The issue is reachability: the VM can't import it.

| Task | Description | Status |
|------|-------------|--------|
| D1 | Preprocessing pass: rewrite `NodeKind.X` MemberExpr → integer literal at macro body preparation time | **DONE** (76 NodeKind variants mapped) |
| D2 | Same for `DeclKind.X` | **DONE** (Const/Let/Var) |
| D3 | Wire `preprocessMacroBody` into `expandMacroInvocation` | **DONE** |
| D4 | E2E test: macro using `kind: NodeKind.BinaryExpr` works | **DONE** (`double(21)` returning a BinaryExpr) |
| D5 | Unit tests for ordinals + rewriter | **DONE** (5 new tests in expand.ms) |
| D6 | `createNodeAt(K, D, L)` call rewrite | **DONE** — rewrites to `{ kind: K, line: L.line, column: L.column, ...D }` at preprocessing time |
| D7 | `ExternKind.X`, `NodeFlag.X` rewrites | DEFERRED — add on demand |

**Why preprocessing instead of VM changes**: Preprocessing is a small source-to-source rewrite that happens in `expandMacroInvocation` before building the wrapper Program. Zero changes to the Raiser VM — just walk the macro body AST and rewrite the recognized patterns. Real cross-module imports for the VM (`import { createNodeAt } from "std/meta"` at the VM level) is a much bigger change that comes in Phase E.

**Implementation**: `preprocessMacroBody` in `src/compiler/meta/expand.ms` walks the body AST in place, mutating MemberExpr nodes that match `NodeKind.X` or `DeclKind.X` into NumberLiteral nodes with the corresponding ordinal. The rewrite is idempotent — running on already-rewritten code is a no-op, so the body in `ctx.macroBodyRegistry` can be preprocessed once and reused across invocations.

**Files**: `src/compiler/meta/expand.ms` (~250 lines added — 80-line `nodeKindOrdinal` lookup table + 50-line walker + 70 lines of unit tests)

**v1 limitations** (acceptable, document them):
- `NodeKind` cannot be used as a value: `const k = NodeKind.X; return { kind: k };` won't work — only direct member access in expression position
- `createNodeAt(K, D, L)` rewrite requires `D` to be an inline ObjectLiteral at the call site. Variable references (`const d = {...}; createNodeAt(K, d, L)`) are NOT rewritten — the call survives into the Raiser VM and yields a silent `<object>` placeholder at runtime (no hard error). Verified empirically 2026-05-22. Workaround: keep the object literal inline, or use helper macros.
- No helper functions like `mkNumber`, `mkString` — those need real cross-module support (Phase E)

**What macro authors can write now**:

```ms
macro double(x: Node): Node {
    return {
        kind: NodeKind.BinaryExpr,    // ← was: kind: 7
        line: x.line,
        column: x.column,
        operator: "+",
        left: x,
        right: x,
    };
}

const y = double(21);   // → 21 + 21 = 42
```

The `NodeKind.BinaryExpr` is rewritten to the integer `7` (or whatever ordinal) at preprocessing time, then the Raiser VM sees the wrapper Program with the ordinal already substituted.

### Phase E: Cross-Module Macros — DONE

| Task | Description | Status |
|------|-------------|--------|
| E1 | Macro body + params carried through ExportedSymInfo | **DONE** |
| E2 | `import { myMacro } from "./macros"` — discover and use cross-module macros | **DONE** |
| E3 | `export macro` syntax in parser | **DONE** |
| E4 | Macro hashing for incremental builds — re-expand only when macro source changes | DEFERRED |
| E5 | `nodeToASTLiteral` full coverage (all 68 NodeKinds) for complex macro args | DEFERRED (21/68 covered) |

### Phase F: Directives Expansion

`@emit` code injection, `@comptime` functions, statement-position `@comptime`. Independent of macro expansion. Mostly already wired in checkExprPass. (Backend-conditional code is `when` — see LANG.md "Conditional Compilation".)

### Dependency Graph

```
0 (module system) ─┐
                   ├─→ A (serialization) ─→ B v1 (expansion) ─→ B+ eager ─┐
                                                                            ├─→ D (macro sugar: NodeKind/createNodeAt rewrite)
                                                                            ├─→ C (quote sugar)
                                                                            └─→ E (cross-module + nodeToASTLiteral full)
F (directives) ─── independent, mostly already wired
```

**Done**: 0, A, B v1, B+ eager, C (quote + `${}`), D (NodeKind/DeclKind + createNodeAt rewrite), E (cross-module macros)
**Next**: F (directives: `@emit`), nodeToASTLiteral full coverage (21/68 → 68/68)

## Key Design Decisions

- **`Node` is compile-time only** — same proven model as standard reference implementations. JSX, `quote`, `createNode` all produce `Node`. Zero `Node` at codegen.
- **No special macro API** — compiler's own AST types are the API. Same proven approach as Haxe (10+ years production). No `MacroContext`, `ASTBuilder`, or `MacroTarget`.
- **Type-checked macros** — checker validates Node access, createNode() calls, `as` casts to `*Data` types before macro ever runs. IMPLEMENTED for macro bodies 2026-07-26: params carry their declared types into the engine compile (`macroParamTypesRegistry`), the body compiles against its OWN module scope (`macroDeclModuleRegistry` → seed symbols — the invoker no longer needs to import `Node`), and engine checker errors surface at the invocation as `Macro '<name>' body: ...` (Severity.Error only; the synthetic wrapper's unused-hints stay quiet). Flat Node-field reads follow the DU access rule (LANG.md "unique field name"): unique across `NodeData` variants → typed direct read (`n.jsxTag: string`); same name with different types (`n.value`) → error demanding a kind-narrow; unknown field → error. The VM wire format is FLAT — `.data` is not populated in macro bodies; construction literals (`{ kind, line, column, ... }`) are key-checked against the same table **at every depth** since 2026-09-15 — a literal nested under a flat wire key is typed through `engineNodeVirtualKeyType`, which returns nothing when the key's type differs across variants, so the DU access rule still holds. A macro's *return* literal remains unchecked (see the decorator section). `@comptime` bodies do report their own checker errors as `@comptime block: …` instead of discarding them. Roadmap: `NodeData` as a real `match (kind)` DU + nested `data` on the wire.
- **Module-scope Node consts** — extends standard reference models to allow `const el = <View/>` at top level, enabling reuse across multiple macros. Erased after expansion.
- **node.nodeType over Context.typeof()** — type info already on every argument Node after phase 2 (module-level statement macros from other modules run before it and see untyped arguments). No separate API call needed (simpler than Haxe).

### Reading types from a macro body (A4)

Three entry points, and picking the wrong one is the usual mistake:

| you have | use | you get |
|---|---|---|
| an argument Node with a type | `arg.nodeType` | the type-AST of that VALUE — class/interface arrives **Ref-wrapped**, so peel `TypeGeneric → typExprArgs[0]` |
| a type the MACRO knows by name | `getTypeImpl(Style)` | that type's implementation, Ref already peeled — `TypeObject` directly; resolved when the body is baked |
| a type the CALLER picked: `m<T>(...)` | `getTypeArg()` | the call site's `<T>`, resolved in the CALL SITE scope, Ref peeled |
| a bound symbol (`bindSym`, either mode) | `getType(s)` / `getTypeImpl(s)` | the symbol's type-AST at macro run time, `getType` keeps Ref, `getTypeImpl` peels it; a class declared later in the module is resolved on demand and answers with its full shape; no type → compile error `node has no type`; a `null` node → `null` |
| a bound symbol | `getImpl(s)` | a copy of its declaration (`ClassDecl`, `FunctionDecl`, …), `null` when the symbol has none; not a symbol → `node is not a symbol`; a `null` node → `null` |
| a type written as a string (`propType`, a param type) | `resolveType("A \| null")` | the type-AST the checker resolves for that annotation at the expansion site |
| a type-AST from any query above | `typeKind(t)` | the `TypeKind` behind the rendered AST — a class is `Ref` via `getType` and `Struct` via `getTypeImpl`, an enum `Enum`, `int32` `Int32`, a function `Function`; no type handle → `node carries no type` |
| two type-ASTs | `sameType(a, b)` | the checker's type identity (`resolveType("int32")` twice → true, against `"string"` → false); a non-type node → `sameType needs two type nodes` |
| a bound symbol | `symKind(s)` | its `SymbolKind` (`Class`, `Enum`, `Function`, …); not a symbol → `node is not a symbol` |

```ms
export macro createStyles(sheet: Node): Node {
    const st = getTypeImpl(Style);          // TypeObject, no peel needed
    // st.typExprFieldNames / st.typExprFieldTypes / st.typExprFieldDecorators
}
```

Both hand back a **type-AST `Node`** (`TypeObject` / `TypeUnion` / `TypeArray` /
`TypeGeneric` / `Identifier` / literal kinds — see `mapTypeToAst` in
`src/compiler/meta/bridge.ms`), NOT the checker's internal `Type`. `std/meta`
declares `Node.nodeType: Type` because that is what the COMPILER stores; inside a
macro body the checker deliberately views it as `Node`, since that is what the VM
wire actually carries. Flat reads (`.typExprFieldNames`, `.discFieldName`, …)
resolve through the same unique-field-name rule as reads on the node itself.

`getTypeImpl(T)` resolves `T` in the **macro's declaring module** scope, not the
call site's, and is baked into the macro body once at compile time — so it is for
types the macro knows by name (a framework's own interface), not for per-call-site
generics. Unresolvable names are a compile error naming the macro.

Why it exists: a macro whose argument is a bare object literal —
`createStyles({ box: {...} })` — gets NO type from `arg.nodeType`, because the
literal has no contextual type at expand time. Before `getTypeImpl` the only way
to validate such a literal against an interface was to demand a witness parameter
from the caller, which framework-facing APIs cannot do.

`getTypeArg()` covers the codec shape — `decode<User>(s)` — where the type is the
caller's choice, not the macro's. It resolves in the call site's scope (that is
where the user spelled the name). Because the value differs per call site, the
macro body is baked into a CLONE and the compiled-macro cache is keyed by
(macro name, type argument); a name-only key would let the first instantiation
poison every later one (`fixedbugs/bug055.ms` pins exactly that).

```ms
export macro decode(s: Node): Node {
    const t = getTypeArg();                 // <User> at this call site
    // ... walk t.typExprFieldNames, emit per-field decode
}
const u = decode<User>(payload);
```

How the type argument gets there: the parser stores it on the Node itself
(`callNode.typeArg`, `parser/expressions/call.ms`), and the
CallExpr→MacroInvocation rewrite replaces only `node.data` — so it survives to
`expandMacroInvocation` untouched. `MacroInvocationData` never needed a slot for
it. (Older notes in this file called type args
unreachable; that was wrong — corrected 2026-07-27.)

⚠ V1 limits: exactly ONE type argument (`m<K, V>(...)` is a clear compile error,
not silent truncation), and a macro DECLARATION still cannot carry type params —
`macro m<T>(x: Node)` does not parse. `getTypeArg()` reads the call site, so no
declaration-side syntax is required.

### Binding symbols from a macro body (bindSym)

`bindSym` has two modes, picked by the shape of its argument (measured 2026-09-10):

| call | resolved in | when | name not found |
|---|---|---|---|
| `bindSym("name")` — a string literal | the scope where the MACRO is defined (module scope for a top-level macro) | once, when the body is baked; the baked body is cached per macro | compile error `Macro 'm': bindSym cannot resolve 'name' in the macro's module scope` |
| `bindSym(expr)` — anything else | the scope where the macro is EXPANDED: the call site's scope for an expression macro, the enclosing function's for a decorator on a nested class | at every expansion, while the macro runs | `null`, no error — test it (`if (s == null) error(...)`) |

The static form splices an Identifier that carries the resolved symbol itself — the
node arrives back in the checker with `NodeFlag.BoundSym` + `Node.resolvedSym`
set (bridge bound-symbol registry), and the checker uses that symbol instead of
looking the name up in the USER's scope. The reference implementation's static
model (a symbol node in the macro output; re-checked, never re-bound):

- the call site needs NO imports for names the macro emits;
- a user-local declaration of the same name CANNOT hijack the macro's callee
  (`fixedbugs/bug056.ms` pins both);
- non-exported helpers of the macro's own module are bindable.

```ms
import { cborText } from "./builder";   // the MACRO's module imports it once

export macro enc(t: Node): Node {
    return { kind: NodeKind.CallExpr, line: t.line, column: t.column,
        callee: bindSym("cborText"), arguments: [t] };
}
```

A string literal bakes once per macro body (`bakeTypeIntrinsics`); a name
computed at macro runtime goes through the dynamic form instead (the
atomic-builder dispatch in `std/serialize/cbor/encode.ms` predates it and keeps
static branches with one bindSym per candidate). Binding an overloaded name
binds the whole overload set; call-site scoring still picks the winner.
Unresolvable names are a compile error naming the macro in the static form and
`null` in the dynamic one. The dynamic form is what a decorator uses to look at
the scope it is expanded in — `bindSym("local" + "Count")` from a decorator on a
class declared inside a function finds that function's `localCount: int32`
(guard `decoratorNested`), while the literal form looks in the macro's own
module and does not.

Bound MACROS work too (V2): `bindSym("cborValueOf")` on a macro name carries the
macro symbol; expansion fetches the body/params from the DECLARING module's
registries (`expandMacroInvocation` regCtx via `lookupModuleCtx(sym.modulePath)`),
so a macro can emit calls to sibling macros the user never imported. A bound
identifier also survives passing THROUGH another macro as an argument — all
three serializers (`nodeToValue`, `readNodeFromObject`, `nodeToASTLiteral`)
carry `symHandle`. Net effect on the CBOR codec: the user imports exactly ONE
name (`cborEncode`).

⚠ Remaining limits: generic symbols are rejected in the static form
(monomorphization would redirect the bound symbol), and there is no gensym
hygiene yet — bindSym stops the USER capturing the MACRO's names, not the
macro's emitted locals shadowing the user's (build when a real consumer emits
locals).
- **quote is sugar** — everything `quote { }` does can be done with `createNode()`. Complex macros use createNode() for full control.
- **Raiser VM is sufficient** — executes MetaScript natively, ~0.5ms startup, negligible compile-time cost.
- **std/meta as stable API** — decouples macro authors from internal file paths.
