# MetaScript Metaprogramming

Compile-time code execution and AST manipulation. Macros are **normal MetaScript code** that imports from `std/metaprogramming` and runs in the Raiser bytecode VM during compilation. No special macro API — the compiler's own typed AST is the macro author's API.

## Core Principle: `Node` is Compile-Time Only

`Node` (from `std/metaprogramming`) is a **compile-time-only type** — like Nim's `NimNode`. Values of type `Node` exist only during compilation and are erased before codegen. Any `Node` remaining in the AST at codegen is a compile error.

Multiple sources produce `Node` values — all follow the same rules:

```ms
import { Node, NodeKind, createNode } from "std/metaprogramming";

// All of these produce Node — all compile-time only:
const el = <View><Text>hello</Text></View>;           // JSX → Node
const tmpl = quote { const x = 42; };                 // quote → Node
const node = createNode(NodeKind.BinaryExpr, ...);    // manual → Node

// Macros consume Node and return runtime AST:
const app = @jsx(el);              // Node → runtime code
const code = @inject(tmpl);        // Node → runtime code

// Same Node, different macros, different output:
const webApp = @webJsx(el);        // → DOM calls
const nativeApp = @nativeJsx(el);  // → UIKit calls

// Direct application (most common):
const app = @jsx <View><Text>hello</Text></View>;

// Macro pipelines — a macro can return Node (still compile-time), not just runtime:
const raw = <View><Text>{count()}</Text></View>;   // Node
const validated = @addAria(raw);                    // macro returns modified JSX → still Node
const optimized = @staticAnalysis(validated);       // macro returns modified JSX → still Node
const app = @render(optimized);                     // macro returns runtime code → Element
```

**One invariant: zero `Node` at codegen.** Everything else is free.

### How it works

1. **Checker** recognizes `Node` type as compile-time only (like Nim's `tfTriggersCompileTime` flag)
2. **Propagation** — any function/interface containing `Node` in its signature becomes compile-time only
3. **Macro expansion** (top-to-bottom) — when a macro argument is a const identifier whose initializer is a `Node` value, the initializer AST is inlined as the macro's argument
4. **Chaining** — if a macro returns a `Node` value (e.g. modified JSX), the result stays as a Node const, available for the next macro. If it returns runtime code, the result becomes runtime.
5. **Re-expansion** — after each macro expansion, the output is re-walked for nested macros/JSX (depth-limited)
6. **Erasure** — after all macros expand, `Node`-only const declarations are erased from the AST
7. **Safety net** — any `Node` surviving to codegen = compile error: *"compile-time Node not consumed by a macro"*

**Ordering constraint**: expansion processes declarations top-to-bottom. A Node const must be declared before it's referenced as a macro argument (same as Nim).

### Nim comparison

| | Nim | MetaScript |
|--|-----|-----------|
| Compile-time AST type | `NimNode` | `Node` |
| Enforcement | `tfTriggersCompileTime` flag propagates to containers/procs | Checker flag, same propagation |
| Backend safety | C/JS codegen emits hard error if NimNode leaks | Same |
| Storage scope | Only inside macros/`static` blocks | Also at module scope (const only) — slightly more permissive |
| Erasure | Implicit (macro bodies only generate VM bytecode) | Explicit (Node consts erased after expansion) |

The module-scope extension enables the "store and reuse" pattern (`const el = <View/>; @jsx(el); @native(el);`) that Nim doesn't support. Cost: ~15 lines of const-inlining logic in macro expansion.

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

`std/metaprogramming` re-exports `Node`, `NodeKind`, `createNode`, all `*Data` type aliases, `Type`, and `TypeKind` from compiler internals. Macro authors never import from `ast/node` directly.

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

### Planned enhancements

1. **Scope capture** — read surrounding `const` declarations (immutable values only)
2. **@comptime functions** — `@comptime function f(): number { ... }` evaluated at every call site
3. **Type inference** — propagate result type back to checker
4. **Statement-position** — `@comptime { assert(SIZE > 0); }` as compile-time assertions
5. **@compileError** — static error reporting from compile-time code

## Tier 2: Macros — Typed AST Manipulation

**Status: Parsing DONE, expansion NOT YET**

Macros receive `Node` values (AST), walk them node-by-node, analyze/reclassify/restructure, and return transformed AST. The compiler's own typed `Node` is the macro's input and output. `node.nodeType` gives type info after phase 2.

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

Macros can receive any `Node` type as argument — blocks, functions, expressions:

| Form | User writes | Macro receives |
|------|------------|----------------|
| Decorator | `@log class Foo {}` | `ClassDecl` node |
| Block | `@routes { GET "/" -> home; }` | `BlockStmt` node |
| Function | `@effect(() => { body })` | `ArrowFunction` node (params + body) |
| Expression | `@validate(x + y)` | `BinaryExpr` node |
| JSX | `@jsx <View>...</View>` | `JSXElement` node |
| Const ref | `@jsx(el)` where `const el = <View/>` | `JSXElement` node (inlined) |

The function form is particularly useful — the macro gets **parameter context** along with the body:

```ms
@effect((count: number) => {
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
import { Node, NodeKind, createNode, JSXElementData } from "std/metaprogramming";

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

The JSX parser produces its own AST nodes (JSXElement, JSXText, JSXExpressionContainer) — all `Node` values, compile-time only. The user's macro walks this tree and returns regular AST nodes that codegen understands:

```ms
function processJSXElement(node: Node, out: Node[], loc: SourceLocation): void {
    const jsx = node.data as JSXElementData;
    const tag = jsx.tagName;

    if (isBuiltInElement(tag)) {
        // <View>, <Text>, <Button>, <Image>, <ScrollView>
        processBuiltIn(tag, jsx.attributes, jsx.children, out, loc);
    } else {
        // <Counter>, <UserCard> — user component, call as function
        processComponent(tag, jsx.attributes, jsx.children, out, loc);
    }
}
```

**`processBuiltIn`** is the heart — classifies attributes and analyzes children:

```ms
function processBuiltIn(tag: string, attrs: Node[], children: Node[],
                         out: Node[], loc: SourceLocation): void {
    // 1. Create element
    out.push(makeVarDecl("el", makeCall("makeElement", [makeStr(tag, loc)], loc), loc));

    // 2. Classify attributes — route to different runtime APIs
    const animatable = extractAnimatable(attrs);   // opacity, scale, translateX
    const events = extractEvents(attrs);           // onPress, onScroll
    const remaining = extractRemaining(attrs);     // style, className, etc.

    // 3. Bind each category differently
    bindAnimatableProps(animatable, out, loc);      // -> bindStyleProp() subscription
    bindEventHandlers(events, out, loc);            // -> addEventListener()
    bindStaticProps(remaining, out, loc);            // -> bindProps()

    // 4. Process children — the key part
    let i = 0;
    while (i < children.length) {
        const child = children[i];

        if (child.kind === NodeKind.JSXText) {
            // Static text: "Add" — direct insertion, zero overhead
            out.push(makeCall("insertChild", [makeStr(child.text, loc), ident("el")], loc));

        } else if (child.kind === NodeKind.JSXExpressionContainer) {
            // Expression: {String(count())} — check for reactivity
            const expr = child.expression;

            if (containsReactiveCall(expr)) {
                // REACTIVE — wrap in createEffect
                out.push(wrapInEffect(expr, loc));
            } else {
                // STATIC expression — evaluate once
                out.push(makeCall("insertChild", [expr, ident("el")], loc));
            }

        } else if (child.kind === NodeKind.JSXElement) {
            // Nested element — recurse
            processJSXElement(child, out, loc);
        }
        i = i + 1;
    }
}
```

**`containsReactiveCall`** — the compile-time expression analyzer:

```ms
function containsReactiveCall(node: Node): boolean {
    if (node.kind === NodeKind.CallExpr) {
        const name = getCalleeName((node.data as CallExprData).callee);
        if (isReactiveSymbol(name)) return true;
    }
    if (node.kind === NodeKind.BinaryExpr) {
        const bin = node.data as BinaryExprData;
        return containsReactiveCall(bin.left) || containsReactiveCall(bin.right);
    }
    if (node.kind === NodeKind.MemberExpr) {
        return containsReactiveCall((node.data as MemberExprData).object);
    }
    return false;
}
```

`"Count: " + String(count())` contains `count()` which is reactive, so the whole expression gets wrapped in `createEffect`. `"Add"` is static text — no wrapping, zero overhead. This selective wrapping is only possible with compile-time AST analysis.

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

`quote` produces a `Node` value (compile-time only, same as JSX and `createNode`). Everything it does can be done with `createNode()` directly. Parser handles `quote { }` already; `${}` interpolation is TODO.

## Tier 3: Directives — Backend-Specific Control

**Status: Parsed + collected, expansion partial**

```ms
@target("c") { extern function malloc(size: number): number; }
@target("js") { function allocate(size: number): number { return 0; } }
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
| `@target("backend")` | Parsed, expansion TODO |
| `@emit("code")` | Parsed, expansion TODO |

## Tier 4: Intrinsics & Runtime Mapping

**Status: DONE**

While Tier 2 macros are user-defined, Tier 4 handles **compiler-intrinsic** logic and direct backend symbol mapping. This layer ensures that high-level MetaScript constructs are lowered into backend-primitive structures before reaching the "DUMB" codegen layer.

### @runtime("symbol") — External Symbol Mapping

Maps a MetaScript function or method directly to a literal symbol in the backend.

- **On Function**: Codegen uses the provided string as the literal C/JS function name, bypassing standard mangling.
- **On Method**: `builtinLower` intercepts calls to this method and rewrites them into direct calls (e.g., `console.log(s)` → `msPrintln(s)`).
- **Nim Parity**: Equivalent to `{.importc: "symbol".}`.

### @builtin("kind") — Structural Intrinsics

Identifies "magic" functions that require structural AST transformation rather than simple renaming.

- **Behavior**: `builtinLower` checks the `builtinKind` on the resolved symbol and performs a complex AST rewrite.
- **Example**: `Result.ok(val)` is marked `@builtin("msResultOk")`. The transformer expands this into an `ObjectLiteral` node: `{ ok: true, value: val }`.
- **Nim Parity**: Equivalent to Nim's `magic` system (e.g., `mResultOk`).

### Builtin Lowering (`src/transform/native/builtinLower.ms`)

The "Magic" expansion pass. It is the primary bridge between high-level semantics and backend primitives.

1. **Renaming**: Applies `@runtime` names definitively.
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

### Phase A: Node Serialization (Node <-> RaiserValue)

**Prerequisite for all macro expansion. Load-bearing for macro chaining** — without complete round-trip serialization, macros that return modified AST (not just runtime code) silently corrupt the tree. Must handle all NodeKinds, preserve SourceLocation and nodeType.

| Task | Description | Status |
|------|-------------|--------|
| A1 | `nodeToValue()` — recursive Node -> RaiserObject for all 62 NodeKinds | **DONE** |
| A2 | `valueToNode()` — extend beyond literals, reverse of A1 | TODO |
| A3 | Round-trip tests: node -> value -> node preserves structure | TODO |
| A4 | `typeToValue()` / `valueToType()` — serialize Type for nodeType access | TODO |

### Phase B: Macro Expansion Pass

**Core macro execution. Depends on Phase A.**

| Task | Description |
|------|-------------|
| B1 | Walk AST, find DecoratedDecl with MacroInvocation decorators |
| B2 | Macro lookup by name (same file, then imports) |
| B3 | Compile macro: parse -> check -> transform -> Raiser bytecode (cached) |
| B4 | Execute: serialize target, call in Raiser VM, deserialize result, splice |
| B5 | Re-expansion with depth limit (macros can generate macro invocations) |
| B6 | Node const inlining: resolve const identifiers to their Node initializers |
| B7 | Node const erasure: remove consumed Node-only declarations from AST |
| B8 | Safety check: error on any remaining Node values in AST |

**File:** `src/compiler/macroExpand.ms`

### Phase C: quote / unquote Interpolation

| Task | Description |
|------|-------------|
| C1 | Parser: `in_quote_context`, parse `${ expr }` as interpolation |
| C2 | Generate `__ms_interp_N` placeholder identifiers |
| C3 | Substitute placeholders with evaluated expressions at expansion time |

### Phase D: Utility Functions

| Task | Description |
|------|-------------|
| D1 | `genSym(prefix)` — unique identifier generation |
| D2 | `@compileError(msg)` — compile-time error reporting |
| D3 | `@comptime` scope capture — read surrounding const declarations |
| D4 | `walkNode(node, visitor)`, `mapNode(node, transform)` — traversal helpers |

### Phase E: Directives Expansion

`@target` block stripping, `@emit` code injection, `@comptime` functions, statement-position `@comptime`. Independent of macro expansion.

### Dependency Graph

```
A (serialization) -> B (expansion) -> C (quote interpolation)
D (utilities)    -- independent, parallel with B/C
E (directives)   -- independent, parallel with everything
```

## Key Design Decisions

- **`Node` is compile-time only** — same proven model as Nim's `NimNode`. JSX, `quote`, `createNode` all produce `Node`. Zero `Node` at codegen.
- **No special macro API** — compiler's own AST types are the API. Same proven approach as Haxe (10+ years production). No `MacroContext`, `ASTBuilder`, or `MacroTarget`.
- **Type-checked macros** — checker validates Node access, createNode() calls, `as` casts to `*Data` types before macro ever runs.
- **Module-scope Node consts** — extends Nim's model to allow `const el = <View/>` at top level, enabling reuse across multiple macros. Erased after expansion.
- **node.nodeType over Context.typeof()** — type info already on every Node after phase 2. No separate API call needed (simpler than Haxe).
- **quote is sugar** — everything `quote { }` does can be done with `createNode()`. Complex macros use createNode() for full control.
- **Raiser VM is sufficient** — executes MetaScript natively, ~0.5ms startup, negligible compile-time cost.
- **std/metaprogramming as stable API** — decouples macro authors from internal file paths.
