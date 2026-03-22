# MetaScript Language Reference

MetaScript is a systems programming language with TypeScript syntax that compiles to C, JavaScript, and Erlang. This document covers all syntax the self-hosted compiler must handle.

## Primitive Types

| Type | Description | C Mapping |
|------|-------------|-----------|
| `number` | IEEE 754 f64 (default numeric) | `double` |
| `string` | Mutable UTF-8 with COW | `msString` |
| `boolean` | true/false | `bool` |
| `char` | 8-bit character (numeric) | `char` / `int8_t` |
| `cstring` | C-compatible string pointer | `const char*` |
| `void` | No value | `void` |
| `never` | Unreachable (bottom type) | N/A |
| `null` | Null value | `NULL` |
| `undefined` | Undefined (aliases to null) | `NULL` |
| `unknown` | Type-safe any | `void*` |

### Sized Integer Types

Fixed-width integers for systems programming. These are true integer types in the C backend — not boxed floats.

| Type | Size | Signed | C Mapping | Range |
|------|------|--------|-----------|-------|
| `int8` | 8-bit | yes | `int8_t` | -128 to 127 |
| `int16` | 16-bit | yes | `int16_t` | -32,768 to 32,767 |
| `int32` / `int` | 32-bit | yes | `int32_t` | -2³¹ to 2³¹-1 |
| `int64` | 64-bit | yes | `int64_t` | -2⁶³ to 2⁶³-1 |
| `uint8` | 8-bit | no | `uint8_t` | 0 to 255 |
| `uint16` | 16-bit | no | `uint16_t` | 0 to 65,535 |
| `uint32` | 32-bit | no | `uint32_t` | 0 to 2³²-1 |
| `uint64` | 64-bit | no | `uint64_t` | 0 to 2⁶⁴-1 |

```typescript
const port: uint16 = 8080;
const flags: uint32 = 0xFF00FF00;
const fileSize: int64 = 4_294_967_296;  // > 32-bit range
const byte: uint8 = 255;

// Sized integers support all arithmetic and bitwise operators
const masked = flags & 0x00FF00FF;
const shifted = byte << 4;
```

**Type Promotion Rules**: Sized integers widen implicitly (e.g., `int8` → `int32` → `int64`). Narrowing requires explicit cast. `number` (f64) and sized integers do not implicitly convert — use explicit cast at the boundary.

### Float Types

| Type | Size | C Mapping |
|------|------|-----------|
| `float32` / `float` | 32-bit | `float` |
| `float64` / `double` | 64-bit | `double` |

`number` is `float64` / `double`. The `float32` type is available for interop with C APIs or GPU buffers that require single-precision.

### Byte Arrays (`uint8[]`)

`uint8[]` is a dynamic array of unsigned bytes. It is the standard type for binary data — file I/O, network buffers, cryptographic operations, and binary protocols.

In the C backend, `uint8[]` shares an identical memory layout with `string` (see [String ↔ Byte Array Bridge](#7-zero-copy-string--byte-array-bridge-binary-parity)). This enables zero-copy conversion between text and binary data via `.asBytes()` and `.asString()`.

```typescript
// Binary buffer
const buf: uint8[] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

// Zero-copy cast to string (valid UTF-8 in this case)
const text = buf.asString();   // "Hello"

// Reading from file returns bytes, cast to string for text processing
const data: uint8[] = readFile("config.json");
const json = data.asString();

// Index access returns uint8
const firstByte: uint8 = buf[0];   // 0x48
```

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
struct    borrow    ref
macro     quote     extern    sizeof
test      assert
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
| `..` | DOT_DOT | Exclusive Range (exclusive end) |
| `...` | DOT_DOT_DOT | Inclusive Range / Spread / Rest |
| `=>` | ARROW | Arrow function |
| `\|>` | PIPE_GT | Pipeline operator |
| `sizeof` | SIZEOF | Size of Type in bytes |

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

### Strings & Characters
```typescript
"hello"         // Double-quoted string
'world'         // Single-quoted string
'a'             // char literal (length 1 single quotes)
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

Interfaces are **reference types** — heap-allocated, reference-counted via DRC. They work identically across JS and C backends. Interfaces can have both fields and method signatures.

```typescript
// Data shape (fields only)
interface Point {
    x: number;
    y: number;
    label?: string;        // Optional property
}

// Behavioral contract (with methods)
interface Shape {
    area(): number;
    perimeter(): number;
}

// Both (fields + methods)
interface ISerializable {
    id: string;
    function serialize(): string;
}

// Extends
interface Circle extends Shape {
    radius: number;
}

// Construction — object literals (heap-allocated, reference-counted)
const p: Point = { x: 1.0, y: 2.0 };
```

**C backend**: Interfaces emit as C structs, passed by pointer (`T*`), heap-allocated with DRC refcounting.

### Structs

Structs are **value types** — stack-allocated, no refcounting, no DRC overhead. Pure data containers: no methods, no vtable. Structs are a MetaScript extension (Layer 2) — an opt-in performance optimization for hot paths.

```typescript
// Direct declaration (fields only)
struct Vec2 { x: float64; y: float64; }
struct Color { r: uint8; g: uint8; b: uint8; a: uint8; }

const p: Vec2 = { x: 1.0, y: 2.0 };  // stack-allocated

// Intersection with data-only interfaces
interface IUser { name: string; age: number; }
struct SuperUser = IUser & { role: string; };
```

#### Struct Parameter Passing

Struct params are **TS-compatible** — mutation propagates to the caller, just like TypeScript objects. The compiler auto-selects the optimal C ABI per parameter based on size and mutation analysis:

```typescript
struct Vec2 { x: float64; y: float64; }
struct BigData { name: string; items: number[100]; }

// Not mutated → compiler uses value (small) or const T* (big) — zero copy
function length(v: Vec2): float64 {
    return Math.sqrt(v.x * v.x + v.y * v.y);
}

// Mutated → compiler uses T* — mutation propagates to caller
function reset(v: Vec2): void {
    v.x = 0;  // caller's v.x becomes 0
    v.y = 0;
}

// readonly → explicit copy, caller's value is never affected
function tryParse(readonly data: BigData): boolean {
    data.name = "test";  // mutates local copy only
    return validate(data);
}
```

| Size | Mutated? | `readonly`? | C output |
|------|----------|-------------|----------|
| Small (≤24B) | No | No | `void f(Vec2 v)` — value, registers |
| Small (≤24B) | Yes | No | `void f(Vec2* v)` — pointer, mutation propagates |
| Small (≤24B) | — | Yes | `void f(Vec2 v)` — forced copy |
| Big (>24B) | No | No | `void f(const BigData* v)` — zero copy |
| Big (>24B) | Yes | No | `void f(BigData* v)` — pointer, mutation propagates |
| Big (>24B) | — | Yes | Copy-on-entry — explicit isolation |

Developer writes normal code — the compiler picks the fastest path automatically.

#### Parameter Modifiers

| Modifier | Syntax | Purpose |
|---|---|---|
| *(default)* | `f(v: Struct)` | Auto-optimized: compiler picks best ABI |
| `readonly` | `f(readonly v: Struct)` | Explicit copy — caller's value unaffected |
| `move` | `f(move v: Struct)` | Ownership transfer — caller's value zeroed |
| `out` | `f(out v: Struct)` | Output parameter — callee fills the value |

#### When to use what

| Construct | Value/Ref | Methods | Allocation | Use Case |
|-----------|-----------|---------|------------|----------|
| `interface` | Reference | Yes | Heap (DRC) | General data + behavior, TS compatibility |
| `struct` | Value | No | Stack | Hot paths, math types, small data, C interop |
| `class` | Reference | Yes | Heap (DRC) | OOP, inheritance, polymorphism |

**Workflow**: Start with `interface` (reference, familiar). Profile. Promote hot paths to `struct` (value, fast). Need methods on a value type? Use extension methods (`this self: T` syntax).

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
export struct Vec2 { x: float64; y: float64; }
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

// Undiscriminated unions (field-based variant matching)
type Result<T, E> =
    | { ok: true; value: T }
    | { ok: false; error: E };

// Intersection types — combine multiple types
type Extended = IUser & { role: string };

// Struct intersection — compose value types from data-only interfaces
struct SuperUser = IUser & { role: string; };
```

### Discriminated Union Types (Variant Objects)

Discriminated unions use `match` in type position to bind each variant to an enum value. This eliminates ambiguity when variants share field names, and maps 1:1 to the standard reference's variant objects (`case kind: EnumType`).

```typescript
enum NodeKind { NumLit, StrLit, BinExpr }

type NodeData = match (kind: NodeKind) {
    NodeKind.NumLit  => { value: number },
    NodeKind.StrLit  => { value: string },
    NodeKind.BinExpr => { op: string, left: Node, right: Node },
};
```

The discriminant field (here `kind`) is always an enum type. Each arm maps one enum member to a set of variant-specific fields.

#### Construction

Provide the discriminant field plus the fields for that variant:

```typescript
function makeNum(n: number): NodeData {
    return { kind: NodeKind.NumLit, value: n };
}

function makeBin(op: string, l: Node, r: Node): NodeData {
    return { kind: NodeKind.BinExpr, op: op, left: l, right: r };
}

// Error: "value" belongs to NumLit/StrLit variants, not BinExpr
// return { kind: NodeKind.BinExpr, value: 42 };  // ← compile error

// Error: discriminant field is required
// return { op: "+", left: l, right: r };          // ← compile error
```

#### Field Access

The discriminant field is always accessible and returns the enum type. Variant-specific fields are accessible directly — if a field name is unique across variants, no cast is needed:

```typescript
function getKind(d: NodeData): NodeKind {
    return d.kind;   // discriminant — always available
}

function getOp(d: NodeData): string {
    return d.op;     // "op" only exists in BinExpr — resolves unambiguously
}
```

Fields that appear in multiple variants with the same type also resolve without ambiguity:

```typescript
enum Kind { A, B }
type Data = match (kind: Kind) {
    Kind.A => { value: number },
    Kind.B => { value: number },
};

function getValue(d: Data): number {
    return d.value;  // same type in both variants — OK
}
```

#### C Backend

In the generated C code, the discriminant field maps to `_tag` (the internal union tag), and the enum type is used instead of a raw `int32_t`:

```c
// Generated C for NodeData:
typedef struct NodeData {
    NodeKind _tag;          // enum type, not int32_t
    union {
        struct { double value; } _v0;           // NumLit
        struct { msString value; } _v1;         // StrLit
        struct { msString op; Node left; Node right; } _v2; // BinExpr
    };
} NodeData;
```

#### Comparison with Undiscriminated Unions

| Feature | `type X = \| { ... } \| { ... }` | `type X = match (d: Enum) { ... }` |
|---------|----------------------------------|-------------------------------------|
| Variant selection | Field-name matching (fragile) | Enum discriminant (precise) |
| Overlapping field names | Picks wrong variant | Each variant independent |
| Construction validation | No | Yes — checks fields match variant |
| `_tag` type in C | `int32_t` | Enum type |

Use discriminated unions when variants may share field names or when you want compile-time construction validation. Use plain unions for simple cases where field names are unique across variants.

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
// Expression match — simple arms (implicit return)
return match (escChar) {
    "n" => "\n",
    "t" => "\t",
    _ => escChar,
};

// Expression match — block arms require explicit `return`
return match (node.kind) {
    NodeKind.Identifier => getName(node),
    NodeKind.BinaryExpr => {
        const d = node.data as BinaryExprData;
        return d.left.toString() + d.op + d.right.toString();
    },
    _ => "unknown",
};
// Rule: `arm => expr` = implicit return; `arm => { return expr; }` = explicit return
// Applies to both `return match` and `const x = match` forms

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

// Or-patterns
match (token.kind) {
    TokenKind.Plus | TokenKind.Minus => parseBinary(),
    TokenKind.Star | TokenKind.Slash => parseMulDiv(),
    _ => defaultCase(),
}

// Guards — `when` adds a condition after the pattern match (parentheses optional)
match (token.kind) {
    TokenKind.Ident when isKeyword(token.value) => handleKeyword(token),
    TokenKind.Ident when isBuiltin(token.value) => handleBuiltin(token),
    TokenKind.Ident => handleIdentifier(token),  // fallback when guards fail
    TokenKind.Number => handleNumber(token),
    _ => handleOther(token),
}

// Guard on binding — binding is assigned before guard is evaluated
match (score) {
    x when x >= 90 => "A",
    x when x >= 80 => "B",
    _ => "F",
}

// Guard on wildcard — conditional default
match (mode) {
    _ when strictMode => { unreachable; },
    _ => handleFallback(),
}

// Guard with char codes
match (ch) {
    "\\".code => "\\\\",
    "\n".code => "\\n",
    "\"".code when quote === "\"".code => "\\\"",
    "'".code when quote === "'".code => "\\'",
    _ => s.byteSlice(i, i + 1),
}
```

**Guard rules:**
- `when` keyword after pattern, before `=>`
- Parentheses around guard expression are **optional**
- Guard is evaluated only when the pattern matches (short-circuit)
- Multiple guards on same pattern: tried top-to-bottom, first match wins
- Guarded arm does **not** count as exhaustive — an unguarded fallback is required
- Enum/integer discriminants generate C `switch` with `if` chains inside case bodies

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

### Promise<T> & Async/Await

MetaScript provides TypeScript-compatible `Promise<T>` with `async`/`await` syntax. Internally, `Promise<T>` maps to `msFuture*` in the C backend — a callback-driven future with deterministic reference counting.

#### Async Functions

```typescript
async function fetchUser(id: number): Promise<string> {
    const data = await httpGet(`/users/${id}`);
    return data;
}

// Await unwraps Promise<T> → T
const user = await fetchUser(42);
```

`async` functions return `Promise<T>`. The compiler desugars `await` into a state machine (stepper pattern) — each `await` splits the function body into states, with callbacks resuming execution when the awaited promise settles.

#### Promise Chaining (.then / .catch / .finally)

```typescript
fetchUser(42)
    .then((user) => { console.log(user); })
    .catch((err) => { console.log("failed: " + err); })
    .finally(() => { cleanup(); });
```

| Method | Callback Signature | Returns | Behavior |
|--------|-------------------|---------|----------|
| `.then(fn)` | `(value: T) => void` | `Promise<void>` | Called on fulfillment, rejection propagates |
| `.catch(fn)` | `(error: string) => void` | `Promise<T>` | Called on rejection, fulfillment passes through |
| `.finally(fn)` | `() => void` | `Promise<T>` | Called always, original value/error preserved |

All three return a new `Promise`, enabling chaining. Exceptions thrown inside callbacks are captured and propagate as rejections on the output promise.

#### Promise Combinators (Static Methods)

```typescript
extern function msPromiseAll(promises: Promise<void>[]): Promise<void> from "msPromiseAll";
extern function msPromiseRace(promises: Promise<void>[]): Promise<void> from "msPromiseRace";
extern function msPromiseAllSettled(promises: Promise<void>[]): Promise<void> from "msPromiseAllSettled";
extern function msPromiseAny(promises: Promise<void>[]): Promise<void> from "msPromiseAny";
```

| Combinator | Resolves When | Rejects When | Empty Array |
|------------|---------------|--------------|-------------|
| `Promise.all` | ALL resolve | FIRST rejects | Resolves immediately |
| `Promise.race` | FIRST settles | FIRST settles (if rejection) | Never settles |
| `Promise.allSettled` | ALL settle | Never | Resolves immediately |
| `Promise.any` | FIRST fulfills | ALL reject | Rejects immediately |

#### Promise.resolve / Promise.reject

```typescript
extern function msPromiseResolve(val: void): Promise<void> from "msPromiseResolve";
extern function msPromiseReject(err: void): Promise<void> from "msPromiseReject";
```

Create pre-settled promises. Useful for returning immediate values from functions that must return `Promise<T>`.

#### new Promise(executor) — Constructor Pattern

```typescript
const p = new Promise<string>((resolve, reject) => {
    // resolve and reject are closures provided by the runtime
    if (success) {
        resolve(data);     // settles the promise as fulfilled
    } else {
        reject("failed");  // settles the promise as rejected
    }
});

const result = await p;
```

The executor runs **synchronously**. Only the first call to `resolve` or `reject` takes effect — subsequent calls are ignored (settled flag). The constructor is lowered to `msPromiseNew(executor)` by the compiler.

#### Promise.withResolvers (ES2024)

Creates a pending promise with explicit `resolve`/`reject` control — the deconstructed form of `new Promise(executor)`:

```typescript
extern function msFutureCreate(): Promise<void> from "msFutureCreate";
extern function msPromiseSettle(p: Promise<void>, value: void): void from "msPromiseSettle";
extern function msPromiseRejectFuture(p: Promise<void>, error: string): void from "msPromiseRejectFuture";

// Create pending promise
const p = msFutureCreate();

// Settle it later (first call wins — double-settle is no-op)
msPromiseSettle(p, null as unknown as void);

// Or reject it
msPromiseRejectFuture(p, "error");
```

Useful when resolve/reject need to be called from a different scope than where the promise was created — e.g., event handlers, timers, or cross-module coordination.

#### Spawn — Thread Pool Parallelism

`spawn` offloads work to a thread pool (Malebolgia-style: fixed workers, backpressure, local execution fallback):

```typescript
extern function msSpawn(fn: () => void): Promise<void> from "msSpawn";
extern function msWaitFor(fut: Promise<void>): void from "msWaitFor";

const fut = msSpawn(() => {
    // runs on a worker thread
    heavyComputation();
});

msWaitFor(fut);  // block until complete
```

Spawn works with all Promise combinators:

```typescript
// Parallel execution — wait for both
const results = msPromiseAll([msSpawn(workA), msSpawn(workB)]);
msWaitFor(results);

// Race — first to finish wins
const fastest = msPromiseRace([msSpawn(workA), msSpawn(workB)]);
msWaitFor(fastest);
```

**Memory ownership**: Captured variables are borrowed (read-only) by default. Use `move` for ownership transfer to the spawned thread.

#### AbortController — Cooperative Cancellation

ECMAScript-compatible cancellation for async and spawned work:

```typescript
const controller = new AbortController();
const signal = controller.signal;

// Check cancellation
if (signal.aborted) { /* cancelled */ }

// Abort with reason
controller.abort("timeout");

// Throw if aborted (cooperative check)
signal.throwIfAborted();  // throws AbortError if aborted

// Static factory
const preAborted = AbortSignal.abort("already done");
```

Works with spawn, async, and all Promise combinators — model-agnostic cooperative cancellation.

#### Value Boxing

Async functions returning non-pointer types (`number`, `boolean`, `int32`) require value boxing because the C runtime stores results as `void*`. The compiler automatically inserts boxing/unboxing:

```typescript
async function compute(): Promise<number> {
    return 42;  // compiler inserts msBoxDouble(42)
}

const n = await compute();  // compiler inserts msUnboxDouble(result)
```

| Type | Box Function | Unbox Function |
|------|-------------|----------------|
| `number` | `msBoxDouble` | `msUnboxDouble` |
| `boolean` | `msBoxBool` | `msUnboxBool` |
| `int32` | `msBoxInt32` | `msUnboxInt32` |

String and pointer types pass through without boxing (they are already pointer-sized).

#### Feature Parity with TypeScript/Node.js

| Feature | TypeScript | MetaScript | Notes |
|---------|-----------|------------|-------|
| `async`/`await` | Yes | Yes | State machine desugaring |
| `Promise.all` | Yes | Yes | Thread-safe (atomics) |
| `Promise.race` | Yes | Yes | Thread-safe (atomics) |
| `Promise.allSettled` | Yes (ES2020) | Yes | Per-future outcome tracking |
| `Promise.any` | Yes (ES2021) | Yes | Thread-safe (atomics) |
| `Promise.resolve`/`.reject` | Yes | Yes | Pre-settled futures |
| `.then()`/`.catch()`/`.finally()` | Yes | Yes | Callback chaining |
| `new Promise(executor)` | Yes | Yes | Synchronous executor |
| `Promise.withResolvers` | Yes (ES2024) | Yes | `msFutureCreate` + `msPromiseSettle` |
| `AbortController`/`AbortSignal` | Yes | Yes | ECMAScript-compatible |
| **`Promise<Result<T,E>>`** | No | **Yes** | Typed errors, no rejection |
| **V1: throw-ban enforcement** | No | **Yes** | Compiler-enforced safety |
| **V2: unguarded await-ban** | No | **Yes** | Compiler-enforced safety |
| **`try await` composition** | No | **Yes** | Unwraps both layers |
| **Thread-safe combinators** | No | **Yes** | Atomic ops for spawn |
| **`spawn` + thread pool** | No | **Yes** | Malebolgia-style parallelism |

---

### Promise<Result<T, E>> — Typed Async Errors

`Promise<Result<T, E>>` is MetaScript's recommended pattern for async error handling. It combines the strengths of both systems:

- **Promise<T>** handles async execution (suspend/resume)
- **Result<T, E>** handles typed errors (no exceptions needed)

The key guarantee: **a `Promise<Result<T, E>>` never rejects**. Errors are always typed `Result` values inside a successfully-resolved promise. The compiler enforces this at compile time.

#### Basic Usage

```typescript
async function fetchUser(id: number): Promise<Result<User, string>> {
    const resp = await httpGet(`/users/${id}`);       // OK: httpGet returns Promise<Result>
    if (resp.status !== 200) return Result.err("not found");
    return Result.ok(parseUser(resp.body));
}
```

#### Composition with `try` and `await`

The `try` operator unwraps `Result<T, E>` → `T`. The `await` keyword unwraps `Promise<T>` → `T`. Together, `try await` unwraps both layers in a single expression:

```typescript
// Two layers: Promise<Result<User, string>>
//   await unwraps: Promise<Result<User, string>> → Result<User, string>
//   try  unwraps: Result<User, string> → User (or early-returns error)
const user = try await fetchUser(42);
```

**Desugaring of `try await`:**

```typescript
// try await fetchUser(42)  desugars to:
const $tmp = await fetchUser(42);              // Promise → Result<User, string>
if (!$tmp.ok) return Result.err($tmp.error);   // propagate error
const user = $tmp.value;                        // Result → User
```

#### The `try await ... catch` Pattern

When you want a fallback value instead of propagating the error:

```typescript
// If fetchUser fails (Result.err), use defaultUser instead
const user = try await fetchUser(42) catch defaultUser;

// Equivalent to:
const $tmp = await fetchUser(42);
const user = $tmp.ok ? $tmp.value : defaultUser;
```

#### All Unwrapping Combinations

| Expression | Input Type | Output Type | On Error |
|---|---|---|---|
| `await p` | `Promise<T>` | `T` | Promise rejects → exception propagates |
| `try expr` | `Result<T,E>` | `T` | Early-returns `Result.err(e)` |
| `try expr catch fallback` | `Result<T,E>` | `T` | Uses fallback value |
| `try await p` | `Promise<Result<T,E>>` | `T` | Early-returns `Result.err(e)` |
| `try await p catch fallback` | `Promise<Result<T,E>>` | `T` | Uses fallback value |

#### Compiler Safety: No-Rejection Guarantee

The compiler enforces two rules inside async functions returning `Promise<Result<T, E>>`:

**V1 — Throw Ban:** `throw` statements are forbidden. Use `Result.err()` instead.

```typescript
async function bad(): Promise<Result<number, string>> {
    throw new Error("boom");  // COMPILE ERROR
    // Fix: return Result.err("boom");
}
```

**V2 — Unguarded Await Ban:** `await` on a plain `Promise<T>` (non-Result) must be wrapped with `try ... catch` to handle potential rejection.

```typescript
async function example(): Promise<Result<number, string>> {
    // ERROR: bare await on Promise<string> — could reject and break the contract
    const data = await riskyCall();

    // OK: guarded with try...catch — rejection converted to Result.err
    const data = try await riskyCall() catch "fallback";

    // OK: inside try/catch statement — rejection is handled
    try {
        const data = await riskyCall();
    } catch (e) {
        return Result.err("wrapped: " + e);
    }

    // OK: await on Promise<Result<T,E>> — already typed errors
    const user = await fetchUser(42);  // Promise<Result<User, string>> — no guard needed

    return Result.ok(42);
}
```

**Why V2?** If `riskyCall()` returns a plain `Promise<string>` that rejects, the rejection propagates up and our `Promise<Result<T,E>>` also rejects — breaking the no-rejection guarantee. V2 forces you to handle the rejection path explicitly.

| Awaited Type | Guard Required? | Reason |
|---|---|---|
| `Promise<Result<T,E>>` | No | Already typed errors — Result handles failure |
| `Promise<T>` (non-Result) | Yes — `try await ... catch` | Rejection could propagate and break contract |

#### Comparison: Promise<T> vs Promise<Result<T, E>>

| Aspect | `Promise<T>` | `Promise<Result<T,E>>` |
|---|---|---|
| Error signaling | Rejection (untyped) | `Result.err(e)` (typed) |
| Needs try/catch? | Yes | No — use `try await` |
| Error type known? | No (`unknown`) | Yes (`E`) |
| Can reject? | Yes | No (compiler-enforced) |
| Recommended for | Fire-and-forget, side effects | All fallible async operations |

#### Real-World Example

```typescript
// Service layer — all errors are typed Results
async function createOrder(req: OrderRequest): Promise<Result<Order, OrderError>> {
    const user = try await fetchUser(req.userId);          // Promise<Result<User, OrderError>>
    const inventory = try await checkStock(req.items);     // Promise<Result<Stock, OrderError>>

    if (inventory.available < req.quantity) {
        return Result.err(OrderError.OutOfStock);
    }

    const order = try await saveOrder(user, req);          // Promise<Result<Order, OrderError>>
    return Result.ok(order);
}

// Caller — clean linear flow, no try/catch blocks
async function handleRequest(): Promise<Result<Response, string>> {
    const order = try await createOrder(request);
    return Result.ok({ status: 200, body: order });
}
```

Every `try await` either succeeds (unwraps the value) or short-circuits with a typed error. No exception handling, no untyped errors, no surprise rejections.

### Decorators & Directives

Both use `@` syntax. Semicolon disambiguates:
- **Decorator** = `@name(...) decl` — attaches to next declaration
- **Directive** = `@name(...);` — standalone statement (ends with `;`)

#### Decorators (attach to declarations)

```typescript
// Compiler intrinsic — builtinLower rewrites AST inline
// Can emit anything: field access, operators, multi-statement patterns
@builtin("LengthStr")
export function len(s: string): number;
// len(s) → ms_string_length(s)  (or future: s->len)

// Decorators can be used on extern declarations to trigger compiler magic
@builtin("msResultOk")
extern function ok<T>(val: T): Result<T, any>;
```

| Decorator | Applies To | Purpose | Status |
|-----------|-----------|---------|--------|
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

| Tier | Mapping | Output | Adding New Ones |
|------|-----------|--------|-----------------|
| **FFI** | `extern function` | Plain C function call | Edit user code (no compiler rebuild) |
| **Intrinsic** | `@builtin("Name")` | Inline C (any pattern) | Edit `builtinLower.ms` (compiler rebuild) |
| **Operator** | `sizeof T` | Native C operator | Lexer/Parser change (compiler rebuild) |

## Strings and Characters

MetaScript provides a high-performance string system that is a systems-programming superset of TypeScript. It adds support for in-place mutation, primitive characters, zero-copy views, and binary-compatible byte array bridging.

### 1. The `char` Primitive
MetaScript introduces `char` as a first-class primitive type (mapped to C `char`/`int8`).

- **Access**: Accessing a string by index (`s[i]`) returns a `char`, not a string.
- **Literals**: Character literals use single quotes (e.g., `'a'`).
- **Numeric**: `char` is a numeric type and can participate in arithmetic or be cast to `number`.

```typescript
const c: char = 'A';
const s = "hello";
const first: char = s[0]; // Returns 'h' as char
```

### 2. Mutable Strings
Strings in MetaScript are mutable when declared with `let`. All standard TypeScript string methods (`slice`, `replace`, etc.) remain available and return new strings.

- **`.length`**: Returns the number of characters (UTF-16 code units), matching TypeScript behavior.
- **`.byteLength`**: Returns the raw number of bytes in the UTF-8 buffer (Systems-optimized).
- **`.unicodeLength`**: Returns the number of actual Unicode code points.

```typescript
let buf = "🚀";
console.log(buf.length);        // 2 (TS compatibility)
console.log(buf.byteLength);    // 4 (UTF-8 bytes)
buf[0] = 'H';                   // Mutation (requires caution with UTF-8)
```

### 3. Zero-Copy String Views (`Span<char>`)
To avoid heap allocations when parsing or processing strings, MetaScript allows viewing a `string` as a `Span<char>`.

- **Zero-Copy Slicing**: Slicing a string with `..` (exclusive) or `...` (inclusive) into a `Span` context performs pointer arithmetic instead of a heap copy.
- **Unified Params**: Functions taking `Span<char>` can accept both `string` and `Span<char>` arguments zero-copy.

```typescript
function parseIdent(view: Span<char>): void {
    // Process characters without allocating tiny strings
}

const source = "function main()";
parseIdent(source[0...7]); // Zero-copy view of "function"
```

### 4. Borrowed References (`Borrow<T>`)
To achieve peak performance with large structs, MetaScript provides the `Borrow<T>` type (similar to the standard reference `lent T` pattern).

- **Purpose**: Avoid memory copies when accessing large objects or array elements.
- **Behavior**: Passes a pointer instead of copying the struct value.
- **Safety**: Managed by the analyzer to ensure the borrow does not outlive the owner.

```typescript
interface LargeData { /* many fields */ }
const data: LargeData[] = [...];

// No copy: 'item' is a pointer to the element in the array
const item: Borrow<LargeData> = data[0];
```

### 5. Reference Types (`Ref<T>` and `Ptr<T>`)

MetaScript has two explicit pointer types for heap-allocated data, following the same architecture as the standard reference's `ref T` and `ptr T`.

| Type | Semantics | Lifecycle | C Mapping |
|------|-----------|-----------|-----------|
| `Ref<T>` | Heap-allocated, reference-counted | Automatic (DRC) | `T*` with `msRefHeader` |
| `Ptr<T>` | Heap-allocated, untraced | Manual (no RC) | `T*` (raw) |

- **`Ref<T>`**: A managed heap pointer. The DRC system automatically inserts `=destroy`, `=copy`, and `=sink` operations. This is the safe default for heap objects.
- **`Ptr<T>`**: An unmanaged heap pointer. No reference counting — the programmer is responsible for the lifetime. Use for C FFI, arena-allocated objects, or performance-critical paths where RC overhead is unacceptable.

```typescript
// Explicit Ref — heap-allocated with automatic RC
const node: Ref<ASTNode> = { kind: "binary", left: a, right: b };

// Explicit Ptr — heap-allocated, no RC (manual lifetime)
const buf: Ptr<Buffer> = arenaAlloc(arena, sizeof Buffer);

// Ptr for C interop
extern function malloc(size: number): Ptr<void> from "ms_malloc";
extern function free(p: Ptr<void>): void;
```

#### Class = `Ref<Object>` (Sugar)

The `class` keyword is syntactic sugar. Internally, a class declaration produces a `Ref<Object>` type — a reference-counted heap pointer wrapping a value-type struct.

```typescript
// What you write:
class Point {
    x: number;
    y: number;
}

// What the compiler sees internally:
//   Point = Ref<{ x: number; y: number }>
//
// - The inner struct is a value type (like a struct)
// - The Ref wrapper adds heap allocation + RC
// - `new Point(1, 2)` allocates via msAllocTyped and returns a Ref
```

This means:
- **`interface`** declares a **reference type** — heap-allocated, passed by pointer, reference-counted (like class)
- **`class`** declares a **reference type** — heap-allocated, passed by pointer, reference-counted, with methods
- **`struct`** declares a **value type** — stack-allocated, auto-optimized passing (compiler picks value or pointer based on size + mutation)
- Users can write `Ref<T>` or `Ptr<T>` explicitly for fine-grained control

| Declaration | Internal Type | Allocation | Passed As |
|-------------|--------------|------------|-----------|
| `interface Foo { ... }` | `Ref<Struct>` | Heap (RC) | `Foo*` (pointer) |
| `class Foo { ... }` | `Ref<Struct>` | Heap (RC) | `Foo*` (pointer) |
| `struct Foo { ... }` | `Struct` | Stack | Auto: value or `Foo*` (size + mutation) |
| `const x: Ptr<Foo> = ...` | `Ptr<Struct>` | Heap (manual) | `Foo*` (pointer) |

#### Nullable Pointers

`Ref<T>` and `Ptr<T>` are inherently nullable — a null pointer is the zero value. No `Maybe<T>` wrapper is needed:

```typescript
const node: Ref<TreeNode> | null = findNode(tree, key);
if (node !== null) {
    // node is non-null here
    process(node);
}
```

The compiler collapses `Ref<T> | null` and `Ptr<T> | null` to bare `Ref<T>` / `Ptr<T>` (null is representable as the zero pointer).

### 6. Nullable Types and `Maybe<T>` (Deep Dive)

MetaScript uses a unified `T | null` syntax for all nullable types. Under the hood, the compiler chooses the optimal representation based on the inner type — no user intervention needed.

#### The Three Strategies

| Source Type | Internal Representation | C Layout | Null Sentinel |
|-------------|------------------------|----------|---------------|
| `interface \| null` | Bare `Ref<Struct>` (pointer) | `T*` | `NULL` (0x0) |
| `class \| null` | Bare `Ref<Struct>` (pointer) | `T*` | `NULL` (0x0) |
| `Ref<T> \| null` | Bare `Ref<T>` (pointer) | `T*` | `NULL` (0x0) |
| `Ptr<T> \| null` | Bare `Ptr<T>` (pointer) | `T*` | `NULL` (0x0) |
| `struct \| null` | `Maybe<Struct>` (wrapper struct) | `struct { T value; bool present; }` | `present == false` |

**Why the split?** Value-type structs live on the stack. There is no "null address" for a stack value — every bit pattern is a valid struct. The compiler must add an explicit `present` flag. Pointers (`Ref<T>`, `Ptr<T>`, interfaces, classes) already have a natural sentinel: the null pointer. Wrapping them in a struct would waste memory and add indirection for no benefit.

#### `Maybe<Struct>` — Wrapper Struct for Value Types

When you write `MyStruct | null` where `MyStruct` is a `struct` (value type), the compiler creates a `Maybe<MyStruct>` type internally:

```typescript
struct Token {
    kind: TokenKind;
    value: string;
    line: number;
}

// What you write:
let current: Token | null = null;
current = nextToken(lexer);

// What the compiler generates (C backend):
//   struct Maybe_Token { Token value; bool present; };
//   Maybe_Token current = {0};           // present=false
//   current = (Maybe_Token){ .value = nextToken(lexer), .present = true };
```

**Null checks** rewrite to `.present` field access:
```typescript
if (current !== null) {       // → if (current.present)
    use(current.kind);        // → use(current.value.kind)
}
```

**Field access after narrowing is transparent.** Once the checker proves `current` is non-null inside a branch, you access fields directly — `current.kind`, not `current.value.kind`. The `nullableLower` transform inserts the `.value` indirection automatically:

```typescript
function process(tok: Token | null): string {
    if (tok === null) return "none";
    // tok is narrowed to Token here — just use it naturally
    return tok.value;           // compiler inserts: tok.value.value (the field)
}
```

Note: `interface | null` and `class | null` are pointer types and use `NULL` directly — no `Maybe` wrapper needed. `Maybe` only applies to `struct` (value types) where there is no null address.

**Optional chaining** works as expected:
```typescript
const name: string | null = node?.name;    // null if node is null, node.name otherwise
```

#### `Maybe<Ref<T>>` and `Maybe<Ptr<T>>` — Nullable Pointer Optimization

Pointer types are inherently nullable. The compiler recognizes this and skips the wrapper entirely:

```typescript
// All three resolve to bare Ref<TreeNode> — no wrapper struct
const a: Ref<TreeNode> | null = findNode(tree, key);
const b: TreeNode | null = findNode(tree, key);   // if TreeNode is a class
let   c: Ptr<Buffer> | null = null;

// Null checks compile to direct pointer comparison
if (a !== null) {       // → if (a != NULL)
    use(a.left);        // → use(a->left)  (no .value indirection)
}

// Assignment of null is just NULL
c = null;               // → c = NULL
c = allocBuffer();      // → c = allocBuffer()  (no wrapping)
```

**No `{ value, present }` overhead.** The pointer *is* the option — `NULL` means absent, any other address means present. This follows the same optimization as the standard reference implementation's managed pointers.

#### How It All Fits Together

The compiler resolves `T | null` in the type checker's resolve pass:

1. **Is `T` a pointer type?** (`Ref<T>`, `Ptr<T>`, `interface`, or `class`) → Collapse to bare `T`. Done.
2. **Is `T` a value-type struct?** → Create `Maybe<T>` wrapper struct.
3. Later passes handle the structural rewrites:
   - **operatorLower**: `x !== null` → `x.present` (for Maybe) or pass-through (for pointers)
   - **nullableLower**: Inserts `.value` on narrowed identifiers, wraps RHS in assignments

#### Summary

| You Write | Compiler Sees | Null Check | Field Access | Assignment |
|-----------|--------------|------------|--------------|------------|
| `v: MyStruct \| null` (struct) | `Maybe<MyStruct>` | `v.present` | `v.value.field` | `{value: x, present: true}` |
| `iface: IFoo \| null` (interface) | `Ref<IFoo>` | `iface != NULL` | `iface->field` | `iface = x` |
| `obj: MyClass \| null` | `Ref<Object>` | `obj != NULL` | `obj->field` | `obj = x` |
| `node: Ref<T> \| null` | `Ref<T>` | `node != NULL` | `node->field` | `node = x` |
| `buf: Ptr<T> \| null` | `Ptr<T>` | `buf != NULL` | `buf->field` | `buf = x` |

All of this is invisible to the programmer. You write `T | null`, check with `!== null`, and access fields normally after narrowing. The compiler picks the optimal representation and inserts the right code.

### 7. Efficient Concatenation
The compiler automatically optimizes string concatenation chains (`a + b + c + d`).

- **Fusion**: Multiple `+` operations are fused into a single variadic call (`msStringConcatMany`).
- **Single Allocation**: The total length is pre-calculated, resulting in exactly one heap allocation for the entire chain.

### 8. String Formatting and Type-to-String Conversion

MetaScript provides three contexts where values are converted to strings, each with different automatic coercion rules.

#### `console.log` — Automatic Conversion for All Types

`console.log` automatically converts any value to a readable string representation. No `.toString()` call needed.

```ms
console.log(42);              // "42"
console.log(true);            // "true"
console.log(color);           // "Red" (enum variant name)
console.log(person);          // Person { name: "Alice", age: 30 } (colored debug format)
console.log(a, b, c);         // space-separated, each auto-converted
```

Structs and classes are printed in a **colored** JSON-like debug format with ANSI color prefixes (blue for structs, green for classes, cyan for anonymous objects, magenta for JsonValue). Enums print their variant name. This colored format is exclusive to `console.log` — it never appears in `.toString()` or string concatenation.

#### String Concatenation (`+`) — Limited Auto-Coercion

The `+` operator auto-coerces only **numbers** and **booleans** to strings:

```ms
const s1 = "value: " + 42;       // OK → "value: 42"
const s2 = "flag: " + true;      // OK → "flag: true"
const s3 = "color: " + color;    // ERROR — enum not auto-coerced
const s4 = "person: " + person;  // ERROR — struct not auto-coerced
```

For enums, structs, and classes in string concatenation, call `.toString()` explicitly:

```ms
const s3 = "color: " + color.toString();
const s4 = "person: " + person.toString();
```

#### `String()` — Universal Type Coercion Function

`String(x)` converts any value to its string representation. It is a prelude function (no import needed) that delegates to `x.toString()` internally:

```ms
const s1 = String(42);           // "42"
const s2 = String(true);         // "true"
const s3 = String(Color.Red);    // "Red"
const s4 = String(person);       // plain JSON (or custom toString if defined)
```

`String()` and `.toString()` always produce the same result — they share the same underlying infrastructure. Use whichever reads better at the call site.

Inside template strings, numbers and booleans auto-convert — no `String()` needed:

```ms
const msg = `value: ${42}`;      // OK — auto-converted
const msg2 = `flag: ${true}`;    // OK — auto-converted
```

#### Explicit `.toString()` — Available on All Types

Every type has a `.toString()` method:

```ms
const n: number = 3.14;
n.toString()              // "3.14"

const b: boolean = true;
b.toString()              // "true"

const c: Color = Color.Red;
c.toString()              // "Red"

const p: Person = { name: "Alice", age: 30 };
p.toString()              // plain JSON (no colors)
```

#### Custom String Format via Extension Methods

Override the default format for any type by defining a `toString` extension method:

```ms
function toString(this p: Person): string {
    return p.name + " (age " + p.age.toString() + ")";
}

// Now all four contexts use your custom format:
console.log(person);                    // "Alice (age 30)"
String(person)                          // "Alice (age 30)"
const s = "hello " + person.toString(); // "hello Alice (age 30)"
person.toString()                       // "Alice (age 30)"
```

The custom `toString` takes priority over the default debug format everywhere — including `console.log` and `String()`.

#### Summary Table

| Type | `console.log(v)` | `"str" + v` | `v.toString()` | `String(v)` |
|------|-------------------|-------------|-----------------|-------------|
| number | auto | auto | yes | yes |
| boolean | auto | auto | yes | yes |
| string | identity | identity | identity | identity |
| enum | auto (variant name) | explicit `.toString()` needed | yes | yes |
| struct | auto (colored debug) | explicit `.toString()` needed (plain JSON) | yes (plain JSON) | yes (plain JSON) |
| class | auto (colored debug) | explicit `.toString()` needed (plain JSON) | yes (plain JSON) | yes (plain JSON) |

### 9. Zero-Copy String ↔ Byte Array Bridge (Binary Parity)

MetaScript strings and `uint8[]` byte arrays share an identical memory layout in the C backend. This enables zero-copy conversion between text and binary data — no allocation, no memcpy, just a type reinterpretation.

This follows the same principle as Zig (where `[]const u8` *is* the string type) and the standard reference (where `string` and `seq[byte]` are binary-compatible and convertible via `cast`).

#### Memory Layout (C Backend)

Both types use the exact same C structure:

```c
// msString and msUint8Array are structurally identical
typedef struct {
    int64_t len;
    struct {
        int64_t cap;
        uint8_t data[];  // Flexible array member
    }* p;
} msString, msUint8Array;
```

The `len` field, the `cap` field, and the `data[]` flexible array member are at identical offsets. A pointer to one is a valid pointer to the other.

#### Conversion Methods

```typescript
const text: string = "hello world";

// String → Bytes: zero-copy bit-cast (0 CPU cycles)
const bytes: uint8[] = text.asBytes();

// Bytes → String: zero-copy bit-cast (0 CPU cycles)
const back: string = bytes.asString();
```

In generated C code, these compile to plain casts — no function call:
```c
msUint8Array bytes = (msUint8Array)text;   // .asBytes()
msString back = (msString)bytes;           // .asString()
```

#### Why It Works: The Null-Terminator Guarantee

MetaScript strings are always null-terminated (`data[len] == '\0'`). To maintain binary parity, all `uint8[]` allocations also include an extra byte and null-terminate by default. This means every byte array is "string-ready" without any extra work.

```
msString "hello":
  len=5, p -> { cap=8, data=['h','e','l','l','o','\0', ...] }

uint8[] from network recv:
  len=5, p -> { cap=8, data=[0x68,0x65,0x6C,0x6C,0x6F,'\0', ...] }

Same bits. Same layout. Cast is free.
```

#### Copy-on-Write (COW) Across the Bridge

String literals use a flag bit in `cap` (`MS_STRLIT_FLAG`) to mark them as read-only (Copy-on-Write). This flag is preserved across the cast:

```typescript
const greeting = "hello";              // COW literal
const bytes = greeting.asBytes();      // Still COW — mutation triggers copy
bytes[0] = 72;                         // COW copy happens here (same as mutating a string literal)
```

#### Ownership and Lifecycle

Because `string` and `uint8[]` share the same layout, the DRC (Deterministic Reference Counting) system treats them identically:

- **Destroy**: Same deallocation path for both types
- **Copy**: Same deep-copy semantics on assignment
- **Move**: `move` transfers ownership with zero cost for both types
- **Sink**: Last-use optimization applies equally

```typescript
const data: uint8[] = readFile("input.bin");
const text = data.asString();   // Zero-copy cast
// 'data' and 'text' point to the same memory
// DRC tracks the lifecycle — only one destroy at scope exit
```

#### UTF-8 Safety

`.asString()` is a zero-copy cast — it does not validate UTF-8. This is by design: in practice, the consumer (JSON parser, HTTP parser, etc.) validates encoding as part of its own parsing pass, touching the same cache lines it would anyway. A separate validation step would scan the data twice for no benefit.

If you receive bytes from an untrusted source, the parser itself will reject invalid UTF-8 — you don't need a pre-validation gate.

#### Use Cases

| Scenario | Pattern |
| :--- | :--- |
| Parse binary protocol | `recv() → uint8[] → .asString() → parse` (zero-copy) |
| Hash file contents | `readFile() → string → .asBytes() → hash(bytes)` (zero-copy) |
| JSON from network | `socket.read() → uint8[] → .asString() → JSON.parse()` (zero-copy) |
| Encode string to wire | `response.asBytes() → socket.write(bytes)` (zero-copy) |

#### Comparison with Other Languages

| Language | String Type | Byte Type | Conversion Cost |
| :--- | :--- | :--- | :--- |
| **MetaScript** | `string` | `uint8[]` | Zero (bit-cast) |
| **Zig** | `[]const u8` | `[]const u8` | Zero (same type) |
| **Nim** | `string` | `seq[byte]` | Zero (`cast`) |
| **Rust** | `String` / `&str` | `Vec<u8>` / `&[u8]` | Zero (`into_bytes`) + UTF-8 check on reverse |
| **Go** | `string` | `[]byte` | Copy (immutable→mutable) |
| **TypeScript** | `string` | `Uint8Array` | Copy (TextEncoder/Decoder) |

---

### Comparison: String vs Span<char> vs uint8[]

| Feature | `string` | `Span<char>` | `uint8[]` |
| :--- | :--- | :--- | :--- |
| **Ownership** | Owned (Heap/RC) | Borrowed (View) | Owned (Heap/RC) |
| **Slicing** | Returns new `string` (Copy) | Returns `Span<char>` (Zero-copy) | Returns new `uint8[]` (Copy) |
| **Mutation** | Allowed (COW-protected) | Allowed (on source buffer) | Allowed (direct) |
| **Bridge** | `.asBytes()` → `uint8[]` | N/A | `.asString()` → `string` |
| **Use Case** | Text processing, standard TS | Parsing, high-perf views | Binary I/O, protocols, hashing |

## Collections and Compound Types

MetaScript provides a robust set of collection types that map to high-performance C implementations while maintaining TypeScript's ergonomic syntax.

### 1. Map<K, V> (HashMap)
A high-performance, open-addressing hash table.

- **Implementation**: ARC-managed `msMap` with a Structure-of-Arrays (SoA) layout for optimal cache performance.
- **Key Types**: Phase 1 supports `string` keys (systems-optimized).
- **Methods**: `get()`, `set()`, `has()`, `delete()`, `clear()`, and `.size`.

```typescript
const symbols = new Map<string, Symbol>();
symbols.set("main", sym);
if (symbols.has("main")) {
    const s = symbols.get("main");
}
```

### 2. Set<T>
A collection of unique values, implemented as a wrapper around `Map<T, void>`.

- **Methods**: `add()`, `has()`, `delete()`, `clear()`, and `.size`.

```typescript
const visited = new Set<string>();
visited.add("module_a");
if (visited.has("module_a")) { /* ... */ }
```

### 3. Tuples
Fixed-size, heterogeneous collections.

- **Implementation**: Tuples are lowered to **unique C structs** (stack-allocated) rather than heap-allocated arrays.
- **Access**: Indexed access (`t[0]`) is rewritten to direct struct field access (`t._0`) in C.

```typescript
function getResponse(): [string, number] {
    return ["OK", 200];
}

const [msg, code] = getResponse();
console.log(msg); // msg is pair._0 in C
```

### 4. Record<K, V>
A TypeScript utility type that is semantically identical to `Map<K, V>` in MetaScript.

```typescript
const registry: Record<string, number> = new Map();
```

---

### Collection Performance & Memory

| Type | Allocation | Access Time | C Mapping |
| :--- | :--- | :--- | :--- |
| `Map<K, V>` | Heap (RC) | O(1) Average | `msMap` |
| `Set<T>` | Heap (RC) | O(1) Average | `msMap` (value-less) |
| `Tuple` | **Stack** | O(1) Direct | Custom `struct` |
| `Array` | Heap (RC) | O(1) Direct | `msArray` |

### 1. Dynamic Arrays (`T[]`)
The standard general-purpose array. It is heap-allocated and managed via Deterministic Reference Counting (DRC).

- **Allocation**: Heap (Reference Counted).
- **Size**: Growable.
- **Behavior**: Passed by reference (incref/decref).
- **Usage**:
  ```typescript
  const items: number[] = [1, 2, 3];
  items.push(4); // Growable
  ```

### 2. Fixed-Size Arrays (`T[N]`)
Used for high-performance scenarios where heap allocation is undesirable. These are allocated directly on the C stack.

- **Allocation**: Stack (within a C struct).
- **Size**: Fixed at compile-time (must be a constant).
- **Behavior**: Passed by value (struct copy) unless passed to a `Span<T>`.
- **Usage**:
  ```typescript
  const buffer: uint8[1024] = [0]; // Stack-allocated 1KB buffer
  // buffer.push(1);               // Compile Error: Fixed size
  ```

### 3. Spans (`Span<T>`)
A non-owning view (pointer + length) into a `T[]` or `T[N]`. This is the MetaScript equivalent of reference `openArray` or Zig's slices.

- **Allocation**: None (View only).
- **Size**: Fixed window into existing data.
- **Behavior**: **Zero-copy calling convention**. When passed to a function, it is expanded into two scalar C arguments: `T* data` and `int64_t len`.
- **Usage**:
  ```typescript
  function process(data: Span<number>): void {
      for (const x of data) console.log(x);
  }

  const dynamic = [1, 2, 3];
  const fixed: number[3] = [4, 5, 6];

  process(dynamic); // Implicit coercion: zero-copy
  process(fixed);   // Implicit coercion: zero-copy
  ```

---

### Key Usage & Implementation Notices

#### Implicit Coercion (The Bridge)
The compiler automatically coerces `T[]` and `T[N]` into a `Span<T>` when passed as function arguments. This allows you to write a single function that accepts any array-like source without performance penalties.

#### Zero-Copy Slicing
Slicing an array into a `Span` is a zero-cost operation. MetaScript supports both exclusive and inclusive ranges:

- **Exclusive (`..`)**: `arr[start..end]` — slice from `start` to `end` (length = `end - start`). Matches TypeScript `slice` semantics.
- **Inclusive (`...`)**: `arr[start...end]` — slice from `start` to `end` inclusive (length = `end - start + 1`).

```typescript
const items = [10, 20, 30, 40, 50];
const exc: Span<number> = items[1..3];  // [20, 30] (length 2)
const inc: Span<number> = items[1...3]; // [20, 30, 40] (length 3)
```

#### Lifetime Restrictions (Safety)
To prevent dangling pointers, `Span<T>` is subject to strict "Borrow" rules:
1. **No Storage**: A `Span<T>` cannot be stored as a field in a class or interface.
2. **No Return**: A `Span<T>` created from a local variable cannot be returned from a function.
3. **Parameter Primary**: The primary use case for `Span<T>` is as a function parameter to enable zero-copy data processing.

#### Summary Table

| Type | Allocation | Passed As (C) | Ownership | Use Case |
| :--- | :--- | :--- | :--- | :--- |
| `T[]` | Heap | Pointer (RC) | Owned | General app logic |
| `T[N]` | Stack | Struct (Copy) | Owned | SIMD, Buffers, Math |
| `Span<T>`| N/A | `ptr` + `len` | Borrowed | Performance, Parsers |


### JSON

Typed JSON parsing with TypeScript-native syntax. The type parameter `T` is required — no `any` fallback:

```typescript
interface Person {
    name: string;
    age: number;
}

// Parse with full type safety — returns Result<T, string>
const person = try JSON.parse<Person>('{"name": "Son", "age": 30}');
person.name    // normal struct field access, LSP autocompletes

// With try/catch fallback
const config = try JSON.parse<AppConfig>(raw) catch defaultConfig;

// Nested types — dot access chains naturally
const app = try JSON.parse<AppConfig>(readFile("config.json"));
app.server.host    // fully typed through nesting

// Stringify any interface
const json = JSON.stringify(person);  // '{"name":"Son","age":30}'
```

Implemented via monomorphization — `JSON.parse<Person>` generates a specialized parse function at compile time using `T`'s field names and types. Same mechanism as `Array<T>` and `Result<T, E>`. See `docs/JSON.md` for full design.

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
// Standard FFI (names match)
extern function free(p: Ptr<void>): void;

// Aliased FFI (names differ)
extern function malloc(size: number): Ptr<void> from "ms_malloc";

// cstring is used for zero-copy C interop. 
// Standard 'string' implicitly coerces to 'cstring'.
extern function printf(fmt: cstring, ...args: unknown[]): void;

extern class FILE { }
extern const STDIN: FILE from "ms_stdin";

// Object-Oriented FFI
extern class console {
    extern log(value: string): void from "msPrintln";
}
```

### Distinct Types
```typescript
distinct type UserId = number;    // Nominal typing wrapper
distinct type Email = string;     // Cannot assign string to Email
```

### Quote Expressions
```typescript
// Capture a block of code as an AST (for macros)
const code = quote {
    const x = 1;
    console.log(x);
};
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

## AST Node Kinds (112 total)

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

### Declarations (8)
`function_decl`, `class_decl`, `enum_decl`, `interface_decl`, `struct_decl`, `type_alias_decl`, `import_decl`, `export_decl`

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

Built-in testing via the `test` and `assert` keywords. Tests are compiler intrinsics — `assert` is a keyword-level statement that gives the compiler access to the expression AST for power assert instrumentation. Test code is stripped from non-test builds.

```typescript
test "addition" {
    assert add(1, 2) === 3;
}

test "ternary" {
    const sign = x > 0 ? "pos" : "neg";
    assert sign === "neg" : "negative value should give neg";
}

test "setup" {
    const s = setup();
    assert s !== null;
}
```

### Power Assert

Inside `test` blocks, `assert` automatically instruments compound expressions to capture intermediate values. On failure, it displays each sub-expression value with vertical bar markers showing position:

```
Power Assert Failed:
  assert a.x === b + c
         |   |    | | |
         |   |    | | 3
         |   |    | 5
         |   |    2
         |   false
         42
```

Decomposed expression types: binary (`===`, `+`, etc.), member access (`a.x`), unary (`!x`), call expressions (`f(x)`). Literals are not captured (their value is obvious from the source).

Outside `test` blocks, `assert` emits a simple abort on failure — no power assert decomposition.

### Running Tests

Run with `bun run test-ms file.ms`. Supports `--filter="name"` to run matching tests only.

| Syntax | Behavior |
|--------|----------|
| `test "name" { ... }` | Register a test case |
| `assert expr;` | Assertion — power assert in tests, abort outside |
| `assert expr : "msg";` | Assertion with custom failure message |

Output: `PASS`/`FAIL` per test, summary line (`N passed, N failed, N skipped`), exit code 1 on any failure.

## Reserved Words

`type` is reserved in MetaScript. Use `tokenType`, `nodeType`, etc. for field names.
