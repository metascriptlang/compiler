# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

## Build Commands

```bash
# Run all tests (ALWAYS rm out/ first — stale artifacts cause false passes)
rm -rf out && msc test src/index.ms

# Run without tests
msc run src/index.ms

# Rebuild reference compiler (ALWAYS rm .zig-cache when changing shared sources)
cd ~/projects/metascript && rm -rf .zig-cache && zig build install
```

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 Analyzer] --> [5 Codegen] --> output
```

- Phase 1 (Parse): COMPLETE -- 37 NodeKind, 80+ TokenKind, recursive descent + Pratt precedence
- Phase 2 (TypeCheck): COMPLETE single-module -- 3-pass (collect, resolve, check). Cross-module deferred.
- Phases 3-5: NEXT -- transforms, analyzer injection, codegen

## Project Structure

```
src/
  index.ms                          -- entry point + smoke tests
  ast/     node.ms                  -- NodeKind(37), NodeData, Node, 50+ type aliases
           printer.ms               -- debug printer (exhaustive match)
  lexer/   token.ms                 -- TokenKind(80+), identToKeyword
           scanner.ms               -- core lexer (char scanning)
           lexer.ms                 -- lex() main function
           state.ms / chars.ms      -- lexer state machine, char classification
  parser/  context.ms               -- ParserState, peek, advance
           typeAnnotation.ms        -- type annotation parser
           expressions/core.ms      -- parseExpression (Pratt precedence)
           expressions/call.ms      -- call, member access, array access
           expressions/arrow.ms     -- arrow functions
           expressions/object.ms    -- object/array literals
           expressions/match.ms     -- match expressions
           statements/core.ms       -- parseProgram, parseBlock, parseStatement
           statements/declaration.ms -- functions, classes, interfaces, enums, imports
           statements/control.ms    -- loops, break, continue, switch
           statements/errorHandling.ms -- try/catch/finally, throw
           statements/callbacks.ms  -- callback injection (breaks circular imports)
  checker/ types.ms                 -- TypeKind(27), flat Type interface, constructors
           symbol.ms                -- SymbolTable, Scope chain, Symbol
           context.ms               -- CheckerContext, error collection
           collectPass.ms           -- Pass 1: collect declarations
           resolvePass.ms           -- Pass 2: resolve type annotations
           checkPass.ms             -- Pass 3: type inference + validation
           compat.ms                -- type compatibility (isAssignable)
  utils/   string.ms                -- string utilities (no indexOf/includes)
  diagnostics/ diagnostics.ms       -- error formatting
```

## Architecture Patterns

### Hub re-exports
Each module directory has `index.ms` that re-exports the public API. Import directly or from hub.

### Callback injection (circular import breaker)
`callbacks.ms` holds function pointers. `core.ms` registers real implementations at module load.
Sub-parsers import from `callbacks.ms` only -- no cycles.

### Flat Type interface (not discriminated union)
Avoids reference compiler codegen bugs with self-referencing anonymous structs. All fields present; unused fields empty/null.
Fields: `kind`, `typeName`, `typeNames`, `typeChildren`, `typeReturn`, `typeExtra`, `typeFlags`.

### Testing
Each .ms file has inline tests via `testGroup` + `test` + `check` from `std/testing`. 93 test groups across 24 files.

## Writing Idiomatic MetaScript

MetaScript looks like TypeScript but has key semantic differences. Full reference: `docs/LANG.md`.

### Match Expressions (use instead of switch, and often instead of if-else)

MetaScript's most distinctive feature. Prefer match over if-else chains for dispatching on enum, string, or number values.

```ms
// Expression form — returns a value, semicolon after closing brace
return match (kind) {
    TokenKind.Plus | TokenKind.Minus => "additive",
    TokenKind.Star => "multiplicative",
    _ => "unknown",
};

// Block arms — last expression is the return value (no explicit return)
return match (ch) {
    "n" => "\n",
    "t" => "\t",
    _ => { let s = "\\"; s + ch },
};

// Statement form with side effects
match (node.kind) {
    NodeKind.BlockStmt => { walkBlock(node); },
    NodeKind.IfStmt => { walkIf(node); },
    _ => {},
};
```

Key rules:
- `_` is the wildcard (NOT `default`)
- `|` for alternatives: `TokenKind.A | TokenKind.B => ...`
- `when` for guards: `x when (x > 10) => handleLarge(x)`
- Bare identifiers are always BINDINGS, never value comparisons -- `x =>` captures, does not compare
- Block arms return their last expression implicitly (no `return` keyword)
- **try in match arms FAILS** -- use if-else when you need `try`
- **break/continue in match arms** target the generated switch, not enclosing loops
- **C-style `for` in match arms FAILS** -- `for (let i = 0; ...)` isn't normalized inside match-lowered blocks. Use `while` loops instead. `for..of` works fine.

When to use if-else instead: complex nested conditions, mutation-heavy loops with state, or any arm needing `try`.

### Result<T, E> + try Operator (Rust-style error handling)

```ms
type ExprResult = Result<Expression, string>;

function parse(state: ParserState): ExprResult {
    const left = try parsePrimary(state);    // unwraps or early-returns error
    return Result.ok(left);
}

// try with catch — unwrap or use fallback
const value = try divide(10, 0) catch 0;

// Manual Result checking (when you need both branches)
const result = parseSource(input);
if (!result.ok) return Result.err(result.error);
const program = result.value;
```

Key fields: `result.ok` (boolean), `result.value` (T), `result.error` (E).

### interface = Concrete Data Struct (NOT a behavioral contract)

In MetaScript, `interface` declares a value type with fields. It is NOT an abstract contract like in TypeScript.

```ms
interface Token {
    kind: TokenKind;
    value: string;
    line: number;
    column: number;
}

// Constructed as object literals
function createToken(kind: TokenKind, val: string, line: number): Token {
    return { kind, value: val, line, column: 0 };
}
```

Interfaces are passed by value (copied in C backend). No methods, no inheritance dispatch.

### "a".code — Compile-Time Character Codes

```ms
// Zero runtime cost — folded to number at compile time
function isDigit(ch: number): boolean {
    return ch >= "0".code && ch <= "9".code;
}

// Works in match patterns too
return match (escChar) {
    "n" => "\n",
    "t" => "\t",
    _ => escChar,
};
```

### Type Aliases and Function Types

```ms
type ExprResult = Result<Expression, string>;
type BlockParserFn = (state: ParserState) => ExprResult;
type Visitor = (node: Node) => Node;
```

### Inline Tests

Every .ms file contains its own tests. Tests are stripped from non-test builds.

```ms
import { test, check, testGroup } from "std/testing";

testGroup("Char Classification", () => {
    test("isDigit", () => {
        check(isDigit("0".code));
        check(!isDigit("a".code));
    });
});
```

`check()` = non-fatal assertion, `require()` = fatal assertion.

### Null Representation

MetaScript has no `undefined`. Use `null` with type assertion for nullable fields:

```ms
const scope: Scope = { symbols: [], parent: null as unknown as Scope };
```

The `null as unknown as T` idiom is the standard way to express nullable typed fields.

### enum (C-style integer enums)

```ms
export enum NodeKind {
    NumberLiteral, StringLiteral, BooleanLiteral,
    // ...
}
// Access: NodeKind.NumberLiteral
// Compare: node.kind === NodeKind.NumberLiteral
```

### Discriminated Unions via type alias

```ms
export type NodeData =
    | { value: number }                                  // NumberLiteral
    | { operator: string, left: Node, right: Node }      // BinaryExpr
    | { statements: Node[] }                             // BlockStmt
    ;

// Narrow with `as`:
const d = node.data as BinaryExprData;
const left = d.left;
```

### Other MetaScript-Specific Syntax

- **move** -- ownership transfer: `return move data;`
- **defer** -- scope-exit cleanup: `defer cleanup();` (LIFO order, always runs)
- **unreachable** -- impossible path marker: `unreachable;`
- **out parameters** -- `function parse(input: string, out result: AST): boolean`
- **distinct type** -- nominal typing: `distinct type UserId = number;`
- **extern** -- C FFI: `extern function printf(fmt: string): void;`
- **Decorators** -- `@derive(Eq, Hash)`, `@comptime`, `@target("c")`, `@emit("...")`
- **Sized integers** -- `int8`, `int16`, `int32`, `int64`, `uint8`-`uint64`, `float32`, `float64`

### Loop Constraints

| Context | `for..of` | `for (let i…)` | `while` |
|---------|-----------|-----------------|---------|
| Top-level / function body | OK | OK | OK |
| Match arms | OK | **FAILS** (not normalized) | OK |
| Closures / callbacks | OK (read-only) | OK | OK |

Rule of thumb: inside match arms, use `while` or `for..of` — never C-style `for`.

### Common Pitfalls for TypeScript Developers

1. `interface` is a data struct, not a behavioral contract -- no `implements`, no method dispatch
2. `type` is a reserved keyword -- use `tokenType`, `nodeType` for variable names
3. No `indexOf`/`includes` on strings -- use `slice`, `length`, `findChar`, `charAt` from `utils/string.ms`
4. `string[]` is a value type -- `push()` inside functions does not propagate to caller (wrap in interface)
5. Match `_` is the wildcard, not `default`; bare identifiers are bindings, not comparisons
6. `null as unknown as T` is the null pattern, not `undefined`
7. `for (const x of arr)` works, but `for..in` is rarely used -- prefer `while` with index for mutation

## Reference Compiler Gotchas (Bugs Affecting All .ms Code)

These are NOT design choices -- they are reference compiler codegen bugs you MUST work around:

1. **NEVER** `let x; x = try f();` -- analyzer destroys the intermediate Result, use-after-free. Use `const x = try f();`
2. **NEVER** pass `makeSymbol(...)` or fresh interface as function arg -- analyzer double-frees. Store in local `const` first, or create inside the callee.
3. **ALWAYS** use `const x = try f();` with immediate use in the return expression.
4. **string[] is VALUE TYPE** -- `push()` inside functions does not propagate to caller. Inline loops or wrap in interface.
5. **try inside match arms** -- emits `/* unsupported: try_expr */`. Avoid.
6. **break/continue in match arms** -- targets the switch, not the enclosing loop.
7. **Standalone `try f();` in while loop** -- analyzer scope bug, all outer variables become undeclared. Use `advance()` instead.
8. **No indexOf/includes** -- use `slice`, `length`, `findChar`, `charAt` from `utils/string.ms`.
9. **`type` is reserved** -- use `tokenType`, `nodeType`, etc.
10. **Circular imports silently drop** -- keep mutually recursive functions in the same file.
11. **C-style `for` in match arms** -- `for (let i = 0; ...)` hits codegen unreachable inside match block arms (not normalized). Use `while` loop or `for..of` instead.

## Match Expression Rules

- String/number/enum literals as patterns: WORKS
- Block arms with side effects: WORKS (`return match (x) { p => { sideEffect(); value } }`)
- `"a".code` in patterns: WORKS
- `try` in match arms: FAILS
- Bare identifiers in patterns are always BINDINGS (not value comparison)
- `|` for alternatives: `1 | 2 | 3 => ...`

## Reference Compiler Locations

- `/Users/le/projects/metascript/` -- Zig-based reference compiler
  - `src/codegen/c/cgen.zig`, `src/transform/drc_inject.zig`, `src/transform/pipeline.zig`
- `/Users/le/projects/nim/compiler/` -- Nim reference
  - `transf.nim`, `lambdalifting.nim`, `injectdestructors.nim`

## Backends

- **C**: Primary. Deterministic memory management, lifecycle hooks, compile via clang. Phase 4 (Analyzer) required.
- **JavaScript**: Secondary. No analyzer needed, direct JS emission. Simpler codegen path.
- **Erlang**: POSTPONED.

## Next Phase: Transforms (Phase 3)

Priority order: `result_desugar`, `match_lower`, `defer_lower`, `for_of_lower`, `optional_chain`, `nullish_coalesce`, `type_coercion`, `lambda_lifting`, `liftdestructors`.
Simple fixed-order runner first, pluggable pipeline later.
