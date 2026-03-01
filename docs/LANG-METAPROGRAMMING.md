# MetaScript Metaprogramming

Compile-time code execution, AST manipulation, and code generation. Three tiers of capability, each building on the previous.

## Overview

```
Tier 1: @comptime { }          — compile-time evaluation (constants, config)
Tier 2: macro + quote { }      — AST-level code generation (@derive, custom transforms)
Tier 3: @target / @emit        — backend-specific code injection
```

All metaprogramming runs at **compile time** — zero runtime cost. The Raiser bytecode VM executes compile-time code in-process (~0.5ms startup).

## Tier 1: @comptime — Compile-Time Evaluation

**Status: DONE (MVP)**

Evaluate a block at compile time; the result replaces the block in the AST as a literal.

```ms
// Expression position — result folded into AST
const SIZE = @comptime { return 4 * 1024; };           // → 4096
const GREETING = @comptime { return "hello world"; };  // → "hello world"

// Local computation
const TABLE = @comptime {
    const items: number[] = [];
    let i = 0;
    while (i < 10) {
        items.push(i * i);
        i = i + 1;
    }
    return items;
};
// → [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]

// Objects
const CONFIG = @comptime {
    return { maxRetries: 3, timeout: 5000, debug: false };
};
```

### Supported return types

| Type | Example | AST Node |
|------|---------|----------|
| number | `return 42;` | NumberLiteral |
| string | `return "hello";` | StringLiteral |
| boolean | `return true;` | BooleanLiteral |
| null | `return null;` | NullLiteral |
| array | `return [1, 2, 3];` | ArrayLiteral |
| object | `return { x: 10 };` | ObjectLiteral |

### Pipeline position

```
Parse → Check → Transform → ComptimeEval → Analyze → Codegen
                                 ↑
                          evaluateComptimeBlocks()
                          walks AST, finds ComptimeBlock nodes,
                          evaluates via Raiser VM, replaces with literals
```

### Implementation

| File | Role |
|------|------|
| `src/ast/node.ms` | `NodeKind.ComptimeBlock`, `ComptimeBlockData { comptimeBody: Node }` |
| `src/parser/statements/core.ms` | Statement-level `@comptime { }` intercept |
| `src/parser/expressions/core.ms` | Expression-level `@comptime { }` in parsePrimary |
| `src/parser/statements/declaration.ms` | Fallback in parseMacroInvocation |
| `src/compiler/comptime.ms` | `evaluateComptimeBlocks()` — walker + evaluator |
| `src/codegen/raiser/eval.ms` | `evalASTFull()` — AST-based Raiser pipeline |

### Current limitations

- **Self-contained only** — no access to surrounding scope (`const N = 10; @comptime { return N; }` won't work)
- **Expression-position only** — statement-position @comptime (side effects) not yet handled
- **No imports** inside @comptime blocks
- **No type propagation** — checker sees @comptime result as `unknown`

### Planned enhancements

1. **Scope capture** — read surrounding `const` declarations (immutable values only)
2. **@comptime functions** — `@comptime function hash(s: string): number { ... }` evaluated at every call site
3. **Type inference** — run comptime eval during checking, propagate result type
4. **Statement-position** — `@comptime { assert(SIZE > 0); }` as compile-time assertions
5. **@compileError** — `@comptime { if (!valid) @compileError("bad config"); }` static error reporting

## Tier 2: Macros — AST Code Generation

**Status: Parsing DONE, expansion NOT YET**

User-defined compile-time functions that receive and transform AST nodes.

### macro declaration

```ms
macro deriveEq(target) {
    // target = the decorated class/interface AST node
    const fields = target.fields;

    const method = quote {
        equals(other: ${target.name}): boolean {
            return ${genFieldComparisons(fields)};
        }
    };

    target.addMethod(method);
    return target;
}
```

- `macro` keyword declares a compile-time function
- First parameter receives the decorated AST node
- Returns modified AST (or new AST via `quote`)
- Body executes in the Raiser VM at compile time

### macro invocation (as decorator)

```ms
@deriveEq
class Point {
    x: number;
    y: number;
}

// After expansion:
class Point {
    x: number;
    y: number;
    equals(other: Point): boolean {
        return this.x === other.x && this.y === other.y;
    }
}
```

### quote / unquote (quasiquotation)

```ms
// quote captures a block as an AST node (not executed)
const ast = quote { const x = 42; };

// ${expr} interpolation splices a computed AST into the template
const name = "count";
const init = quote { 0 };
const decl = quote { const ${name} = ${init}; };
```

- `quote { }` → `QuoteExpr` node, body stored as AST
- `${expr}` → interpolation, evaluated at macro expansion time, result spliced into quoted AST
- Self-hosted parser handles `quote { }` but `${}` interpolation is not yet implemented

### @derive — built-in attribute macros

```ms
@derive(Eq, Hash)
class Token {
    kind: TokenKind;
    value: string;
}
```

Built-in derive traits (planned):

| Trait | Generates | Notes |
|-------|-----------|-------|
| `Eq` | `equals(other): boolean` | Structural field-by-field comparison |
| `Hash` | `hash(): number` | FNV-1a over all fields |
| `Clone` | `clone(): T` | Deep copy |
| `Debug` | `toString(): string` | Debug string representation |
| `Serialize` | `toJSON(): string` | JSON serialization |

### Implementation plan

```
Phase 1: MacroExpander pass (walks AST, finds MacroInvocation → MacroDecl, expands)
Phase 2: quote { } expansion (QuoteExpr → cloned AST subtree)
Phase 3: ${} interpolation in quote blocks
Phase 4: Built-in @derive traits (Eq first, then Hash, Clone, Debug)
Phase 5: Standard library macros (std/macros/derive.ms)
```

| File | Role | Status |
|------|------|--------|
| `src/ast/node.ms` | `MacroDecl`, `MacroInvocation`, `QuoteExpr` NodeKinds | DONE |
| `src/parser/statements/declaration.ms` | `parseMacroDecl`, `parseMacroInvocation` | DONE |
| `src/parser/expressions/core.ms` | `quote { }` parsing | DONE |
| `src/checker/collectPass.ms` | Macro symbol registration | DONE |
| `src/compiler/macroExpand.ms` | Macro expansion pass | TODO |
| `src/compiler/quoteExpand.ms` | Quote/unquote expansion | TODO |

## Tier 3: Directives — Backend-Specific Control

**Status: Parsed + collected, expansion partial**

### @target — conditional compilation

```ms
@target("c") {
    extern function malloc(size: number): number;
    extern function free(ptr: number): void;
}

@target("js") {
    function allocate(size: number): number {
        return 0; // JS doesn't need manual allocation
    }
}
```

- Strips the block entirely if compiling for a different backend
- Parsed as `MacroInvocation` with block body
- Checker should strip mismatched blocks during collect pass

### @emit — inline code injection

```ms
@emit("#include <stdio.h>");

function print(msg: string): void {
    @emit("printf(\"%s\\n\", msg.data);");
}
```

- Injects raw backend code at the current position
- Backend-specific (C strings for C target, JS for JS target)
- Use sparingly — breaks portability

### @include / @link / @passC / @passL — build directives

```ms
@include("mylib.h");        // -I path for C compiler
@link("libcrypto.a");       // link library
@passC("-DDEBUG=1");        // pass flag to C compiler
@passL("-lssl");            // pass flag to linker
```

- Collected during checker Pass 1 (collectPass)
- Stored on `CheckerContext.compilerFlags`
- Forwarded to `compileCFile` / `linkObjects` in compile.ms

| Directive | collectPass field | Status |
|-----------|-------------------|--------|
| `@include("file")` | `ctx.includes` | DONE |
| `@link("lib")` | `ctx.links` | DONE |
| `@passC("flag")` | `ctx.compilerFlags` | DONE |
| `@passL("flag")` | `ctx.compilerFlags` | DONE |
| `@target("backend")` | strip/keep block | Parsed, expansion TODO |
| `@emit("code")` | inline injection | Parsed, expansion TODO |

## @comptime functions (future)

Decorator form — marks a function as compile-time-only:

```ms
@comptime
function fib(n: number): number {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

const FIB10 = fib(10);  // evaluated at compile time → 55
```

- Function body runs in Raiser VM when called with constant arguments
- Result folded into AST at every call site
- Non-constant arguments → compile error
- Enables: lookup tables, compile-time validation, const-evaluated configs

## Roadmap

```
DONE    @comptime { } expression-position MVP
        Parser for macro, quote, all directives
        collectPass for @include/@link/@passC/@passL
        @runtime/@builtin decorator handling

TODO    @comptime scope capture (read outer const)
        @comptime functions (decorator form)
        @comptime type propagation
        @target block stripping
        @emit code injection
        MacroExpander pass
        quote expansion (no interpolation)
        quote ${} interpolation
        @derive(Eq) built-in
        @derive(Hash, Clone, Debug, Serialize)
        std/macros/derive.ms (self-hosted derive)
        @compileError
        Statement-position @comptime
```

## Architecture Notes

### VM choice

The self-hosted compiler uses the **Raiser bytecode VM** for all compile-time execution. This differs from the reference compiler which uses Hermes (Facebook's JS engine). The Raiser VM:
- Starts in ~0.5ms (no JIT warmup)
- Executes MetaScript directly (no JS transpilation step)
- Shares the same AST/type infrastructure as the compiler
- Limitation: no network/filesystem access inside @comptime (reference compiler's Hermes has `fetch()`)

### Macro expansion pipeline position

```
Parse → Check → Monomorphize → MacroExpand → Transform → ComptimeEval → Analyze → Codegen
                                    ↑
                              Runs user macros (@derive etc.)
                              before transforms normalize AST
```

Macros run **after** type checking (so they can inspect types) but **before** transforms (so generated code goes through the full lowering pipeline).

### Hygiene

Macro-generated identifiers use `genSym()` to produce unique names (`__ms_derive_0`, `__ms_derive_1`, ...) avoiding conflicts with user code. Not full hygienic macros (Scheme-style) — uses name mangling similar to Rust's `proc_macro` approach.
