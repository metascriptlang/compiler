# MetaScript Language Reference

MetaScript is a systems programming language with TypeScript syntax that compiles to C, JavaScript, and Erlang. This document covers all syntax the self-hosted compiler must handle.

## Primitive Types

| Type | Description | C Mapping |
|------|-------------|-----------|
| `number` | IEEE 754 f64 (default numeric) | `double` |
| `string` | Immutable UTF-8 (surface); COW + in-place-append engine internal | `msString` |
| `boolean` | true/false | `bool` |
| `char` | 8-bit character (numeric) | `char` / `int8_t` |
| `cstring` | C-compatible string pointer | `const char*` |
| `void` | No value | `void` |
| `never` | Unreachable (bottom type) | N/A |
| `null` | Null value | `NULL` |
| `undefined` | Alias of `null` (warns — prefer `null`) | `NULL` |
| `unknown` | Top type — opaque until cast | `void*` |

**There is no `any`.** `unknown` is the sole top type: opaque, readable only
through an explicit cast. A native target has no dynamic member lookup, so an
annotation promising one would be a promise the backend cannot keep — the
checker rejects it and names the alternative.

#### `unknown` vs `Ptr<void>` — same C repr, opposite intent

Both compile to `void*`, so it is tempting to treat them as one thing. They are
not, and picking the wrong one hides a real bug:

| | `unknown` | `Ptr<void>` |
|---|---|---|
| **Means** | "a value I must prove the type of before I touch it" | "a raw machine address" |
| **Reads** (`x.field`, `x()`, `x + 1`) | rejected by the checker — narrow with `as` first | allowed where pointer arithmetic / FFI expects it |
| **What flows in** | anything pointer-shaped (`Ref`, `Ptr`, `null`, `cstring`, another `unknown`); value types (`number`, a bare struct) are rejected — box them or pass a `Ref` | whatever the FFI/`malloc` boundary hands back |
| **Use for** | the `null as unknown as T` nullable-field idiom; opaque handles crossing an API you re-narrow at the other end | C interop, allocator return values, deliberately untyped memory |

Rule of thumb: reach for `Ptr<void>` **only** at an `extern`/FFI boundary or when
you genuinely mean "an address." Everywhere else the opaque value wants
`unknown`, because the checker's narrow-before-use discipline is the whole point
— `Ptr<void>` gives you none of it (`p.field` compiles and reads garbage).

`unknown` is **not** a universal top type in the TypeScript sense. TS `unknown`
accepts every value because every JS value is already boxed; MS keeps values
unboxed for native speed, so a value type has no `void*` form to reinterpret and
is rejected on the way in. The discipline TS `unknown` actually buys —
can't-touch-until-narrowed — is preserved in full; only the "literally any value
fits" part is traded away, on purpose. If you need to hold "one of several
concrete types," that is a discriminated union or a generic, not `unknown`.

**`undefined` is accepted as an alias of `null`** for TypeScript
backward-compatibility, and warns so the code can be migrated to `null`. MS has
one absent value, not two.

```ms
function f(x: any): void {}          // ✗ 'any' is not a MetaScript type - use 'unknown' with an explicit cast
let a: undefined = null;             // ⚠ 'undefined' is an alias of 'null' - prefer 'null'  (compiles)
function g(s: string | undefined) {} // ⚠ same warning; behaves exactly as `string | null`
function h(x: unknown): void {}      // ✓
const t = null as unknown as Token;  // ✓ the nullable-field idiom
```

### Sized Integer Types

Fixed-width integers for systems programming. These are true integer types in the C backend — not boxed floats.

| Type | Size | Signed | C Mapping | Range |
|------|------|--------|-----------|-------|
| `int8` | 8-bit | yes | `int8_t` | -128 to 127 |
| `int16` | 16-bit | yes | `int16_t` | -32,768 to 32,767 |
| `int32` | 32-bit | yes | `int32_t` | -2³¹ to 2³¹-1 |
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
| `float32` | 32-bit | `float` |
| `float64` | 64-bit | `double` |

`number` is `float64`. The `float32` type is available for interop with C APIs or GPU buffers that require single-precision.

> **Reserved keywords**: `int`, `float`, and `double` are reserved by the lexer (they cannot be used as identifiers) but are **not currently usable as type names** — use the sized forms (`int32`, `float32`, `float64`). The unsized aliases are reserved for a future revision.

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
float32   float64
int       float     double                       (reserved, not yet usable as type names)
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
| `==` | EQ_EQ | Equality — same as `===` (no `undefined`, so no loose form); the JS backend emits `===` |
| `===` | EQ_EQ_EQ | Equality |
| `!=` | BANG_EQ | Inequality — same as `!==`; the JS backend emits `!==` |
| `!==` | BANG_EQ_EQ | Inequality |
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
  0xFFn           // Hex/binary/octal BigInt (0x/0b/0o + n)
  ```

  ### Callable namespaces — `BigInt()` *and* `BigInt.asUintN(...)`

  A small closed set of global names is BOTH a callable function AND a
  namespace carrying static methods, like the JS primitive-wrapper globals:

  | Name | Call form | Static members |
  |---|---|---|
  | `BigInt` | `BigInt("123")` (string → bigint) | `asIntN(bits, v)`, `asUintN(bits, v)` |
  | `String` | `String(42)` | `fromCharCode(n)` |
  | `Number` | `Number(x)` | `isInteger(x)` |
  | `Boolean` | `Boolean(x)` | — |
  | `Symbol`, `Object`, `Array` | — | namespace surface |
  | `Buffer`, `JSON`, `Promise`, `Map`, `Set` | — | namespace only (not callable) |

  Verified surface (C == JS, `msc_n5` 2026-09-01):

  ```typescript
  const a = BigInt("123") + 0xFFn;          // 378
  a.toString(16);                            // "17a"
  BigInt.asUintN(8, 255n + 1n);              // 0n  (wraps mod 2^8)
  BigInt.asIntN(8, 255n);                    // -1n
  Number.isInteger(5);                       // true
  String.fromCharCode(72);                   // "H"  (one code unit per call)
  ```

  Rules:
  - `bits` is an int; the value must be bigint. Mixed `bigint`/`number`
    arithmetic is a type error — convert explicitly (`BigInt(n)`, `Number(b)`).
  - A local shadowing the name wins for the CALL form; the namespace arm only
    binds for function-kind symbols (`const BigInt = 5; BigInt.asUintN(1, 0n)`
    is "Property does not exist on int32", not a namespace hit).
  - Mechanism: `isTypeLevelAccess` in the checker (allowlist + `staticReceivers` cache).
    Pinned by corpus `744-namespaceCallSurface`, `743-bigintOps`.

  ### BigInt carriers & JSON

  - `Buffer.readBigUInt64LE/BE` / `readBigInt64LE/BE` return **bigint** — exact
    beyond 2^53 on both backends; `writeBig*` take bigint. Node parity.
    Pinned by corpus `746-bufferSurface`.
  - `JSON.stringify` **refuses bigint at compile time** (Node throws at
    runtime): `bigint is not JSON-serializable — convert with .toString()
    first`. `JSON.parse` never produces bigint.


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

Declarations below are **module-level**: `class`, `interface`, `struct`, `enum`, `type`, `extern`,
`actor` and `macro` must appear at the top level of a file. Writing one inside a function body,
arrow body, bare block or `test` block is a compile error (`local <kind> 'X' is not supported yet -
move the declaration to module level`). A nested `function` is the one exception — it is a closure
and is fully supported. A declaration inside a module-level `when` block is module-level and works.

### Variables
```typescript
const x = 42;                    // Immutable binding
const x: number = 42;            // With type annotation
let y = "hello";                 // Mutable binding
let y: string = "hello";         // With type annotation
var z = true;                    // Function-scoped (legacy)
```

### Void

`void` is the return type of a function that produces no value. The type
rules follow TypeScript strict mode; the value follows the machine: a void
call returns nothing at the C ABI, so the few value positions TypeScript
forgives observe a materialized carrier instead — and with no `undefined`
in the language, that carrier is `null`.

Refused (measured against `tsc --strict`):

```typescript
function f(): void {}
const a: number = f();      // 'void' is not assignable to type 'number'
if (f()) {}                 // cannot be tested for truthiness (also while/for/ternary/!/&&/||)
const n = f();
const s = n + 1;            // operator '+' cannot be applied to 'void'
const b = n === 1;          // 'void' and 'number' have no overlap
```

Forgiven, observing the null carrier — identical output on C and JS:

```typescript
const n = f();              // bind: n is void, carrier null
console.log("n=" + n);      // n=null
const eq = n === null;      // true
const m = n;                // chained bind carries null too
let x: void = f(); x = f(); // void slot, re-assignment stays legal
const aw = await h();       // h(): Promise<void> → aw is null
```

The bind lowers to `f(); const n = null;` and the binding is retyped to
null (C representation `void*`), so no `void` local, array element, or
async env field ever reaches the C emitter. TypeScript's
`undefined`-flavoured rules translate by one rename: `undefined` is
assignable to `void` there, `null` is assignable to `void` here.

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

// Parameter destructuring — sugar for `const { label, count } = props;` at the top of
// the body. The pattern needs a type: an annotation, or the slot's contextual type.
interface Props { label: string; count: number; }
function Counter({ label, count }: Props): string { return label + count.toString(); }
const twice = ({ count }: Props): number => count * 2;
items.forEach(({ label }) => console.log(label));   // typed from the callback slot
function bad({ label }) { ... }                        // error: a destructured parameter needs a type annotation
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

**Optional fields**: `label?: string` desugars to `label: (string) | null` — omitting the field at construction stores `null`, and a null check narrows back to the base type (verified 2026-08-13, corpus `015-optionalFieldNull`, C+JS):

```typescript
interface Handler { tag: int32; cb?: (x: int32) => int32; }
const h: Handler = { tag: 1 };            // cb omitted → null
if (h.cb !== null) { h.cb(7); }           // narrow, then call
```

A **bare** function-typed field (no `?`, no `| null`) must be initialized — a NULL function pointer has no safe default, so the checker rejects omission; `?` is the opt-out. `?` is a parse error on `struct` fields (a value type would silently become a union — write the union explicitly) and on class methods (declare a function-typed property instead). `?` applies to interface fields, class properties, and anonymous object types alike.

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

### BitSet&lt;E&gt;

A set of enum members whose bit position is the member's **ordinal**. The representation
follows the member count: `uint8` up to 8 members, `uint16` up to 16, `uint32` up to 32, `uint64`
up to 64, and a byte array `uint8[⌈n/8⌉]` above that, up to 65536 members (`sizeof` is 1, 2, 8 and
13 for 6, 15, 40 and 100 members). `Flag.A | Flag.B` infers `BitSet<Flag>` instead of widening to
`int32`, so the enum identity survives and two different enums can never be mixed.

```typescript
enum Flag { Mutable, Used, Consumed, Cursor }   // ordinal values

const base: BitSet<Flag> = Flag.Used | Flag.Cursor;
const g = base.incl(Flag.Mutable).excl(Flag.Used);
if (g.has(Flag.Cursor)) { /* ... */ }

const none = 0 as BitSet<Flag>;                  // the empty set; there is no literal
const one = none.incl(Flag.Used);                // a one-member set
const rest = base.difference(g);                 // no operator for the difference
if (rest.isSubsetOf(base) && !rest.isEmpty()) { /* ... */ }

for (const m of base) { console.log(m.toString()); }   // Used, Cursor: ordinal order
console.log(base.toString());                          // {Used, Cursor}

flags & TypeFlag.HasAsgn        // now a type error when `flags` is BitSet<NodeFlag>
```

`BitSet<E>` is a value type, so it has **no mutating methods**: every operation returns a new set,
and adding in place is `s = s | Flag.Used` (`|=` does not lex, KNOWN-ISSUES L24). Only enums with
ordinal values participate — an enum with hand-assigned values (`A = 1, B = 2`) is already a flag
encoding and keeps its numeric meaning.

| Member | Result | Notes |
| :--- | :--- | :--- |
| `has(m)` | `boolean` | |
| `incl(m)`, `excl(m)` | `BitSet<E>` | |
| `isEmpty()` | `boolean` | |
| `union(o)`, `intersection(o)`, `symmetricDifference(o)` | `BitSet<E>` | also `\|`, `&`, `^`; a bare member joins from either side (`Flag.Used \| s`) |
| `difference(o)` | `BitSet<E>` | no operator: `s & ~o` and `~s` are type errors |
| `isSubsetOf(o)`, `isSupersetOf(o)`, `isDisjointFrom(o)` | `boolean` | `<=` and `<` are rejected |
| `size()` | `int32` | |
| `==`, `!=` | `boolean` | two sets over the same enum; `s == Flag.Used` is rejected |
| `toItems()` | `E[]` | members in ordinal order; what `for..of` calls; allocates |
| `toString()` | `string` | `{Used, Cursor}`, `{}` when empty; allocates |
| `hash()` | `int64` | C only; what makes `HashMap<BitSet<E>, V>` work |

Measured 2026-09-15 on the installed `v0.2.54`, identical on C and JS unless a row says otherwise.
Three spellings look right and are not:

- `Flag.Used as BitSet<Flag>` compiles and reads the **ordinal as the mask**: ordinal 1 becomes the
  set `{Mutable}`. A one-member set is `(0 as BitSet<Flag>).incl(Flag.Used)`;
  `const s: BitSet<Flag> = Flag.Used` is a type error.
- Implicit text conversion: `` `${s}` ``, `"x " + s` and `String(s)` fail the C compile and print the
  representation word on JS (`12` for bits 2 and 3); `console.log(s)` prints `<BitSet>` on C and the
  word on JS (KNOWN-ISSUES L32). `s.toString()` is right in a template, a concatenation and `+=` on
  both backends.
- An integer mask crosses with one cast each way: `(mask as uint8) as BitSet<Flag>` at the band's
  width, and `s as uint32` back.

Why it is shaped this way — the cross-language survey, the one TypeScript idiom it costs
(`(flags & F.X) != 0` becomes `.has()`), the width rules, and the deliberately deferred
set literal `{A, B}` — is recorded in
[`LANG-PRIMITIVE.md`](LANG-PRIMITIVE.md#bitsete--typed-ordinal-set-design-record-2026-09-07).

### Type Aliases

Simple type aliases and generic type aliases (Tier 3).

```ms
type ID = number;
type StringOrNumber = string | number;
type Callback = (data: string) => void;

// Generic type aliases — type parameters substituted at each use site
type Box<T> = { value: T };
type Pair<A, B> = { first: A, second: B };

const b: Box<number> = { value: 42 };         // Box<number> = { value: number }
const p: Pair<string, number> = { first: "hi", second: 1 };

// Field type mismatch is caught:
// const bad: Box<number> = { value: "wrong" };  // error: string not assignable to number
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

### Converter Declarations

Compile-time source since 2026-07-31 (main `9ce47eb`); runtime source since 2026-09-20 (`wt/inbox-directive`).

Third routine kind besides `function` and `macro`: a routine the COMPILER calls where a value of its
source type meets its target type. It is looked up by the PAIR of types, never by its name.

```typescript
// function  — invoked explicitly by code
// macro     — runs at compile time, invoked explicitly by code (AST -> AST)
// converter — invoked BY THE COMPILER at a type boundary
export converter element(node: Node): VNode { /* macro-engine body: source is Node */ }
export converter jsonToInt32(v: JsonValue): int32 { return v.asInt32(); }   // runtime body
```

The source type picks the body's domain: `Node` makes the body a macro that runs at compile time and
expands in place (JSX, `docs/LANG-JSX.md`); any other source makes it an ordinary function that runs at
run time, and the compiler inserts a call to it. Both are callable by name like any routine.

Rules for a runtime-source converter (each is pinned in `src/test/c/converter.ms`; the quoted text is
the diagnostic):

1. **Shape**: module level, exactly one parameter, no default value, not generic, an explicit return
   type — "converter 'f' is only allowed at module level", "must take exactly one parameter",
   "parameter cannot have a default value", "cannot be generic", "requires an explicit return type".
2. **Ownership**: declared in the module that declares its source type or its target type —
   `converter numToBool(n: float64): boolean` is "converter 'numToBool' must be declared in the module
   that declares 'float64' or 'boolean'", so no import can change how two builtins, or another
   module's type, convert. A `Ref` alias, `T | null` and `Maybe` are looked through to the named type.
3. **Scope**: in scope like any symbol — declared here, imported by name, re-exported through a hub, or
   from the prelude (the JSON converters). A converter that is not in scope never applies.
4. **Lookup by type identity**: the source must be exactly the value's type (an alias is looked through,
   a subtype is not); two types named `Meters` in two modules do not share a converter. Two in-scope
   converters for one pair are an error at the use: "'a' and 'b' both convert 'Box' to 'int32' — the
   compiler never chooses; call one explicitly".
5. **Where it applies**: a typed slot (declaration, assignment, field, return), an argument of a call
   with one signature, `as U` when `as` has no conversion of its own (numeric ↔ numeric and distinct ↔
   its base stay casts), and an operand whose other side has a static type the operand does not have
   (arithmetic, comparison, equality, the right side of `op=`, `+` with a string). Not at: a condition,
   a receiver (`b.length` is still "no member"), an assignment or `++` target, a formal with open
   generic parameters, or overload scoring (an overloaded call needs a candidate that takes the value).
   For `+` with a string a type that declares `valueOf` reads `valueOf` first, as JavaScript does.
6. **One step**: the converter's return type must be the target, or the target is `T | null` of it;
   `float64 → Seconds` and `Seconds → Minutes` do not make `float64 → Minutes`.
7. **No self-application**: inside its own body the converter does not apply ("'boxToText' does not
   apply inside its own body — write the conversion explicitly"), and neither does it in any routine its
   body reaches through resolved calls ("'boxToInt' is applied implicitly in 'half', which 'boxToInt'
   reaches through its calls — the conversion would recurse"). The reference compiler builds that
   program and it dies at run time; measured here before the rule: C built and exited silently, JS
   overflowed the stack.

Measured on every corpus lane (C, ORC, danger, JS, ESM, identical output):

| program | shows | stdout |
|---|---|---|
| `784-runtimeConverter` | slot, argument, return, `as U`, nullable slot, generic formal and condition keep the value | `slot 41\|arg 42\|ret 43\|as box#44\|maybe 1.5\|generic 45\|cond yes` |
| `785-runtimeConverterOperand` | operands, `+=`, comparison, equality, concat; a converter to `boolean` does not touch a condition | `add 45\|radd 46\|mul 88\|acc 44\|gt true\|eq true\|text n=box#44\|cond yes` |
| `786-jsonConverter` | parsed JSON through the prelude converters | `slot Ann 41 true 1.5\|arg 41\|as 41\|op 42 hi Ann true 3` |
| `787-cborConverter` | CBOR converters imported by name | `slot Ann 41\|arg 41\|as 41\|op 42 hi Ann true` |

Before these converters `j.age + 1` on a parsed JSON value was "operator '+' cannot be applied",
`"hi " + j.name` printed `hi <object>` on C, and `j.age > 40` compiled without reading the number.

Not verified: a converter whose source or target is a generic instance; `build.ms` `globalImports` as
the scope of a runtime converter; the cost of rule 7 on a program with many converters (on
`src/index.ms`, which declares none, an interleaved A/B was below the noise of a loaded machine).

Known gap: `T | null` of a value type is cached by type name, so a converter to `a.ms`'s `Seconds` does
not reach a `Seconds | null` slot once `b.ms`'s own `Seconds | null` was built first
(`~/metascript/.inbox/compiler/2026-09-20-maybe-cache-keyed-by-type-name-mixes-modules.md`).

Design note (2026-09-20). The reference compiler has the same routine kind and the same insertion
points; three places are deliberately narrower here. It lets any module declare any pair (`if 5:`
starts compiling project-wide once `converter toBool(x: int): bool` is imported) — rule 2 closes that.
It takes the first of two converters for one pair silently — rule 4 refuses. It applies converters
inside overload scoring and to both operands (`j + j` gives `0`) — rule 5 applies them only where the
target is already settled and to the operand whose other side is typed. It replaces the old
`as<TargetType>` protocol, which found `asU` by the TARGET'S NAME, so any method called `asString`
became an implicit conversion (`asString(this arr: uint8[])` in std made `const s: string = bytes`
compile and run) — a converter is found by its pair of types, and naming a method `asInt32` now means
nothing to the compiler (`const s: string = bytes` now reaches the `string`-slot gap of
`~/metascript/.inbox/compiler/2026-09-19-union-into-string-slot-accepted.md`: the checker says nothing and
clang rejects the C): `const n: int32 = w` with only `asInt32(this w: W)` declared is "Type 'W' is not
assignable to type 'int32' — … (convert explicitly or declare a converter to 'int32')".

First user: JSX boundary lowering — see `docs/LANG-JSX.md` "Boundary Lowering via Converter".

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

**Inferring one type parameter from several arguments.** The first argument binds `T`; every
argument that binds the same `T` is a candidate. The binding starts as the first candidate and
moves to a later one only when that one is strictly wider (the current binding fits it, not the
reverse); every candidate must then fit the chosen type, and the one that does not is reported.
Argument order never changes the result.

```typescript
class Animal { name: string = ""; }
class Dog extends Animal { breed: string = ""; }
function pair<T>(a: T, b: T): T { return a; }

pair("s", "t");              // T = string
pair(animal, dog);           // T = Animal — Dog fits an Animal binding
pair(dog, animal);           // T = Animal — Animal is strictly wider than Dog
pair3(dog, cat, animal);     // T = Animal, in any argument order
pair(1, 2.5);                // T = float64 — int32 fits float64, not the reverse

pair("s", 3);                // error: arg 1 got int32, expected string — 'T' was bound by argument 0
pair(dog, cat);              // error: siblings, no candidate covers both (TypeScript rejects this too)
pair(anInt32, anInt64);      // error in either order: integer widths never widen into each other
```

One of these differs from TypeScript, deliberately: TypeScript has a single `number`, so
`pair(anInt32, anInt64)` is fine there. MetaScript keeps `int32`, `int64` and `float64` distinct
(see "Numeric Types"); only `int32` → `float64` counts as wider. Say which width you mean:
`pair<int64>(anInt32, anInt64)`.

**Explicit type arguments.** `f<A, B>(...)` must name exactly as many type arguments as the
declaration has parameters — on functions, static methods, templates and `new` alike. Too few,
too many, or any on a non-generic function are all rejected:

```typescript
function f2<A, B>(a: A, b: B): A { return a; }
f2<string>("s", 1);          // error: Wrong number of type arguments to 'f2': expected 2, got 1
f2<string, int32>("s", 1);   // ok
```

A written type argument *is* the binding: every argument must fit it and it is never widened.
`pair<Dog>(animal, dog)` fails at argument 0 even though `pair(animal, dog)` would infer
`Animal`. Templates follow the same rule (`id2<string>(3, 4)` reports argument 0), and a generic
rest parameter checks each trailing argument against its element type (`f<T>(a: T, ...r: T[])`
called `f("a", 3)` reports `arg 1: got int32, expected string`). A default in a function's
parameter list (`<T, E = string>`) is parsed but not applied yet: pass every type argument, or
pass none and let them infer.

An explicit type argument settles `T` before the arguments are looked at: `pair<Animal>(dog, dog2)`
instantiates the `Animal` version even though both arguments are `Dog`, `pair<Dog>(dog, animal)` is
an error, and an explicit binding is never widened.

### Union & Intersection Types
```typescript
type StringOrNumber = string | number;
type Shape = Circle & Drawable;

// Discriminated union with shared boolean-literal field — narrows via `if (r.ok)`.
// See "Discriminated Union Types" below for full coverage of all DU forms.
type R<T, E> =
    | { ok: true;  value: T }
    | { ok: false; error: E };

// Intersection types — combine multiple types
type Extended = IUser & { role: string };

// Struct intersection — compose value types from data-only interfaces
struct SuperUser = IUser & { role: string; };
```

### Discriminated Union Types

MetaScript supports two flavors of discriminated unions, both lowered to a tagged C union (`_tag` + variant payloads):

1. **`match`-type DU** — explicit `match (disc: T) { Key => {...}, ... }` syntax. Discriminator can be an enum OR a boolean.
2. **TS-style DU** — structural `{ disc: "x", ... } | { disc: "y", ... }` with a shared literal-typed discriminator field (string or boolean). Mirrors TypeScript's discriminated union pattern.

Both forms support narrowing in `if` branches via discriminator equality, so the compiler can prove which variant fields are accessible in each branch.

#### `match`-type with enum discriminator

```typescript
enum NodeKind { NumLit, StrLit, BinExpr }

type NodeData = match (kind: NodeKind) {
    NodeKind.NumLit  => { value: number },
    NodeKind.StrLit  => { value: string },
    NodeKind.BinExpr => { op: string, left: Node, right: Node },
};
```

The discriminant field (here `kind`) is the enum value. Each arm maps one enum member to a set of variant-specific fields.

#### `match`-type with boolean discriminator

For two-state values (success/failure, present/absent), boolean is the natural discriminator. The keys are `true` and `false` literals:

```typescript
type Result<T, E> = match (ok: boolean) {
    true  => { value: T },
    false => { error: E },
};
```

This is exactly how the built-in `Result<T, E>` is defined internally — a boolean-discriminated tagged union, with `r.value` only reachable when `r.ok` is true and `r.error` only reachable in the false branch.

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

#### TS-style with literal discriminator

A structural union of object types whose variants share a discriminator field with a literal type. The compiler infers which variants belong to the union by spotting the shared discriminant.

```typescript
// String-literal discriminator
interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
type Shape = Circle | Square;

function area(s: Shape): number {
    if (s.kind === "circle") return s.radius * s.radius * 3;
    return s.side * s.side;
}

// Boolean-literal discriminator
interface Ok<T>  { ok: true;  value: T;     }
interface Err<E> { ok: false; error: E;     }
type R<T, E> = Ok<T> | Err<E>;
```

In each branch the compiler narrows the union to a single variant, so accessing variant-specific fields (`s.radius`, `r.value`) is type-safe.

#### C Backend

All three forms lower to the same C layout — a wrapper struct with a numeric `_tag` plus an anonymous union over per-variant struct payloads:

```c
// Generated C for NodeData (enum-disc match-type):
typedef struct {
    NodeKind _tag;          // enum type for match-type with enum disc
    union {
        struct { double value; } v0;           // NumLit
        struct { msString value; } v1;         // StrLit
        struct { msString op; Node left; Node right; } v2; // BinExpr
    };
} NodeData;
```

For boolean-disc and TS-style DUs, `_tag` is `int32_t` (variant index). The discriminator field (`ok`, `kind`) lives inside each variant struct at the same offset, so accessing `r.ok` reads it through `v0`/`v1` overlapping memory.

#### Choosing the right form

| Use case | Best fit |
|---|---|
| Two-state value (success/failure) with custom payloads | `match (ok: boolean) { true => ..., false => ... }` |
| Many variants identified by an enum | `match (kind: K) { K.A => ..., ... }` |
| Adapting external/JSON shapes with `kind: "..."` strings | TS-style string DU |
| Need narrowing on a boolean field — minimal ceremony | TS-style boolean DU (`{ok: true, ...} | {ok: false, ...}`) |

Plain unions (`A | B` without a shared discriminator) work when variants have unique field names, but offer no construction validation and pick the wrong variant on field-name collision — prefer the discriminated forms above.

### Enum Literal Types

Specific enum members as types (Tier 1). An enum literal type is a subtype of its enum — `K.A` is assignable to `K`, but `K` is not assignable to `K.A`.

```ms
enum K { A, B, C }

// Enum literal as parameter type — only accepts that specific member
function handleA(k: K.A): void { }
handleA(K.A);      // OK
// handleA(K.B);   // error: got K.B, expected K.A

// Enum literal as return type
function makeA(): K.A { return K.A; }

// Union of enum literals
function handleAorB(k: K.A | K.B): void { }

// Variable annotation preserves literal type
const k: K.A = K.A;    // k: K.A (literal)
const k2 = K.A;        // k2: K (widened — no annotation)
```

### Function Overload Signatures

Body-less overload declarations followed by a single implementation (Tier 1, TypeScript parity).

```ms
enum K { A, B }

function f(k: K.A): string;          // overload sig 1
function f(k: K.B): string;          // overload sig 2
function f(k: K): string {           // implementation (must come last)
    return "result";
}

f(K.A);  // matches sig 1 (Exact) over impl (Subtype)
f(K.B);  // matches sig 2
f(K.C);  // matches impl (fallback)
```

Rules:
- Implementation must come LAST after all overload signatures
- All sigs must have the same arity as the implementation
- Each sig's param types must be assignable to the impl's corresponding params
- Each sig's return type must be assignable to the impl's return type
- At least one non-sig definition (the implementation) must exist

**Known limitation — literal args**: Overload resolution currently scores each
argument against each candidate's param type *without* per-candidate contextual
re-checking. This means object-literal arguments (`{ ... }`) get an anonymous
structural type during scoring that does **not** match specific named struct
param types. Until speculative per-candidate checking lands, do **not** add
overload signatures to functions that take object literals as discriminated
arguments (e.g. a hypothetical `createNodeAt(NodeKind.X, { ... }, loc)` API).
Use a single wide signature with a union param type instead — the caller can
add an `as XxxData` cast if needed. Tier 3 generic aliases
(`createNodeAt<K extends NodeKind>(kind: K, data: DataFor<K>, loc): Node`)
will be the proper long-term solution.

### Conditional Types

Type-level if/else based on assignability (Tier 3).

```ms
// Basic conditional: T extends U ? TrueType : FalseType
type IsNumber<T> = T extends number ? string : boolean;
const a: IsNumber<number> = "yes";    // resolves to string
const b: IsNumber<string> = true;     // resolves to boolean

// Nested conditionals
type Classify<T> =
    T extends string ? "text" :
    T extends number ? "num" :
    "other";

// infer keyword — extract type from a pattern
type Unwrap<T> = T extends Array<infer U> ? U : T;
const x: Unwrap<number[]> = 42;       // U inferred as number
const y: Unwrap<string> = "hi";       // no match → T = string

// infer with generic aliases
type Box<T> = { value: T };
type Unbox<T> = T extends Box<infer U> ? U : never;
const v: Unbox<Box<string>> = "hello"; // U inferred as string
```

`infer` is only valid inside the `extends` clause of a conditional type. It uses structural unification (`unifyType`) to extract the binding — works with Array, generic instances, Ref/Ptr wrappers, and struct types.

### Discriminated Union Narrowing

Type narrowing in `if` and `match` blocks based on discriminant field checks (Tier 2).

#### String-literal discriminated unions

```ms
type Shape =
    | { kind: "circle", radius: number }
    | { kind: "square", side: number };

function area(s: Shape): number {
    // if-narrowing: s.radius is valid here, s.side would error
    if (s.kind === "circle") {
        return s.radius * s.radius * 3;
    }
    return s.side * s.side;
}

// match-narrowing: each arm restricts to the matching variant
function describe(s: Shape): string {
    return match (s.kind) {
        "circle" => "r=" + s.radius.toString(),    // s narrowed to circle variant
        "square" => "s=" + s.side.toString(),       // s narrowed to square variant
    };
}

// Exhaustiveness: missing variant arms are reported
// match (s.kind) { "circle" => 0 }
// error: Non-exhaustive match: missing variant 'square'

// Call-site validation: wrong fields for a variant are caught
// area({ kind: "circle", side: 5 });
// error: Field 'side' does not exist on the kind-matched variant
```

#### Enum-based discriminated unions

```ms
enum K { A, B }
type V = match (kind: K) {
    K.A => { x: number },
    K.B => { y: string },
};

function f(v: V): number {
    if (v.kind === K.A) {
        return v.x;      // OK — variant A has x
        // v.y would error: Property 'y' does not exist on type 'V.A'
    }
    return 0;
}
```

#### `typeof` narrowing

`typeof x === "tag"` (and `!==`) narrows a union by the tag the value carries at runtime, on both
backends. The tags are the ones JavaScript reports: `"number"` covers every numeric kind,
`"string"` the string kinds, `"boolean"`, `"function"` (closures and function values),
`"bigint"`, and `"object"` for everything else (refs, structs, arrays, `null`). The negated
branch keeps the complement.

```ms
function apply(v: int32 | ((prev: int32) => int32), cur: int32): int32 {
    if (typeof v === "function") { return v(cur); }   // v: (prev: int32) => int32
    return v;                                          // v: int32
}

function size(v: int32[] | int32): int32 {
    if (typeof v === "object") { return v.length; }   // v: int32[]
    return v;
}
```

The compared tag must be a string literal; a variable holding `"function"` does not narrow.
Two members that share a tag (a union of two function types) are not split by `typeof` — the
union stays whole and a call on it is rejected. Inside the branch the narrowed value is used
directly as an operand, callee, condition or receiver; no `as` is needed (an explicit
`v as int32` remains a no-op there).

### Struct Field Type Checking

Object literal construction validates field types against the expected struct type (Gap 1).

```ms
type Config = { port: number, host: string };
const c: Config = { port: 8080, host: "localhost" };    // OK

// const bad: Config = { port: "wrong", host: 42 };
// error: Type 'string' is not assignable to type 'number' for field 'port'
// error: Type 'int32' is not assignable to type 'string' for field 'host'

// Also works with generic aliases:
type Box<T> = { value: T };
// const b: Box<number> = { value: "wrong" };
// error: Type 'string' is not assignable to type 'number' for field 'value'
```

### Utility Types
```ms
Partial<T>           // All properties optional (planned)
Required<T>          // All properties required (planned)
Readonly<T>          // Read-only view of T (shipped) — deep, never converts back to T; `readonly T[]` for arrays.
                     // Not the `readonly` parameter modifier above (that one is an explicit copy). See Spawn.
Record<K, V>         // Object type with keys K and values V (planned)
Pick<T, K>           // Subset of properties (planned)
Omit<T, K>           // Exclude properties (planned)
```

### Mapped Types
```ms
// Planned — not yet implemented
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
msPromiseSettle(p, null);

// Or reject it
msPromiseRejectFuture(p, "error");
```

Useful when resolve/reject need to be called from a different scope than where the promise was created — e.g., event handlers, timers, or cross-module coordination.

#### Spawn — Thread Pool Parallelism

`spawn` offloads work to a thread pool (Malebolgia-style: fixed workers, backpressure, help-first scheduling):

```ms
const handle = spawn(() => heavyComputation());  // returns Promise<T>
const result = await handle;                      // block until complete
```

`spawn` returns a `Promise<T>` tagged as **affine + scope-bound** under the hood — it must be awaited exactly once before its scope exits. Surface type is `Promise<T>`; the affine semantics are attached via internal flags so the compiler can enforce safety without forcing users to learn a second type name:

```ms
const h = spawn(() => 42);
// COMPILE ERROR if h is never awaited (PARALOCK R1/E2)
// COMPILE ERROR if h is awaited twice (PARALOCK R2/E3)
// COMPILE ERROR if h is returned from a function (PARALOCK R3/E4)
```

The same `Promise<T>` produced by `async function`s, actor CALLs, and `spawn(...)` all interoperate: you can mix them in arrays, pass them through generic code, etc. When a spawn-origin `Promise<T>` flows into a context that drops the affine guarantee (mixed array, generic parameter, explicit upcast), the compiler emits a lint so the safety loss is visible.

**Spawn groups** — parallel fan-out with structured results:

```ms
// Parallel execution — Promise.all with spawn handles
const results = await Promise.all([
    spawn(() => workA()),
    spawn(() => workB()),
    spawn(() => workC()),
]);
// results: [resultA, resultB, resultC]
```

When all elements are spawn calls, `Promise.all` is automatically optimized to use AwaitGroup (condvar + zero-alloc) instead of the generic callback path.

**Memory ownership** — three verbs, one keyword:

```ms
const c: Counter = { n: 0 };
const cfg: Config = { size: 8 };

spawn(() => c.n + cfg.size);                             // BORROW: captures are read at Readonly<T>
spawn(() => { c.n = 1; return c.n; }, { move: [c] });    // MOVE:   c is the thunk's now; the parent cannot use c again
spawn(() => lockedUpdate(gate, (v: int32): int32 => v + 1)); // SHARE:  writes go through a Locked<T> critical section
```

- A captured binding is a **read-only view** inside the thunk: assignment, `++`, `out` arguments, `move`, the mutating array builtins (`push`, `splice`, …) and an `as` cast back to the mutable type are compile errors (`cannot write through Readonly<Counter> — … (PARALOCK E24)`). The view is deep and follows the value through aliases, `for..of`, destructuring, and struct copies that carry a ref; a POD struct copy is a plain value again.
- A callee that only reads says so in its signature: `function readOnly(c: Readonly<Counter>)`. A class method says it with a TypeScript `this` parameter — `peek(this: Readonly<Counter>): int32 { return this.n; }` — and only such methods are callable through a view (`v.bump()` on a view: `a method callable through the view declares its receiver … (PARALOCK E24)`); inside, `this` is the view, so a write is E24. An extension spells the same receiver `function peek(this c: Readonly<Counter>): int32`. The `this` parameter must come first, name the enclosing class (`C` or `Readonly<C>`), and is refused on static methods, constructors, free functions and lambdas.
- `{ move: [x, y] }` hands the listed bindings to the thunk on the parent thread at the spawn site. Inside the thunk they are owned and writable; a later use in the parent is an error (`'c' was moved into a spawn thunk and cannot be used afterwards`), rebinding a `let` revives it. Entries must be plain local names. `{ timeout: ms }` is the other option; any other key is an error.
- `move x` *inside* the thunk is refused (`cannot move out of Readonly<…>`): it would reset the parent's slot from the child thread.
- A moved binding must be its **sole owner** (PARALOCK E148): a local of the enclosing function, built from a fresh value (a literal, an object/array literal, `new`, a call, `move`) and re-assigned only from fresh values, and never copied anywhere the parent can still reach before the spawn — another name, a field, a literal, a call argument, a closure, a `defer`. A parameter, a `for..of` element, or a module-level binding cannot be moved. The error names the site: `cannot move 'c': it is not the sole owner — it is bound to 'a' at 4:2; only a binding nothing else can reach may cross into the thunk (PARALOCK E148)`. Calling a method on the binding before the move is fine (`buf.push(i)`), as long as what goes in is fresh too.

**Lint E40**: `await spawn(...)` inside a loop body is a warning — spawns execute sequentially. Collect handles first, then await outside the loop.

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
| `Promise.all` | Yes | Yes | Typed collection; corpus-gated c/orc/danger/js parity (2026-08-28) |
| `Promise.race` | Yes | Partial on C | Scalar `T` verified; `T = string` silently wrong (probed 2026-08-28) |
| `Promise.allSettled` | Yes (ES2020) | **Broken on C** | Typed use crashes (NULL result array, probed 2026-08-28); decl is `Promise<T[]>`, not the JS outcome-object shape |
| `Promise.any` | Yes (ES2021) | Partial on C | Scalar `T` verified; `T = string` silently wrong (probed 2026-08-28) |
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

### Actors

Actors are long-lived stateful objects that communicate via message passing. Each actor has its own mailbox and processes one message at a time — no internal locking needed.

#### Declaration

```typescript
actor Counter {
    private count: number = 0;

    // void return = SEND (fire-and-forget, enqueue and return immediately)
    increment(): void {
        this.count += 1;
    }

    // non-void return = CALL (request/reply, returns Promise<T>)
    get(): number {
        return this.count;
    }
}

const counter = new Counter();
counter.increment();                  // send: returns immediately
counter.increment();
const value = await counter.get();    // call: returns Promise<number>
```

#### Actor Isolation

An actor's mutable state is only accessible from within the actor itself. External access goes through the mailbox:

```typescript
const counter = new Counter();
counter.count;                 // COMPILE ERROR: actor-isolated property
await counter.get();           // OK: goes through mailbox
```

A field marked `@nonisolated` is readable from outside without await. The
decorator is an ordinary symbol exported by `std/actor`, not a word the checker
knows by spelling, so it has to be imported — and it may be renamed on import
like any other name:

```typescript
import { nonisolated } from "std/actor";

actor Server {
    @nonisolated
    public readonly name: string = "api-1";
    private connections: number = 0;

    getConnections(): number { return this.connections; }
}

const s = new Server();
s.name;                           // OK: nonisolated, readonly
await s.getConnections();         // OK: through mailbox
```

Without the import the name resolves to nothing and the field stays isolated:
`Cannot find name 'nonisolated'`, followed by `cannot access actor field 'name'
directly — use actor methods` at the read.

Every actor has a `pid` field (int64) — its unique runtime identity, always nonisolated.

#### The 3 Transfer Rules

Data crossing actor boundaries follows three rules:

```
actor.method(data)
       |
       +-- Is `move` keyword present?
       |     YES --> MOVE: transfer pointer, invalidate source (zero-copy)
       |     NO  |
       |         v
       +-- Is data provably immutable?
       |   (value type, or Ref<T> with all fields readonly)
       |     YES --> SHARE: pass pointer, incref (zero-copy)
       |     NO  |
       |         v
       +-- COPY: value types copied automatically
       |   Ref<T> with mutable fields: must use `move`
```

```typescript
// Value types — always safe (COPY):
counter.add(42);                    // number copied into message

// Immutable Ref<T> — safe to share (SHARE):
interface FrozenConfig { readonly host: string; readonly port: number; }
const cfg: FrozenConfig = { host: "0.0.0.0", port: 443 };
server.configure(cfg);              // shared pointer, zero-copy

// Mutable Ref<T> — must transfer ownership (MOVE):
let state: MutableState = { count: 0 };
worker.process(move state);         // zero-copy, state invalidated
// state.count;                     // COMPILE ERROR: used after move
```

#### Spawn Inside Actors

Actors can spawn parallel work internally. Safety rules prevent data races:

```ms
actor Worker {
    private data: number[] = [];

    compute(): number {
        // OK: read-only field borrow in spawn thunk
        const h = spawn(() => {
            let sum = 0;
            for (const v of this.data) sum = sum + v;
            return sum;
        });
        return await h;
    }
}
```

The compiler enforces two safety rules (PARALOCK S1/S3):

```ms
actor Unsafe {
    private state: number = 0;

    bad(): void {
        spawn(() => {
            this.state = 42;     // COMPILE ERROR (S3): cannot mutate actor field in spawn
        });
        spawn(() => {
            const ref = this;    // COMPILE ERROR (S1): cannot capture bare 'this'
        });
    }
}
```

Actors also support cooperative suspension — async actor methods (`CALL` pattern) suspend the actor while awaiting an internal future, freeing the scheduler to process other actors' mailboxes.

#### Supervision (Erlang OTP)

Supervisors monitor child actors and restart them on failure:

```typescript
import { Supervisor, RestartStrategy, RestartType, ShutdownKind } from "std/actor/supervisor";

const sup = new Supervisor(RestartStrategy.OneForOne, 3, 5);

sup.addChild({
    name: "database",
    start: () => new DatabaseActor(connectionString),
    restart: RestartType.Permanent,
    shutdown: ShutdownKind.Timeout,
    shutdownMs: 5000,
});

sup.start();
```

Three restart strategies: `OneForOne` (only crashed child), `OneForAll` (all restart), `RestForOne` (crashed + later children).

Per-child shutdown protocol: `BrutalKill` (immediate), `Timeout` (graceful then force), `Infinity` (wait forever).

Dynamic child management at runtime: `startChild`, `terminateChild`, `deleteChild`, `restartChild`, `countChildren`.

`DynSupervisor` is the pool variant (all children use the same spec, dynamic add/remove).

#### Links and Monitors

```typescript
import { link, unlink, monitor, demonitor } from "std/actor";

// Link: bidirectional — if either dies, both die
link(actorA.pid, actorB.pid);

// Monitor: unidirectional — watcher receives DOWN message when target dies
const ref = monitor(watcher.pid, target.pid);
```

Actors can trap exit signals by defining an `onExit` handler:

```typescript
actor Watcher {
    onExit(childPid: int64, reason: ExitReason): void {
        console.log(`child ${childPid} died: ${reason}`);
    }
}
```

#### Lifecycle Hooks

```typescript
actor MyActor {
    onTerminate(reason: ExitReason): void { }    // called before destruction
    onExit(pid: int64, reason: ExitReason): void { }  // linked actor died
    onDown(ref: number, pid: int64, reason: ExitReason): void { }  // monitored actor died
    onIdle(): void { }                            // no messages for N ms
}
```

Enable idle timeout: `setIdleTimeout(this.pid, 5000)` — fires `onIdle` after 5 seconds of inactivity.

#### Name Registry

```typescript
import { registerName, whereis, unregister } from "std/actor";

registerName(actor.pid, "database");    // returns true on success
const pid = whereis("database");        // returns pid or 0
unregister("database");                 // auto-unregisters on actor death
```

#### Constructor

Actor constructors run after the actor's pid is wired, so `this.pid` is available:

```typescript
actor Worker {
    constructor(name: string) {
        registerName(this.pid, name);   // OK: pid is valid here
    }
}
```

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
| `@compilerFunc` | extern function | The compiler may synthesize calls to this routine; its declaration is where they read their signature | DONE (2026-09-18) |
| `@throws` | extern function | The routine raises by setting the runtime error flag instead of returning | DONE (2026-09-18) |
| `@beforeReload` / `@afterReload` | module-level `(): void` function | Hot-reload lifecycle handler, run by `std/hcr` around a reload under `--hcr` (docs/HCR.md "Host runtime (S4)") | DONE on Windows x64 (2026-09-23) |
| `@comptime` | block | Compile-time evaluation | PLANNED |
| `@emit("...")` | statement | Inline raw C/JS code into output | PLANNED |
| `@inline` | function | Hint to inline function body at call site | PLANNED |

##### Which of the three a declaration wants

The three marks above answer three different questions about one call. A routine
can need any combination; they do not substitute for one another.

| Question about the call | Mark | Consequence |
|---|---|---|
| Does the call **disappear**, replaced by emitted code? | `@builtin("Name")` | `builtinLower` rewrites the AST by tag; no function call survives |
| Is the call **synthesized** by a lowering rather than written by hand? | `@compilerFunc` | the name a lowering emits resolves to this symbol, so later phases read a declared signature instead of guessing from the name |
| Can the routine **raise**? | `@throws` | DRC keeps the scope's cleanup on the error path (`callCanThrow`, `analyzer/inject.ms`) |

`msAssertFail` carries both `@compilerFunc` (the `assert` lowering emits the call)
and `@throws` (it sets the error flag). `nonisolated` carries neither — it is
`@builtin`-tagged because that is currently the only way to declare a decorator
that has a symbol; see the note below.

```typescript
// std/core/system/index.ms
@compilerFunc @throws
extern function msAssertFail(msg: cstring, file: cstring, line: int32): void from "msAssertFail";
```

A `@compilerFunc` declaration lives in the prelude so every module a synthesized
call lands in can reach it, and it needs no `export` — the table travels with the
prelude scope, not through the export registry. The C name still comes from the
`from "..."` clause, not from the mark.

**Two known rough edges, so nobody copies them as patterns.** `@builtin` currently
carries one declaration that is not an intrinsic at all (`nonisolated`, an actor
field property), because declaring a decorator with a symbol has no mark of its
own. And the `@include`/`@passC` family of directives is matched as plain strings
in the checker, so unlike `@builtin`/`@compilerFunc`/`@throws` they have no
declaration to jump to.

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

## Conditional Compilation

`when` selects code at compile time from build flags. The first true branch is
spliced into the enclosing statement list; every other branch is dropped at parse
and **never type-checked**, so a dropped branch may name symbols that do not exist
on the current target.

```typescript
when (js) {
    function now(): number { return Date.now(); }
} else when (c && !debug) {
    function now(): number { return msClockMonotonic(); }
} else {
    function now(): number { return 0; }
}
```

`when` splices — it does not open a scope, so declarations inside a taken branch
belong to the enclosing module or function. It is available wherever a statement
list is (module level, function body, macro body), and it gates directives as well
as code:

```typescript
when (macos) {
    @passL("-framework Metal");
    @compile("./bridgeEmbed.m");
}
```

### Condition grammar

A closed grammar — flag names, literals, `!`, `&&`, `||`, comparisons
(`==` `===` `!=` `!==` `<` `<=` `>` `>=`) and parentheses. Function calls and
arbitrary expressions are rejected: conditions are resolved before any symbol
table exists, so an identifier there is always a flag name, never a variable.
Comparison is numeric when both sides are numeric, string otherwise.

### Flags

| Source | Example |
|--------|---------|
| Backend | `c`, `js`, `raiser`, plus `backend=c` |
| Target OS | `macos`, `ios`, `android`, `linux`, `windows`, plus `os=macos` |
| OS family (computed) | `posix`, `unix`, `bsd` |
| Memory mode | `drc`, `orc`, `none`, `manual`, plus `gc=orc` |
| Build mode | `debug`, `release`, `danger`, plus `mode=release` |
| Command line | `-d:myFlag`, `-d:tier=3`, `--define:name=value` |

A flag with no value is `"true"`. A name that is not defined is **false, never an
error** — the namespace is open, so a typo cannot be distinguished from a flag the
user has not set. `msc --help-defines` lists everything currently defined.

`-d:my-flag` is normalized to `my_flag`, since `my-flag` lexes as a subtraction.

> `@target(...)` and `@platform(...)` were retired 2026-08-09 in favour of `when`.
> `@target` never gated anything (the name was accepted, the filter was never
> written); `@platform` gated directives only. Both now raise an error pointing here.

## Strings and Characters

MetaScript provides a high-performance string system that is a systems-programming superset of TypeScript. It adds support for in-place mutation, primitive characters, zero-copy views, and binary-compatible byte array bridging.

### 0. The Index-Space Contract (normative)

Strings are **UTF-8 byte buffers on both backends** (C: `msString`; JS: byte array, the standard reference's JS model) with a cached is-ASCII flag. Over that single representation the API exposes exactly **two index spaces, separated by name** — an offset produced in one space must never be consumed by the other:

| Tier | Names | Index space | Semantics |
|------|-------|-------------|-----------|
| **TS tier** (default) | `length`, `s[i]`, `charAt`, `charCodeAt`, `indexOf`, `lastIndexOf`, `slice`, `substring`, `split`, `replace`, `replaceAll`, `padStart`, `padEnd`, `startsWith`, `endsWith`, `repeat`, … | UTF-16 code units | **TypeScript-exact.** What a TS developer reads is what they get. |
| **Byte tier** (explicit) | `byteLength`, `byteAt`, `byteSlice`, `byteIndexOf`, `asBytes`, `asString` | Raw UTF-8 bytes | The standard reference's string surface. Lexers, parsers, and binary protocols live here. |

- **`s[i]` behaves like TypeScript**: it is equivalent to `charAt(i)` and yields the i-th UTF-16 code unit as a `string`. Sole documented deviation: out-of-range yields `""`, not `undefined`.
- **ASCII fast path**: when the is-ASCII flag holds, byte index == code-unit index and both tiers run at byte speed. Non-ASCII TS-tier calls pay a UTF-8 decode walk.
- **Bridge**: `asBytes()` is a zero-copy borrow of the buffer (C: Cursor bit-cast; JS: identity). `asString()` is a copying kernel returning a fresh owned string.
- Index **assignment** (`s[i] = c`) is byte-space legacy and slated to move to an explicit byte-tier form; treat it as byte-tier today.

### 1. The `char` Primitive
MetaScript introduces `char` as a first-class primitive for **byte-tier** work: an unsigned 8-bit value (0–255).

- **Access**: `byteAt(i)` reads raw bytes; `s[i]` is TS-tier and returns a `string` (see §0).
- **Literals**: Character literals use single quotes (e.g., `'a'`).
- **Numeric**: `char` is a numeric type and can participate in arithmetic or be cast to `number`.
- **Codepoints use `int32`, not `char` or `uint32`**: `char` is 8-bit (only U+0000–U+00FF). A full Unicode codepoint is 21-bit, so hold it in `int32` — the type `.code`, `s.charCodeAt(i)`, and `fromCodePoint()` all speak, matching Go's `rune`. Prefer `int32` over `uint32` here: signed stays cast-free with those APIs and leaves `-1` free as an "invalid/absent" sentinel, whereas `uint32` buys only a compile-time non-negativity guarantee at the cost of an `as uint32` cast at every codepoint boundary.

```typescript
const c: char = 'A';
const s = "héllo";
const first = s[0];        // "h" — string, TS semantics
const b: int32 = s.byteAt(1); // 0xC3 — first byte of é, byte tier
```

### 2. Mutable Strings
Strings in MetaScript are mutable when declared with `let`. All standard TypeScript string methods (`slice`, `replace`, etc.) remain available and return new strings.

- **`.length`**: Returns the number of characters (UTF-16 code units), matching TypeScript behavior.
- **`.byteLength`**: Returns the raw number of bytes in the UTF-8 buffer (Systems-optimized).
  On a `Buffer` use the call form `buf.byteLength()`: `Buffer` is `string` on the C target but
  `uint8[]` on the JS target, and the call form is the surface both share.
- **`.unicodeLength`**: Returns the number of actual Unicode code points.

```typescript
let buf = "🚀";
console.log(buf.length);        // 2 (TS compatibility)
console.log(buf.byteLength);    // 4 (UTF-8 bytes)
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

#### Linked structures: arena ownership + `Ptr<T>` links

An **owning** self-referential field makes the generated destroy hook recurse per
node — stack depth equals chain length, so a long list overflows the stack at
scope exit. The compiler warns on this shape:

```
warning: owning self-referential field 'next' in 'Tok': destroy recurses per node —
a long chain overflows the stack; for non-owning links use Ptr<Tok> with an
arena/array owner
```

The sanctioned pattern: an arena (plain array) owns every node; the links are
non-owning `Ptr<T>`. Dropping the structure is then a flat array destroy:

```typescript
interface Tok {
    value: string;
    next: Ptr<Tok>;               // non-owning link — destroy hook skips it
}

const arena: Tok[] = [];          // the arena owns every node
arena.push({ value: "a", next: null as unknown as Ptr<Tok> });
arena.push({ value: "b", next: null as unknown as Ptr<Tok> });
arena[0].next = arena[1];         // Ref ↔ Ptr assign both ways, no cast needed
let cur: Ptr<Tok> = arena[0];
while (cur !== null) { use(cur.value); cur = cur.next; }   // transparent access
```

Trees built through arrays (`children: Node[]`) are depth-bounded and are NOT
flagged — only direct self-ref links recurse by chain length.

DRC rule at the boundary: when a `Ptr<T>` whose pointee is a counted object flows
into an **owning** position (a `T[]` element, a `T`-typed return, a `T` field in a
literal), the compiler materializes ownership with an incref — and a `Ptr`
variable is never *moved* into such a slot (it holds a borrow; there is no
ownership to transfer). `Ptr<void>` / `Ptr` to plain structs (malloc/FFI memory,
no rc header) are never touched by this rule.

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

- **Fusion**: Multiple `+` operations are fused into a single array-based call (`msStringConcatArr`).
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

#### Explicit `.toItems()` — Iterator Protocol for `for...of`

Any type with a `toItems()` method becomes iterable with `for...of`. The compiler resolves `toItems()` during type checking, not at runtime.

```ms
const names: Set<string> = new Set(["alice", "bob"]);
for (const name of names) {
    console.log(name);   // "alice", "bob"
}

const ages: Map<string, int32> = new Map();
ages.set("alice", 30);
for (const key of ages) {
    console.log(key);    // "alice"
}
```

The compiler rewrites `for (const x of set)` → `for (const x of set.toItems())` during checking. Generic instantiation happens naturally — no special runtime support.

**Built-in `toItems()`**: `Set<T>` returns `T[]`, `Map<K, V>` returns `K[]` (keys by default, use `.values()` for values).

**Custom iterables**: define a `toItems` extension method on any type:

```ms
function toItems(this self: TokenStream): Token[] {
    // return array of tokens
}

// Now works:
for (const tok of stream) { ... }
```

#### Convention-based dispatch protocols (overview)

The `toItems` mechanism is one of a family of **convention-based dispatch protocols**: extension methods with reserved names that the compiler synthesizes calls to at well-defined syntax sites. Type opts in by declaring the extension; non-opt-in types remain strict.

| Protocol | Synthesizes | Triggered when |
|---|---|---|
| `toItems(this T): U[]` | `for (x of obj)` → `for (x of obj.toItems())` | non-array obj in `for..of` |
| `toString(this T): string` | implicit string context | type concat with string |
| `getDynamicField(this T, key: string): U` | `obj.foo` → `obj.getDynamicField("foo")` | `foo` not a real field of T |
| `setDynamicField(this T, key: string, value: U): void` | `obj.foo = v` → `obj.setDynamicField("foo", v)` | `foo` not a real field of T, written |
| `converter f(v: T): U` (a routine, not a method — [Converter Declarations](#converter-declarations)) | `expr` → `f(expr)` | T meets a slot, argument, `as U` or operand of type U |
| `valueOf(this T): U` | `expr` → `expr.valueOf()` | a read of T fails: value slot, operand, condition, missing member, index, `switch`, `as` |

**Order**: a position that needs one form tries the protocol for that form before `valueOf` — a converter
to `U` for a slot of type `U`, for `as U` and for an operand beside a `U`, `toItems` for `for..of` — and
reads through `valueOf` only when the type has none for it, or has one for another target (corpus
`782-protocolSiteBeforeValueOf`: a `Box` with a converter to `string` meeting an `int32` slot reads
`valueOf`, `fallback 100`). `+` with a string reads `valueOf` first, as JavaScript does (`concat v=100`). The choice is made while
checking, by the static type; the chosen call runs at run time.

**Mechanism**: in checker, after normal resolution fails, synthesize a `MemberExpr + CallExpr` matching the convention name, type-check it, rewrite the AST in-place if it succeeds. If the extension doesn't exist on `T`, fall through to the existing error path. **Zero overhead for non-opt-in types** — one O(1) extension registry lookup → fast skip.

##### `valueOf` — opt-in value read

A type that declares `valueOf` is read through it wherever the bare read would be an error:

```ms
type Accessor<T> = distinct (() => T);
export function valueOf<T>(this a: Accessor<T>): T { return a(); }

const [count, setCount] = createSignal(0);
setCount(count + 1);               // count.valueOf() + 1
if (count > 3) { ... }             // count.valueOf() > 3
const n: number = count;           // count.valueOf()
const f: () => number = count;     // the accessor itself: the slot takes it
const alias = count;               // the accessor itself: nothing failed
```

It fires only where the bare read is already an error, at that error: a typed slot (declaration,
assignment, return, non-overloaded or extension-method argument, `as U`; after a converter); an operand that the operator
check refuses (arithmetic, `===`/`!==`, relational, compound assignment) or a string concatenation, beside
`toString`; a function tested for truthiness (`if`/`while`/`for`/ternary, `!`, the left of `&&`/`||`);
unary `-`; an index or an indexed function; a spread; a `switch` whose case cannot equal it; `for..of`
(after `toItems`); a receiver that lacks the member (before `toString`). Each of those positions is an
error for a function value on its own — "a function is always truthy", "unary '-' needs a numeric
operand", "an array index must be a number" — so a type without `valueOf` gets that error. It never fires
at a callee, an assignment or `++` target, a formal that still has generic parameters, a slot that
already takes `T`, a position that accepts every type (JSX children and attributes, `console.log`,
`String(x)`, `typeof`), or inside overload resolution: like a converter, an overloaded call needs a candidate
that takes `T` itself, otherwise write `x()`.
One step only: the result of a `valueOf` is not read again. The receiver matches by type name, so another
distinct of the same shape does not borrow it, and the extension must be visible like any other (imported
from its module, or re-exported through a hub).

Consequences: `const c2 = count`, `id(count)`, `[count]`, `nn ?? count` and `() => count` in a
`() => Accessor<T>` slot keep the accessor; `console.log(count)` and `String(count)` print the handle
(write `${count}` or `count.toString()`); `typeof count` inspects the handle.

##### `getDynamicField` — opt-in dynamic member access

```ms
interface JsonValue { kind: JsonKind; ... }

export function getDynamicField(this v: JsonValue, key: string): JsonValue {
    if (v.kind === JsonKind.Object) { /* lookup */ }
    return jsonNull();
}

const j = parseJson("...");
const name = j.user.name;   // synthesized: j.getDynamicField("user").getDynamicField("name")
```

Self-referential return enables infinite chaining. Non-opt-in types (e.g. `User` interface with declared fields only) remain strict like TypeScript — `u.weirdField` errors at compile.

**Read-only**: synthesis fires only on the read path. `obj.foo = x` does NOT route through `getDynamicField` — the compiler's `leftPartOfAsgn` guard ensures writes still error strictly.

##### Runtime converters

The implicit conversion of a value into another type at a slot, an argument, `as U` or an operand is a
`converter`, declared beside the type — rules and measurements in
[Converter Declarations](#converter-declarations).
The old `as<TargetType>` protocol (a method named `as` + target name) is gone; such methods are ordinary
methods now.

A condition is not a converter site: corpus `785-runtimeConverterOperand` declares
`converter boxToFlag(b: Box): boolean { return false; }` and `box ? "yes" : "no"` still prints `yes`.

##### Cross-protocol composition

`getDynamicField` and a converter can co-exist on the same type. Dynamic access result then flows into the converter:

```ms
interface Doc { tag: string; }

export function getDynamicField(this d: Doc, key: string): Doc { return { tag: d.tag + "." + key }; }
export converter docToText(d: Doc): string { return "[" + d.tag + "]"; }

const root: Doc = { tag: "root" };
const s: string = root.user.name;
// → root.getDynamicField("user").getDynamicField("name") → Doc { tag: "root.user.name" }
// → docToText(that Doc) → "[root.user.name]"
```

This is how `JsonValue` works: `getDynamicField` for members and the converters in `std/serialize/json/types.ms` for slots and operands (corpus `786-jsonConverter`).

##### Cross-module generic protocols (mixin)

A generic function can call convention extensions on its open type parameter `T` — including extensions defined in the **calling** module, not just the generic's own module (the extension is resolved at the instantiation site, so the calling module counts). This is how a library ships a generic walker and each consumer opts its own node type in:

```ms
// lib.ms — the walker never names concrete types
export function walkTree<T>(n: T, depth: float32): void {
    n.protoBump(depth);
    for (const c of n.protoKids()) {
        walkTree(c, depth + 1.0);
    }
}

// main.ms — opt-in via exported extensions
import { walkTree } from "./lib";
interface Panel { name: string; children: Panel[]; depth: float32; }

export function protoKids(this p: Panel): Panel[] { return p.children; }
export function protoBump(this p: Panel, v: float32): void { p.depth = v; }

walkTree(panel, 1.0);   // monomorphized: direct static calls, zero dispatch cost
```

Rules:

- **Extensions must be `export`ed.** The monomorphized instance is emitted in the defining module's TU and calls the extensions cross-TU. A private extension is not visible to the instantiation and produces a check-time error with an `in instantiation of '...'` note at the call site.
- **Conflict is an error.** If the defining module and the calling module both provide an extension with the same name and receiver, instantiation fails with "Ambiguous call to overloaded extension method" — there is no silent preference.
- **Keep extensions next to the type or next to the walker** (orphan-rule-lite). Defining protocol extensions in an unrelated third module makes instantiation depend on which caller ran first.

##### Limitations (V1)

- **Bracket access** (`obj["foo"]`) NOT in protocol scope — only `MemberExpr` (dot access) triggers synthesis.
- **Optional chain** (`obj?.foo`) skips synthesis to preserve null-safety semantics — use direct calls or non-optional access.
- **Generic class** with extension method: blocked by pre-existing class-constructor monomorphization gap. Use generic `interface` instead, which works end-to-end.
- **No infinite chain**: single-step coercion only; explicit chains require explicit calls.

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
The standard general-purpose array. It is a **reference type** — heap-allocated, DRC-managed, and shared on assignment exactly like a TypeScript array.

- **Allocation**: Heap (Reference Counted).
- **Size**: Growable.
- **Behavior**: Reference semantics — `const b = a` makes `b` an alias of `a`; a mutation through any alias is visible to all. Passed to functions by reference (no copy).
- **Value counterpart**: use `Vec<T>` when you need copy-on-assignment value semantics.
- **Usage**:
  ```typescript
  const items: number[] = [1, 2, 3];
  items.push(4);        // Growable
  const alias = items;  // shares the same underlying array
  alias.push(5);        // items is now [1, 2, 3, 4, 5]
  ```
- **Elements are invariant** (differs from TypeScript, which lets `Dog[]` stand in for `Animal[]`). An array is shared by pointer, so a view with a wider element type would let `push(new Animal())` land in a `Dog[]` and the next `dogs[i].breed` read past the object (measured as an ASan heap-buffer-overflow, 2026-09-10). Every route is closed: argument, `Span<T>`, `T[N]`, declaration, field, return, and a generic `T[]` whose `T` another argument would widen.
  ```typescript
  class Animal { name = ""; }
  class Dog extends Animal { breed = ""; }
  function add(xs: Animal[]) { xs.push(new Animal()); }
  const dogs: Dog[] = [new Dog()];
  add(dogs);                      // error: Argument type mismatch in 'add' arg 0: got Dog[], expected Animal[]
  const view: Animal[] = dogs;    // error: Type 'Dog[]' is not assignable to type 'Animal[]' — memory layout differs (… array element …)
  add(dogs as Animal[]);          // explicit view: you take the write hazard
  const one: Animal = dogs[0];    // element subtyping itself is unchanged
  const empty: Dog[] = [];        // empty literal, literals, and generic-open elements keep adapting
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

### 4. Value Arrays (`Vec<T>`)
The value-semantics counterpart to `T[]`. Same growable storage and methods, but **copied on assignment** — like a `struct` (or reference `seq`). Assigning or passing a `Vec<T>` produces an independent array; mutations do not propagate back to the source.

- **Allocation**: Heap buffer, value handle (copied on assignment).
- **Size**: Growable.
- **Behavior**: Value semantics — `const b = a` copies; `a.push(x)` does NOT affect `b`.
- **Use it when**: you need a private, non-aliased array, or to recover the (small) reference-deref cost in a *measured* hot loop. `T[]` is the right default — reach for `Vec<T>` deliberately, not by habit.
- **Usage**:
  ```typescript
  const a: Vec<number> = [1, 2, 3];
  const b = a;     // independent copy
  a.push(4);       // b is still [1, 2, 3]
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
`Span<T>` follows "Borrow" rules — two checker-enforced, one by contract:
1. **Storage is allowed — the writer owns the borrow contract** (probed 2026-08-28: struct, class and interface fields plus globals all accept `Span` declarations; `BsatnReader.bytes: Span<uint8>` is the load-bearing in-tree example). The checker does NOT track this lifetime: a stored Span must not outlive the buffer it views, or C reads freed memory while JS keeps "working". This is the expert tier — SDK cursors/parsers. App code that wants to KEEP data stores `T[]` (alias + refcount keeps the buffer alive, still zero-copy) or `Vec<T>` (owns a copy). The implicit owning-container → `Span` coercion fires at every init/assign position — declaration, assignment, call argument, and object-literal field (the last closed 2026-08-28, `wrapSpanObjectFields` in spanLower).
2. **No Return**: A `Span<T>` cannot be returned from a function at all (checker-enforced since 2026-08-28: `cannot return Span<T>: a Span borrows memory owned by its source; return the owning container (Vec<T> or T[]) instead`) — regardless of where the Span was created.
3. **Parameter Primary**: The primary use case for `Span<T>` is as a function parameter — structurally safe (the callee's frame always dies before the caller's owner), zero-copy from every source (`T[]`, `Vec<T>`, `T[N]`, literals, slices).

Safety tier and intent: today `Span` sits exactly where Zig slices sit — safe as a parameter by construction, unchecked as storage. The planned upgrade is escape-analysis lite in the checker (view-style inference over a few countable escape shapes), NOT a borrow checker: no lifetime annotations will ever enter the syntax (TS surface).

#### Value Bindings Are Read-Only Views (Checker-Enforced)

Value-typed bindings that look like copies are passed by pointer for speed; the checker preserves copy semantics by rejecting writes through them (landed 2026-08-23..28):
- **Value params** (`function f(v: Vec<T>)`): interior writes (`v[0] = …`, `v.x = …`) AND builtin mutators (`v.push/pop/shift/unshift/splice/sort/reverse/fill/…`) are compile errors. `T[]` params stay fully writable — aliasing is their contract, and the caller sees it.
- **for-of bindings** over value elements: same rule (the binding is a per-iteration copy); rebinding the loop variable stays legal; `T[]` elements stay writable.
- To mutate the CALLER's data, say so in the signature: `ref`/`out` params (write-back works on both backends since 2026-08-28). For a scratch copy, copy explicitly: `let local = v;`.
- **Known gap (planned)**: user-defined struct methods that write `this` are not yet detected at call sites through value bindings (`c.bump()` slips where `c.n = 1` errors). The design follows the language's inference philosophy — NO new keywords: the checker will scan method bodies for `this` writes (the `mutatedParams` mechanism) and flag such calls. `ref`/`out` stays reserved for caller-visible write-back params, never a required annotation.

#### Summary Table

| Type | Allocation | Passed As (C) | Ownership | Use Case |
| :--- | :--- | :--- | :--- | :--- |
| `T[]` | Heap | Pointer (RC) | Owned (reference) | General app logic |
| `Vec<T>` | Heap | Struct (Copy) | Owned (value) | Private/non-aliased arrays |
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

Implemented via monomorphization — `JSON.parse<Person>` generates a specialized parse function at compile time using `T`'s field names and types. Same mechanism as `Array<T>` and `Result<T, E>`.

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
type UserId = distinct number;    // Nominal typing wrapper
type Email = distinct string;     // Cannot assign string to Email
```

#### Reading a distinct thunk

A `distinct` over a function type is callable (`count()`) and widens one way into that function type. It
is never read implicitly on its own: a type that wants bare reads declares the `valueOf` protocol (see
"Convention-based dispatch protocols").

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

### Sink Parameters (extern declarations only)
```typescript
extern function push<T>(this arr: T[], sink value: T): void from "&msGenericArrayPush";
```
`sink name: T` says the routine takes ownership of the argument: the caller passes it
consumed and does not destroy it afterwards. It is a contextual modifier like `out` /
`ref` — a parameter may still be *named* `sink` (`f(sink: int32)` compiles). Overload
scoring, literal fitting and generic binding look through it, so `a.push(0)` on a
`uint8[]` picks the same overload as without the modifier.

Measured 2026-09-18 (`src/test/handoff/sinkParam.ms`, 4/4): literal into a sink
overload compiles and calls `msUint8ArrayPush`; a generic `sink value: T` binds `T`;
`sink` as a parameter name compiles; and **a `sink` parameter on a function WITH a
body is a compile error** — `'sink' parameter on 'eat': only an extern declaration can
take ownership of an argument`. The callee-owns half (destroy at scope exit unless
moved on) is not implemented, so accepting it there would leak every argument.
NOT verified: `sink` on class methods and constructors, and the JS backend.

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
    assert sign === "neg", "negative value should give neg";
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

Run with `msc test file.ms`.

| Syntax | Behavior |
|--------|----------|
| `test "name" { ... }` | Register a test case |
| `assert expr;` | Assertion — power assert in tests, abort outside |
| `assert expr, "msg";` | Assertion with custom failure message |

Output: `PASS`/`FAIL` per test, summary line (`N passed, N failed, N skipped`), exit code 1 on any failure.

## Reserved Words

`type` is reserved in MetaScript. Use `tokenType`, `nodeType`, etc. for field names.
