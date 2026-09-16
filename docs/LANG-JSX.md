# MetaScript JSX

JSX support in MetaScript. The parser produces dedicated AST nodes (`Node` values, compile-time only) that are consumed by user-written macros. The compiler has no opinion on what JSX means — a macro decides how to transform JSX into runtime code. This is more powerful than JavaScript's JSX, where the compiler hardcodes `React.createElement`.

JSX is one of several ways to produce `Node` values (alongside `quote { }` and `createNode()`). All follow the same compile-time-only rules — see `LANG-METAPROGRAMMING.md` for the full model.

## Syntax

Standard JSX, familiar to React/SolidJS developers:

```ms
// Elements with attributes
const ui = <View style={styles.container}>
    <Text>Hello, {name}</Text>
    <Button onPress={handleClick}>Click me</Button>
</View>;

// Self-closing
const img = <Image src={url} />;

// Fragments
const items = <>
    <Text>One</Text>
    <Text>Two</Text>
</>;

// Expressions in braces
const loading = <Text>{isLoading ? "Loading..." : data}</Text>;

// Spread attributes
const btn = <Button {...props}>Submit</Button>;

// Components (uppercase = component, lowercase = built-in)
const counter = <Counter initial={0} />;
```

All of the above are `Node` values — compile-time only, must be consumed by a macro before codegen.

## AST Nodes (6 NodeKinds)

### Elements and containers

| NodeKind | Data | Example |
|----------|------|---------|
| `JSXElement` | `{ jsxTag: string, jsxAttrs: Node[], jsxChildren: Node[], jsxSelfClosing: boolean }` | `<View style={s}>...</View>` |
| `JSXFragment` | `{ jsxFragChildren: Node[] }` | `<>...</>` |
| `JSXText` | `{ jsxText: string }` | `Hello, ` (raw text between tags) |
| `JSXExpressionContainer` | `{ jsxExpr: Node }` | `{count()}` |

### Attributes

| NodeKind | Data | Example |
|----------|------|---------|
| `JSXAttribute` | `{ jsxAttrName: string, jsxAttrValue: Node }` | `style={s}` |
| `JSXSpreadAttribute` | `{ jsxSpreadArg: Node }` | `{...props}` |

Each attribute is a regular `Node`. Two forms:

```ms
// Named attribute: jsxAttrName = "style", jsxAttrValue = expression node
<View style={styles.box} />

// Spread: jsxSpreadArg = expression node
<Button {...props} />
```

## Parsing

JSX parsing activates when the lexer encounters `<` in expression position followed by an identifier or `>` (fragment). The parser switches to JSX mode:

```
parsePrimary():
    if token === '<':
        if peek === '>':             // <> fragment
            return parseJSXFragment()
        if peek === Identifier:      // <View ...>
            return parseJSXElement()
```

### parseJSXElement

```
'<' tag attributes* ('/' '>' | '>' children* '<' '/' tag '>')

attributes:  name '=' '{' expr '}'     ->  JSXAttribute
             name '=' '"' string '"'   ->  JSXAttribute (string literal value)
             name                      ->  JSXAttribute (value = true)
             '{' '...' expr '}'        ->  JSXSpreadAttribute

children:    JSXElement                ->  nested element (recurse)
             '{' expr '}'             ->  JSXExpressionContainer
             raw text                  ->  JSXText (raw slice; consuming macro applies any whitespace rules)
```

### Disambiguation: `<` as less-than vs JSX

The parser uses context:
- In expression position after `=`, `(`, `[`, `return`, `,`, `?`, `:` -> JSX
- After an identifier or `)` -> less-than operator
- Same heuristic as TypeScript/Babel

## Usage: Macros Decide What JSX Means

JSX produces `Node` values (compile-time only). A macro transforms them into runtime code:

```ms
// Store as reusable compile-time template
const ui = <View style={s}>
    <Text>Count: {String(count())}</Text>
</View>;

// Different macros produce different output from same JSX:
const webApp = @webJsx(ui);       // → DOM manipulation
const nativeApp = @nativeJsx(ui); // → UIKit calls
const termApp = @termJsx(ui);     // → ANSI terminal

// Direct application (most common):
const app = @jsx <View><Text>hello</Text></View>;
```

See `LANG-METAPROGRAMMING.md` Tier 2 for the full JSX transform macro implementation.

### Reading JSX nodes inside a macro body (typed — 2026-07-26)

Macro params are typed from the macro declaration, and flat Node-field reads are
checked against the `NodeData` union by the DU access rule (LANG.md "unique field
name"): unique across variants → typed direct read; same name with different
types → must narrow; unknown field → compile error surfaced at the invocation
site as `Macro '<name>' body: ...`.

```ms
export macro element(n: Node): Node {
    n.jsxTag;                                  // string (unique → typed)
    n.line; n.column;                          // number (wire-universal)
    for (const a of n.jsxAttrs) {              // Node[]
        if (a.kind === NodeKind.JSXAttribute) {
            a.jsxAttrName.startsWith("on");    // string methods dispatch correctly
        }
    }
    n.bogusField;                              // ERROR: does not exist on type 'Node'
    n.value;                                   // ERROR: different types across variants — narrow first
}
```

The macro VM's wire format is FLAT: `n.data` is NOT populated inside macro bodies
— read payload fields directly on the node. Construction literals
(`{ kind, line, column, value }`) are key-checked against the same table.

### Component convention

Uppercase tag = component (user function), lowercase tag = platform element. The macro decides how to distinguish and compile them:

```ms
// Components are regular MetaScript functions:
function Counter(props: { initial: number }): Element {
    const count = signal(props.initial);
    return @jsx <View>
        <Text>Count: {String(count())}</Text>
        <Button onPress={() => count.set(count() + 1)}>
            <Text>+</Text>
        </Button>
    </View>;
}

// Usage:
const app = @jsx <Counter initial={0} />;
```

## Boundary Lowering via Converter (IMPLEMENTED 2026-07-31 — main `9ce47eb`, guards in `src/test/c/converter.ms`; build.ms global-import tier awaits build.ms globalImports wiring)

Decided 2026-07-30. JSX remains a free compile-time value —
held in consts, passed through macros, produced by macros — and is implicitly lowered ONLY when
it reaches a runtime-typed boundary. Mechanism: the `converter` routine kind (LANG.md
"Converter Declarations").

```ms
// UI library side — element becomes a converter instead of a plain macro:
export converter element(node: Node): VNode { ... }

// user code — React-style, no explicit element() anywhere:
function Counter(props: CounterProps): VNode {
  return <p>n = {props.count()}</p>;   // return type VNode -> converter applies
}
const view: VNode = <div/>;            // annotated decl -> applies
render(<App/>, host, root);            // resolved param type -> applies

const ui = <h1>raw</h1>;               // no boundary -> stays a compile-time Node
const ok = validateA11y(ui);           // macros still receive RAW JSX (param type Node)
```

- **Trigger** = expression of compile-time Node kind at a settled expected-runtime-type
  position. Not name-based; no framework type is hardcoded — the expansion is re-checked
  normally, so whatever the in-scope converter produces must fit the position.
- **Nullable slots** (2026-09-13): a converter declared for `T` also serves a `T | null` position (optional field, nullable parameter or declaration); the expansion is re-checked against the full slot, so the value wraps like any `T → T | null` flow.
- **Precedence**: explicit call > module-imported converter (scope shadowing) > build.ms
  global import > none -> today's "unconsumed JSX" error, message extended with an import hint.
- **Component convention** (uppercase tag -> component) is the converter body's job, unchanged.
- **What gets emitted** (VNode tree vs direct host calls) is the converter body's decision,
  not the language's. A V1 UI library emits the VNode layer (host-agnostic: dom/terminal/void/mock +
  renderToString); direct-emit is a named later optimization tier (per-target converter via
  build.ms).
- **V1 limit**: splicing a held JSX const INSIDE other JSX (`<div>{header}</div>` with
  `header: Node`) is not covered — the converter sees an identifier child and emits the
  runtime path. nodeType-aware splice is V2 (unlocked by A4 `nodeType` reads).

Status: design locked; implementation sequenced after a thunk-field closure miscompile that
blocked component props (2026-07-30).

## Implementation Status

JSX is wired end-to-end: `.ms` source → tokens → AST → checker → macro-expand → native binary.
Verified natively 2026-07-10 (`jsxMacroNative.ms` / `jsxDomNative.ms` both `PASS`).

```
DONE    AST: 6 NodeKind + NodeData variants + *Data aliases + createNodeAt overloads (std/meta/node.ms)
        Printer: 6 exhaustive arms (src/ast/printer.ms) — verified rendering a tree at runtime
        Node walkers: visitor.ms, walker.ms, hash.ms all handle the 6 kinds
        Lexer: src/lexer/jsx.ms mode machine — 3 JSX tokens + `<` disambiguation (26 tests)
        Parser: src/parser/expressions/jsx.ms — all 6 JSX kinds (18 parser tests)
        Checker: src/checker/checkExprPass.ms — JSX typed compile-time Node, unconsumed JSX
                 rejected ("consumed by a macro"), jsxMacroArgDepth leak guard, tag-name LSP symbols
        Bridge: nodeToValue / valueToNode round-trip (src/compiler/meta/bridge.ms)
        Macro walker: expand.ms addKindFields + nodeKindOrdinal table; macro bodies navigate JSX
                      array fields (for..of, indexing, .length)
        Reference macro + examples: std/meta/jsxDom.ms (JSX → el()/txt()/attr()) + 4 native
                      programs (jsxLex/Parse/Macro/DomNative) in the native manifest
        Design: attribute nodes, expression containers, fragments, compile-time-only Node model

TODO    Editor/compiler parity CI corpus (Phase 8) — the compiler-side corpus exists; only the
        tree-sitter↔compiler cross-check that fails on divergence is still open
```

> Note: the compiler binary shipped at `bin/msc` may lag the source — if `msc dump-ast`
> reports "Unexpected token: <", rebuild via `rm -rf out && msc test src/index.ms`
> and use the freshly built `./msc` (or copy it to `bin/msc`).
