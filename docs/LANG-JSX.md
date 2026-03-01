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
             raw text                  ->  JSXText (whitespace-trimmed)
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

## Implementation Status

```
DONE    NodeKind planned: JSXElement, JSXFragment, JSXText, JSXExpressionContainer
        Design: attribute nodes, expression containers, fragment syntax
        Design: Node as compile-time-only type, macro consumption model

TODO    Parser: JSX lexer mode, parseJSXElement, parseJSXFragment
        AST: Add 6 NodeKind members + NodeData variants + *Data type aliases
        Checker: recognize Node as compile-time only (tfTriggersCompileTime equivalent)
        Macro expansion: Node const inlining + erasure (see LANG-METAPROGRAMMING.md Phase B)
```
