# MetaScript Language Reference

MetaScript is a systems programming language with TypeScript syntax that compiles to C, JavaScript, and Erlang. This document covers all syntax the self-hosted compiler must handle.

## Primitive Types

| Type | Description | C Mapping |
|------|-------------|-----------|
| `number` | IEEE 754 f64 | `double` |
| `string` | Mutable UTF-8 (TS superset) | `msString` |
| `boolean` | true/false | `bool` |
| `void` | No value | `void` |
| `never` | Unreachable | N/A |
| `null` | Null value | `NULL` |
| `undefined` | Undefined | `NULL` |
| `unknown` | Type-safe any | `void*` |

### Sized Integer Types

| Type | Size | Signed | C Mapping |
|------|------|--------|-----------|
| `int8` | 8-bit | yes | `int8_t` |
| `int16` | 16-bit | yes | `int16_t` |
| `int32` | 32-bit | yes | `int32_t` |
| `int64` | 64-bit | yes | `int64_t` |
| `uint8` | 8-bit | no | `uint8_t` |
| `uint16` | 16-bit | no | `uint16_t` |
| `uint32` | 32-bit | no | `uint32_t` |
| `uint64` | 64-bit | no | `uint64_t` |

### Float Types

| Type | Size | C Mapping |
|------|------|-----------|
| `float32` / `float` | 32-bit | `float` |
| `float64` / `double` | 64-bit | `double` |

## Keywords (99 total)

### JavaScript/TypeScript Keywords
```
break    case     catch    class    const    continue
debugger default  delete   do       else     enum
export   extends  false    finally  for      function
if       import   in       instanceof        interface
let      new      null     return   super    switch
this     throw    true     try      typeof   var
void     while    with
```

### TypeScript-Specific Keywords
```
abstract  as        asserts   async     await     yield
constructor          declare   from      get       implements
infer     is        keyof     namespace never     of
private   protected public    readonly  require   set
static    type      unknown
```

### MetaScript-Specific Keywords
```
match     when      unreachable
defer     distinct  move      out
macro     quote     extern
int8      int16     int32     int64
uint8     uint16    uint32    uint64
float32   float64   int       float     double
```

## Operators

### Arithmetic
| Operator | Token | Description |
|----------|-------|-------------|
| `+` | PLUS | Addition / string concat |
| `-` | MINUS | Subtraction / negation |
| `*` | STAR | Multiplication |
| `/` | SLASH | Division |
| `%` | PERCENT | Modulo |
| `**` | STAR_STAR | Exponentiation |

### Assignment
| Operator | Token | Description |
|----------|-------|-------------|
| `=` | EQUALS | Assignment |
| `+=` | PLUS_EQUALS | Add-assign |
| `-=` | MINUS_EQUALS | Sub-assign |
| `*=` | STAR_EQUALS | Mul-assign |
| `/=` | SLASH_EQUALS | Div-assign |
| `%=` | PERCENT_EQUALS | Mod-assign |

### Comparison
| Operator | Token | Description |
|----------|-------|-------------|
| `==` | EQ_EQ | Loose equality (compile-time macro) |
| `===` | EQ_EQ_EQ | Strict equality |
| `!=` | BANG_EQ | Loose inequality |
| `!==` | BANG_EQ_EQ | Strict inequality |
| `<` | LT | Less than |
| `<=` | LT_EQ | Less or equal |
| `>` | GT | Greater than |
| `>=` | GT_EQ | Greater or equal |

### Logical
| Operator | Token | Description |
|----------|-------|-------------|
| `&&` | AMP_AMP | Logical AND |
| `\|\|` | PIPE_PIPE | Logical OR |
| `!` | BANG | Logical NOT |

### Bitwise
| Operator | Token | Description |
|----------|-------|-------------|
| `&` | AMP | Bitwise AND |
| `\|` | PIPE | Bitwise OR |
| `^` | CARET | Bitwise XOR |
| `~` | TILDE | Bitwise NOT |
| `<<` | LT_LT | Left shift |
| `>>` | GT_GT | Right shift |
| `>>>` | GT_GT_GT | Unsigned right shift |

### Update
| Operator | Token | Description |
|----------|-------|-------------|
| `++` | PLUS_PLUS | Increment |
| `--` | MINUS_MINUS | Decrement |

### Special Operators
| Operator | Token | Description |
|----------|-------|-------------|
| `?` | QUESTION | Ternary / optional |
| `??` | QUESTION_QUESTION | Nullish coalescing |
| `?.` | QUESTION_DOT | Optional chaining |
| `.` | DOT | Member access |
| `...` | DOT_DOT_DOT | Spread / rest |
| `=>` | ARROW | Arrow function |
| `\|>` | PIPE_GT | Pipeline operator |

### Punctuation
| Token | Description |
|-------|-------------|
| `(` `)` | Parentheses |
| `{` `}` | Braces |
| `[` `]` | Brackets |
| `;` | Semicolon |
| `:` | Colon |
| `,` | Comma |
| `@` | At sign (decorators) |

## Literals

### Numbers
```typescript
42              // Integer
3.14            // Float
1_000_000       // Underscore separator
0xFF            // Hex (0x prefix)
0b1010          // Binary (0b prefix)
0o777           // Octal (0o prefix)
1e10            // Exponent
1.5e-3          // Float with exponent
123n            // BigInt (n suffix, integers only)
```

### Strings
```typescript
"hello"         // Double-quoted
'world'         // Single-quoted
"line\nnext"    // Escape sequences: \n \t \r \\ \" \'

// Character code (compile-time fold, single-char literal only)
"a".code        // → 97 (zero runtime cost)
"\n".code       // → 10 (works with escapes)
```

### Template Literals
```typescript
`hello`                      // No substitution
`hello ${name}`              // With expression substitution
`${a} + ${b} = ${a + b}`    // Multiple substitutions
```

### Backtick-Escaped Identifiers
```typescript
`if`            // Use reserved word as identifier
`my-var`        // Use invalid identifier chars
```

### Boolean / Null
```typescript
true  false
null  undefined
```

## Declarations

### Variables
```typescript
const x = 42;                    // Immutable binding
const x: number = 42;            // With type annotation
let y = "hello";                 // Mutable binding
let y: string = "hello";         // With type annotation
var z = true;                    // Function-scoped (legacy)
```

### Functions
```typescript
function add(a: number, b: number): number {
    return a + b;
}

// Arrow functions
const add = (a: number, b: number): number => a + b;
const greet = (name: string): void => { console.log("hi " + name); };

// Async functions
async function fetch(url: string): Promise<string> { ... }

// Generator functions
function* range(n: number): Generator<number> { ... }
```

### Extension Methods

```typescript
// Instance extension — adds method to existing type via `this` receiver
function trim(this s: string): string { ... }
"hello ".trim();  // → trim("hello ")

// Generic instance extension
function push<T>(this arr: T[], elem: T): void { ... }
names.push("alice");  // T inferred as string from receiver

// Static extension — namespace method via `this typeof`
function floor(this typeof Math, x: number): number { ... }
Math.floor(3.7);  // → floor(3.7), receiver not passed
```

Instance: receiver prepended as first arg at call site. Static: receiver stripped, just a namespaced call.

### Classes
```typescript
class Point {
    x: number;
    y: number;

    constructor(x: number, y: number) {
        this.x = x;
        this.y = y;
    }

    distance(): number {
        return Math.sqrt(this.x * this.x + this.y * this.y);
    }
}

// Inheritance
class Point3D extends Point {
    z: number;
    constructor(x: number, y: number, z: number) {
        super(x, y);
        this.z = z;
    }
}

// Access modifiers
class Service {
    private key: string;
    protected data: number;
    public name: string;
    readonly id: number;
    static count: number;
}
```

### Interfaces
```typescript
interface Shape {
    area(): number;
    perimeter(): number;
}

// With properties
interface Point {
    x: number;
    y: number;
    label?: string;        // Optional property
}

// Extends
interface Circle extends Shape {
    radius: number;
}
```

### Enums
```typescript
enum Color {
    Red,
    Green,
    Blue,
}

// With explicit values
enum Status {
    Active = 1,
    Inactive = 0,
}
```

### Type Aliases
```typescript
type ID = number;
type StringOrNumber = string | number;
type Callback = (data: string) => void;
type Pair<T> = { first: T; second: T };
```

### Import / Export
```typescript
// Named imports
import { Token, formatToken } from "./lexer/token";

// Default import
import Parser from "./parser";

// Namespace import
import * as utils from "./utils";

// Named exports
export function helper(): void { }
export interface Config { debug: boolean; }
export type ID = number;

// Default export
export default class App { }

// Re-exports
export { Token } from "./lexer/token";
export * from "./utils";
```

## Statements

### Control Flow
```typescript
// If/else
if (condition) { ... }
if (condition) { ... } else { ... }
if (a) { ... } else if (b) { ... } else { ... }

// While
while (condition) { ... }

// For (C-style)
for (let i = 0; i < n; i++) { ... }

// For-of
for (const item of items) { ... }
for (const [key, value] of map) { ... }

// Switch
switch (expr) {
    case value1: ...; break;
    case value2: ...; break;
    default: ...;
}

// Return
return;
return expr;

// Break / Continue
break;
continue;

// Throw
throw new Error("message");
```

### Try/Catch/Finally
```typescript
try {
    riskyOperation();
} catch (e) {
    handleError(e);
} finally {
    cleanup();
}
```

## Type System

### Type Annotations
```typescript
const x: number = 42;
function f(a: string, b: number): boolean { ... }
const arr: number[] = [1, 2, 3];
const tuple: [string, number] = ["hello", 42];
const map: Map<string, number> = new Map();
const set: Set<number> = new Set();
```

### Generics
```typescript
function identity<T>(x: T): T { return x; }
class Container<T> { value: T; }
interface Comparable<T> { compareTo(other: T): number; }

// Constraints
function longest<T extends { length: number }>(a: T, b: T): T { ... }

// Default type parameters
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };

// Const generics
class Matrix<const ROWS: int32, const COLS: int32> {
    getTotalElements(): int32 { return ROWS * COLS; }
}
```

### Union & Intersection Types
```typescript
type StringOrNumber = string | number;
type Shape = Circle & Drawable;

// Discriminated unions
type Result<T, E> =
    | { ok: true; value: T }
    | { ok: false; error: E };
```

### Utility Types
```typescript
Partial<T>           // All properties optional
Required<T>          // All properties required
Readonly<T>          // All properties readonly
Record<K, V>         // Object type with keys K and values V
Pick<T, K>           // Subset of properties
Omit<T, K>           // Exclude properties
```

### Conditional Types
```typescript
type IsString<T> = T extends string ? true : false;
type UnwrapPromise<T> = T extends Promise<infer U> ? U : T;
```

### Mapped Types
```typescript
type MyPartial<T> = { [K in keyof T]?: T[K] };
type Nullable<T> = { [K in keyof T]: T[K] | null };
```

### Type Assertions
```typescript
const data = expr as { value: number };   // Type narrowing (borrow, no copy)
const len = (x as string).length;
```

## MetaScript-Specific Syntax

### Move Semantics
```typescript
// Transfer ownership — source is zeroed, no copy
const y = move x;        // y owns the data, x is zeroed (wasMoved)
return move data;         // caller takes ownership, local zeroed
consume(move buffer);     // callee takes ownership

// Without move: analyzer decides sink vs copy via last-read analysis
// With move: forces sink path, source always zeroed
```

### Defer
```typescript
// Execute at scope end (LIFO order)
function process(): void {
    const buf = allocate(1024);
    defer free(buf);           // Always runs when scope exits

    if (error) return;         // defer still runs
}
```

### Match Expression
```typescript
// Expression match (pure return values)
return match (escChar) {
    "n" => "\n",
    "t" => "\t",
    _ => escChar,
};

// Statement match with side effects (generates native C switch)
match (ch) {
    "(".code => { advanceChar(s); addToken(s, LParen); return true; },
    ")".code => { advanceChar(s); addToken(s, RParen); return true; },
    _ => { return false; },
};

// Destructuring
match (result) {
    { ok: true, value: v } => process(v),
    { ok: false, error: e } => handleError(e),
}

// Or-patterns and guards
match (token.kind) {
    TokenKind.Plus | TokenKind.Minus => parseBinary(),
    x when (x > 10) => handleLarge(x),
    _ => defaultCase(),
}
```

### Result Type & Try Operator
```typescript
function divide(a: number, b: number): Result<number, string> {
    if (b === 0) return Err("division by zero");
    return Ok(a / b);
}

// Try: unwrap or early-return error
const result = try divide(10, 2);

// Try with catch: unwrap or use default
const value = try divide(10, 0) catch 0;
```

### Decorators & Directives

Both use `@` syntax. Semicolon disambiguates:
- **Decorator** = `@name(...) decl` — attaches to next declaration
- **Directive** = `@name(...);` — standalone statement (ends with `;`)

#### Decorators (attach to declarations)

```typescript
// Bind to C runtime function — codegen emits c_name as a plain call
@runtime("ms_println")
function log(value: string): void { unreachable; }
// log("hi") → ms_println("hi")

// On class methods (declared in std/core.ms prelude)
class console {
	@runtime("ms_println")
	log(value: string): void { unreachable; }
}
// console.log("hi") → ms_println("hi")

// Compiler intrinsic — builtinLower rewrites AST inline
// Can emit anything: field access, operators, multi-statement patterns
@builtin("LengthStr")
export function len(s: string): number;
// len(s) → ms_string_length(s)  (or future: s->len)

// Multiple decorators stack
@runtime("ms_floor")
@inline
export function floor(x: number): number { unreachable; }
```

| Decorator | Applies To | Purpose | Status |
|-----------|-----------|---------|--------|
| `@runtime("c_name")` | function, method | Bind to C runtime function (always a function call) | DONE |
| `@builtin("Name")` | function, method | Compiler intrinsic (inline codegen, no function call) | DONE (stub) |
| `@derive(Trait, ...)` | class, interface | Auto-generate methods (Eq, Hash, Clone, Debug) | PLANNED |
| `@comptime` | block | Compile-time evaluation | PLANNED |
| `@target("c")` | block | Backend-conditional code | PLANNED |
| `@emit("...")` | statement | Inline raw C/JS code into output | PLANNED |
| `@inline` | function | Hint to inline function body at call site | PLANNED |

#### Directives (standalone, module-level)

```typescript
@include("openssl/ssl.h");     // Include C header (emit #include)
@compile("bridge.c");          // Compile C source file into build
@link("libssl.a");             // Link pre-built archive
@passC("-I/usr/local/include");// Raw C compiler flag
@passL("-lssl");               // Raw linker flag
```

| Directive | Purpose | Status |
|-----------|---------|--------|
| `@include("file.h");` | Include C header (emits `#include` in generated C) | DONE |
| `@compile("file.c");` | Compile C source file, link into output binary | DONE |
| `import from "*.h"` | Auto-compiles companion `.c` if it exists at same path | DONE |
| `@link("lib.a");` | Link pre-built archive | DONE |
| `@passC("flag");` | Raw C compiler flag | DONE |
| `@passL("flag");` | Raw linker flag | DONE |

#### 3-Tier Builtin System

| Tier | Decorator | Output | Adding New Ones |
|------|-----------|--------|-----------------|
| `@runtime("c_name")` | Plain C function call | Edit `std/core.ms` + `runtime/*.c` (no compiler rebuild) |
| `@builtin("Name")` | Inline C (any pattern) | Edit `std/core.ms` + `builtinLower.ms` (compiler rebuild) |
| `extern function` | Raw C FFI declaration | Edit user code directly |

### Mutable Strings

MetaScript strings are mutable — a TypeScript superset. All TS string code works unchanged; mutation is purely additive.

```typescript
// TypeScript-compatible (unchanged behavior)
const s = "hello";            // const → no mutation, no reassignment
let t = s.slice(1);           // returns new string
let u = s + " world";         // concat returns new string

// MetaScript extension (new capability)
let buf = "hello";
buf[0] = "H";                 // char assignment — TS rejects, MS allows
buf.add(" world");            // in-place append
// buf is now "Hello world"
```

Rules:
- `const` strings: immutable (same as TS)
- `let` strings: reassignable (same as TS) AND mutable (MS extension)
- `.slice()`, `.replace()`, `+`: return new strings (same as TS)
- `s[i] = ch`, `.add()`: mutation ops — no existing TS code uses them, purely additive

### Three-Tier Array System

MetaScript has three array types for systems programming control over allocation, expressed as TypeScript-compatible syntax.

```typescript
// Dynamic array — standard TypeScript, heap-allocated, growable
const items: number[] = [1, 2, 3];
items.push(4);

// Fixed-size array — stack-allocated, zero heap overhead
const matrix: number[4] = [1, 0, 0, 1];
// matrix.push(5);              // compile error: fixed size

// Span — non-owning view, accepts both T[] and T[N]
function sum(data: Span<number>): number {
    let total = 0;
    for (const x of data) total += x;
    return total;
}
sum(items);                    // number[]  → Span<number> (implicit)
sum(matrix);                   // number[4] → Span<number> (implicit)
sum(items.span(1, 3));         // zero-copy slice, no allocation
```

| Type | Allocation | Growable | Use Case |
|------|-----------|----------|----------|
| `T[]` | Heap (RC) | Yes | General-purpose, all TS array code |
| `T[N]` | Stack | No | Fixed buffers, matrices, SIMD, embedded |
| `Span<T>` | None (view) | N/A | Unified function params, zero-copy slicing |

Restrictions: `Span<T>` cannot be returned or stored (dangling pointer). `T[N]` size must be compile-time constant. See `docs/LANG-RUNTIME.md` for full design.

### Macros
```typescript
macro deriveEq(target) {
    const fields = target.fields;
    // ... generate equality method at compile-time
    return target;
}

```

### Extern Declarations (FFI)
```typescript
extern function printf(fmt: string, ...args: unknown[]): void;
extern class FILE { }
extern const STDIN: FILE;
```

### Distinct Types
```typescript
distinct type UserId = number;    // Nominal typing wrapper
distinct type Email = string;     // Cannot assign string to Email
```

### Unreachable
```typescript
unreachable;    // Mark code path as impossible (crashes in debug)
```

### Out Parameters
```typescript
function parse(input: string, out result: AST): boolean {
    result = parseAST(input);
    return true;
}
```

## Memory Management

### ORC Mode (Default)
- Automatic reference counting with cycle detection
- Lifecycle hooks: `=destroy`, `=copy`, `=sink`, `=wasMoved`, `=trace`
- Shared by default (TypeScript semantics)
- `move` for optional ownership transfer optimization

### NONE Mode (`--gc:none`)
- Manual memory with allocator pattern
- `defer` for cleanup
- Arena, Pool, FixedBuffer allocators

## AST Node Kinds (111 total)

### Literals (6)
`number_literal`, `bigint_literal`, `string_literal`, `regex_literal`, `boolean_literal`, `null_literal`

### Identifier (1)
`identifier`

### Expressions (25)
`binary_expr`, `unary_expr`, `update_expr`, `call_expr`, `member_expr`, `new_expr`, `array_expr`, `object_expr`, `function_expr`, `conditional_expr`, `spread_element`, `move_expr`, `out_expr`, `await_expr`, `try_expr`, `yield_expr`, `type_assertion_expr`, `stmt_expr`, `custom_infix_expr`, `custom_prefix_expr`, `optional_wrap`, `optional_none`, `optional_unwrap`, `range_check_expr`, `implicit_conv`

### String Coercion Nodes (4)
`string_concat_expr`, `string_append_expr`, `string_assign_expr`, `string_sink_expr`

### Statements (16)
`block_stmt`, `expression_stmt`, `if_stmt`, `while_stmt`, `for_stmt`, `for_of_stmt`, `switch_stmt`, `match_stmt`, `return_stmt`, `break_stmt`, `continue_stmt`, `variable_stmt`, `try_stmt`, `throw_stmt`, `defer_stmt`, `unreachable_stmt`

### Declarations (7)
`function_decl`, `class_decl`, `enum_decl`, `interface_decl`, `type_alias_decl`, `import_decl`, `export_decl`

### Class Members (3)
`property_decl`, `method_decl`, `constructor_decl`

### Type Annotation (1)
`type_annotation`

### Macro Nodes (11)
`macro_decl`, `extern_macro_decl`, `extern_function_decl`, `extern_var_decl`, `extern_const_decl`, `extern_class_decl`, `extern_enum_decl`, `extern_type_decl`, `macro_invocation`, `comptime_block`, `compile_error`, `quote_expr`

### JSX (4)
`jsx_element`, `jsx_fragment`, `jsx_text`, `jsx_expression_container`

### Program (1)
`program`

## Compilation Pipeline

```
Source (.ms)
    |
    v
Lexer -> Tokens
    |
    v
Parser -> AST
    |
    v
Macro Expansion -> Expanded AST
    |
    v
Type Checker (3-pass)
    |- Pass 1: Collect declarations (all modules)
    |- Pass 2: Propagate export types to imports
    |- Pass 3: Resolve, infer, check (all modules)
    |
    v
Transforms (analyzer, lambda lifting, lowering)
    |
    v
Code Generation (C / JS / Erlang)
    |
    v
Output
```

## Testing Framework

Built-in testing via `std/testing`. Tests are compiler intrinsics — `check()` captures expression sides at compile time (no runtime reflection), and test code is stripped from non-test builds.

```typescript
import { test, check, require } from "std/testing";

test("addition", () => {
    check(add(1, 2) === 3);     // non-fatal, prints "FAIL: 3 === 4" on mismatch
    require(setup() !== null);   // fatal, aborts current test on failure
});

testGroup("edge cases", () => {
    test("large numbers", () => {
        check(add(999999, 1) === 1000000);
    });
});
```

Run with `msc test file.ms`. Supports `--filter="name"` to run matching tests only.

| Function | Behavior |
|----------|----------|
| `test(name, body)` | Register a test case |
| `check(expr)` | Non-fatal assertion with expression capture |
| `require(expr)` | Fatal assertion — aborts test on failure |
| `testGroup(name, body)` | Group related tests under a heading |

Output: `PASS`/`FAIL` per test, summary line (`N passed, N failed, N skipped`), exit code 1 on any failure.

## Reserved Words

`type` is reserved in MetaScript. Use `tokenType`, `nodeType`, etc. for field names.
