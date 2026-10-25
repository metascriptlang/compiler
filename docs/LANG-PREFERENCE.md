# MetaScript Authoring Standard

This is the official, standalone authoring standard for this repository: how to choose data,
write APIs, organize modules, express failure, manage ownership and cross runtime boundaries.
It is both a style guide and an authoring handbook; ordinary work needs no second style guide.
[LANG.md](LANG.md) owns the detailed grammar and language contracts. This document owns preferred
choices, their reasons, runnable compositions and the limits attached to their checked baselines.
Project-specific build/release rules remain in the project's instructions, not in this standard.

Write TypeScript-shaped code with explicit widths, ownership and deliberate concurrency.
Choose the contract before the syntax: value or shared identity, borrowed access or an owner,
recoverable failure or caller misuse, suspension or CPU work. A familiar spelling is not proof
of identical storage, allocation or host behavior.

### Read the part the task needs

Read relevant sections when authoring or reviewing code, not this entire file at every session
start. The defaults and review checklist are the common entry points; the longer recipes are
here so a reader can finish the corresponding task without inventing an API.

| Task | Read |
|---|---|
| Ordinary module/API change | Defaults (§1), organization and formatting (§2), then the affected feature section |
| Data model, identifiers or numeric boundary | Widths/conversions (§3), storage (§5), cases/errors (§8) |
| Text, byte offsets or binary data | Text index spaces (§4), ownership (§6), untrusted format data (§14) |
| Buffer, view, move or resource owner | Ownership (§6), collection access (§7); native retention also needs §10 |
| Async, CPU job or stateful service | Concurrency (§9), including completion and shutdown, not just the submission syntax |
| Reusable generic or extension | Generics (§11), protocols and caller visibility (§12) |
| Macro, decorator or JSX DSL | Compile-time phases and complete recipes (§13) |
| Untrusted input or native/host integration | Validation (§14), ABI (§10), actual target (§16) |
| Review or performance work | The checklist and measurement discipline (§18); checked limitations and evidence (§19 and below) |

Defaults are preferred choices, not a reason to erase a different explicit requirement. Safety
obligations still apply when taking an exception: a raw pointer does not excuse a lifetime proof,
a numeric cast does not replace validation, and removing memory management does not remove cleanup.
A project can impose narrower conventions, but cannot redefine the language's ownership or ABI.

Examples are separate `.ms` modules unless related files are named together. Native-only contracts
are marked even when a JS facade produces similar text. Code examples illustrate use; their output
is not a substitute for assertions in application tests. A declared API or accepted syntax alone
certifies neither every input nor every target. §19 separates baseline observations from designs.
When an older observation differs from the current compiler, reproduce the consumer path before
changing a status claim; do not preserve a historical bug as a permanent authoring prohibition.

Quick navigation:

- Basics: [defaults](#1-defaults-that-make-code-read-as-metascript),
  [functions/files](#2-files-apis-and-formatting),
  [numbers](#3-numbers-domain-types-and-conversions), [text](#4-text-is-not-a-byte-offset).
- Storage: [values/classes](#5-values-for-data-references-for-sharing),
  [ownership/hooks](#6-own-once-view-while-processing-move-when-finished),
  [collections/generators](#7-collections-and-iteration).
- Control: [failure/variants](#8-express-cases-and-failure-not-encodings),
  [async/actors](#9-one-awaitable-surface-three-execution-tools).
- Extension: [generics/types](#11-reuse-types-extend-behavior-and-specialize-work),
  [protocols](#12-protocols-are-explicit-conventions),
  [macros/JSX](#13-compile-time-code-macros-and-jsx).
- Boundaries: [native ABI](#10-use-c-directly-make-the-boundary-explicit),
  [codecs](#14-validate-data-at-the-boundary), [Proxy](#15-proxy-and-reflection).
- Delivery: [builds/targets](#16-modules-builds-and-targets),
  [standard modules](#17-know-the-library-boundary), [tests](#18-tests-measurement-and-delivery),
  [current limits](#19-current-limits-and-design-boundaries).
- Worked recipes: [managed-field owner](#compose-resource-hooks-with-managed-fields),
  [retained C callback](#complete-retained-context-handoff),
  [checked macro](#check-a-macro-input-before-generating-an-expression),
  [two declarations](#generate-two-declarations-with-splicemany),
  [nullable JSON](#required-nullable-json-distinguish-missing-from-null),
  [strict CBOR](#strict-cbor-field-kind-duplicate-policy-exact-extraction-then-range).

## 1. Defaults that make code read as MetaScript

- `const` first; `let` when the binding or its value-owned storage must change.
- `struct` for data values; `interface`/`class` when sharing, identity or inheritance is intended.
- `int32` for ordinary indices/counts; deliberate `int64`/`uint64` for wider domains;
  `float32`/`float64` for fractional data. Avoid bare `number`; cast narrowing and signedness
  changes explicitly. A width or cast is not input-range validation; integer division truncates.
- `match` for discrete cases, `if` for conditions, `for..of` for sequences, indexed `for`
  when the index matters, `while` for condition-driven work. Do not write `switch`.
- `Result<T, E>` for recoverable failure; `T | null` for absence; `boolean` for yes/no queries.
- Use named exports, descriptive camelCase names, tabs and code lines at most 100 columns wide.
  The entry module's top-level code runs; a function named `main` is not called automatically.

## 2. Files, APIs and formatting

A `.ms` file is a module. Its top-level code is its entry point; functions run only when called.
Keep one coherent concern per module, private helpers beside their consumer, and a small named
export surface. Import named exports (`import { Point, total } from "./point"`); use relative
paths within a project and `std/...` for standard modules. A narrow `index.ms` barrel may re-export
that surface. Do not make every helper public or create a class just to namespace functions.

Use camelCase for files, variables, fields and functions; PascalCase for types and enum members;
UPPER_SNAKE_CASE for true module constants. Spell out domain names instead of saving characters.
Use tabs for indentation, semicolons and braces. Keep code at most 100 display columns wide;
a tab stop is four columns, not one character. When a construct no longer fits, put one field,
argument, import or parameter per line with a trailing comma. Enum declarations put one member
per line with trailing commas even when short. Break a binary expression after its operator;
start a continued method chain with the dot on the following line. Prefer early guards to deep
nesting. These are authoring rules, not a claim that every alternative spelling is a parse error.

Use meaningful domain names rather than compressed abbreviations. Keep implementation helpers
private beside their consumer; an index barrel exposes a deliberate API, not every file. Prefer
a literal or spread over a constructor that only forwards fields. Introduce a type/helper when
it gives a real contract a name, not merely to move a line elsewhere. Comments explain a
non-obvious constraint that the name, type or test cannot express; do not narrate the code.

Annotate exported parameters and returns, callback contracts and data-layout fields. Infer obvious
locals instead of repeating types; use `void` when there is no result. A small complete module:

```ms
export function doubled(value: int32): int32 {
	return value * 2;
}

test "doubling preserves zero" {
	assert doubled(0) == 0;
}

when (!testBuild) {
	console.log(doubled(21));
}
```

### Formatting is part of the API's readability

This complete module shows trailing commas, an operator at the end of a continued line and
leading dots on a continued method chain. Formatting does not change the value contract:

```ms
enum Level {
	First,
	Second,
}
function bounded(
	value: int32,
	low: int32,
	high: int32,
): int32 {
	return Math.min(
		Math.max(value, low),
		high,
	);
}
const bits = (1 as uint32) |
	(2 as uint32);
const text = "a"
	.repeat(2)
	.repeat(3);
console.log(Level.First as int32, Level.Second as int32, bounded(7, 0, 4), bits, text);
```

C and JS print `0 1 4 3 aaaaaa`. Run `msc fmt` when useful, inspect what it changes and keep
semantic tests; a formatter result is not a correctness check or proof of idempotence. Avoid
unrelated whole-file formatting in a behavioral change because it hides the contract being reviewed.

### Program entry, tests and shutdown

Save the `doubled` module above as `app.ms`: `msc check app.ms`, `msc run app.ms`,
`msc test app.ms`.
Compiler options precede the file: `msc run --release app.ms`, `msc run --target=js app.ms`.
Guard a CLI entry with `when (!testBuild)` so testing its module does not start the application.
A named `main` is an ordinary function: call it explicitly, or keep a short entry at top level.
Await an async entry so its errors and completion remain visible. Do not finish every host tool
with `process.exit(main())`: an explicit exit skips pending work, cleanup and orphan rejection
reporting. Use it only when intentionally bypassing that lifecycle and owning the consequences.
Keep library imports free of unrelated startup effects. Use `.cms` for native implementations,
`.jms` for JS implementations, and `.ms` for portable code; native success is not backend parity.

### Function contracts

Use named functions for public operations and arrows for local callbacks. A callback type is
`(value: T) => U`; a rest parameter is `...values: T[]`. Optional parameters/properties use null,
not a separate undefined value. Default parameters, annotated object parameter patterns and
contextually typed callback patterns are supported:

```ms
interface Params { n?: int32; }
function withDefault({ n = 4 }: Params): int32 { return n; }
const read: (value: Params) => int32 = ({ n }) => n ?? 7;
function total(...items: int32[]): int32 {
	let sum: int32 = 0;
	for (const item of items) { sum += item; }
	return sum;
}
console.log(withDefault({}), read({}), total(1, 2, 3));
```

Closures/nested functions capture state; do not assume a callback is a plain C function pointer
or that a local `const` callback can read a later uninitialized binding. Annotate recursive
boundaries. Every returning path must satisfy the result contract. `void` means no useful result;
`never` is for an operation that cannot return normally, not a way to hide a missing return.

Overloads can use concrete bodies with distinct parameter types or supported signatures followed
by an implementation. Return-type-only overloads are ambiguous. Prefer a generic when one body
expresses the operation; annotate literal/callback inputs when contextual overload ranking needs
help rather than relying on accidental declaration order.

Parameter modes are contracts: ordinary parameters borrow, `readonly` forbids mutation, `ref`
mutates a caller location, `out` initializes it, and `sink` takes ownership (§6). Modes affect
function compatibility and overrides. Destructuring does not waive lifetime or mutation rules.

## 3. Numbers, domain types and conversions

| Meaning | Default |
|---|---|
| Ordinary index, count, small identifier | `int32` |
| Large signed count, timestamp or delta | `int64` |
| Nonnegative wide quantity, bit pattern or hash | `uint64` |
| Packed storage or exact ABI field | Its actual `int8`/`uint8`/… width |
| Fractional computation | `float64`; `float32` when its precision/layout is intended |

Annotate large literals at their declaration. Do integer-domain work as integers, not through a
floating intermediate; integer `/` truncates toward zero. Validate external values and ranges
before narrowing or crossing signedness. A negative signed value is not a valid unsigned quantity
merely because a mixed expression can widen it. An explicit `as` expresses a conversion, not proof
that the value belongs to your domain. Remainder follows the dividend's sign; do not use `%` as
positive modular arithmetic without handling negative inputs. Do not rely on debug overflow
checks, release wrapping or a runtime narrowing check as application validation.
A floating-to-integer cast truncates toward zero, not to the nearest integer: the checked
`4.9 as int32` and `-4.9 as int32` give `4` and `-4`. Validate finite/range and domain constraints
before that cast when the input is external. An enum likewise needs an explicit integer boundary;
do not perform arithmetic on members as if an ordinal were a general numeric quantity.
Keep wire formats explicit for large integers: the external consumer may not represent them exactly.

`Math.min`/`Math.max` can keep a shared integer domain: an explicitly uint64 pair does not need a
floating detour. Mixed integer/floating operands are a different contract. For example, the
checked `Math.min(7 as uint64, 4 as uint64)` gives integer `4`, while
`Math.min(7 as int32, 4.5)` gives `4.5`. Clamp with these operations when their common type is
intentional; validate the low/high bounds too. Do not justify an elaborate guard-only match by
an unmeasured speed difference.

A type alias names an existing type; it does not change its ownership or separate two ID domains.
Use `distinct` when mixing those domains must be an error. Convert at explicit boundaries and
opt into the base's operators only when those operations make sense for the domain:

```ms
type UserId = distinct uint64;
@delegate function `==`(this a: UserId, b: UserId): boolean;

const a = (42 as uint64) as UserId;
const b = (42 as uint64) as UserId;
console.log(a == b, a as uint64);
```

Do not silence a type error with `unknown` or chained casts. `unknown` holds managed class/interface
objects, not arbitrary scalars, arrays or maps; use a generic, union or `JsonValue` for those.
There is no universal `any`. Narrow class objects with `instanceof`; decode untrusted data.
Call a defined conversion extension (`value.asColor()`, for example) explicitly instead of assuming
that a cast invokes it. Use `String(n)` for numeric text and `.toString()` for a type's formatting
contract; a cast is not formatting or parsing.

A primitive brand such as `string & { __brand: "UserKey" }` is another nominal surface: explicit
construction from the base, with widening back to the base. Brand identity comes from its brand
field/value pairs, not just the alias name. Prefer `distinct` for a deliberately separate domain;
use a brand when that one-way compatibility is wanted. Object-only intersections combine declared
fields; they are not arbitrary native-layout reinterpretations.

### Big integers and operators

Use `bigint`/`123n` beyond fixed-width ranges. Convert deliberately between bigint, floating-point
and fixed-width values; never pass an exact identifier/amount through `number`. Bare `number`
remains float64 syntax, not arbitrary-precision integer syntax. Bigint on C/JS does not establish
bigint support in the compile-time VM. Radix/separator literals still need the right declared width.

Operator overloads use backtick names. Keep operand meaning unsurprising; use a named operation
when mutation, external-resource acquisition or failure deserves a visible contract.

```ms
struct Distance { value: int32; }
function `+`(this a: Distance, b: Distance): Distance { return { value: a.value + b.value }; }
const a: Distance = { value: 2 };
const b: Distance = { value: 3 };
const c = a + b;
console.log(c.value);
console.log(5n + 7n, (-1 as int8) >>> 0);
```

The output is `5` then `12n 255`: logical right shift preserves the operand's integer width.
Do not assume every bit operation is a JS 32-bit operation, or use one as numeric validation.
A compound operator can have its own mutating `this ref` contract; overloading a base operator
does not imply every compound spelling has identical dispatch. Import operator extensions that
are part of the API rather than making meaning depend on an unrelated caller module.

## 4. Text is not a byte offset

Use normal strings and template literals for text. On native builds strings have value semantics
with copy-on-write storage; `text += fragment` is the building idiom. Do not mutate through raw
pointers or assume a string copy has already duplicated its bytes.

String APIs expose two distinct index spaces:

| Task | API / unit |
|---|---|
| TypeScript-style text positions | `.length`, indexing, `charAt`, `charCodeAt`, `indexOf`, `slice`: UTF-16 code units |
| Parser/protocol byte positions | `.byteLength()`, `byteAt`, `byteIndexOf`, `byteSlice`: UTF-8 bytes |
| Read bytes through an API | `asBytes()`; keep the borrowed-storage contract |

```ms
const text = "é🚀";
console.log(text.length, text.byteLength());
console.log(text.indexOf("🚀"), text.byteIndexOf("🚀"));
console.log(text.slice(0, 1), text.byteSlice(0, 2));

let line = "item";
const before = line;
line += ":";
line += String(7);
console.log(before, line);
```

Never feed a byte offset into a code-unit API or the reverse. For valid UTF-8 text and a byte
offset in range at a complete character boundary, `text.byteSlice(0, byteOffset).length` gives
the corresponding UTF-16 position; it is not an arbitrary-byte boundary validator. For `é🚀x`,
byte offsets `0, 2, 6, 7` map to code-unit positions `0, 1, 3, 4`: four units, seven bytes.
Neither length counts user-perceived graphemes. `char` is an 8-bit byte character, not a Unicode
code point; hold code points in `int32`.
`'A'` is a string, not a char literal. String `for..of` visits UTF-8 bytes, not Unicode characters;
choose an explicit index space rather than using it as a Unicode loop. Supply both slice endpoints.
For an ASCII byte delimiter, a single-character literal's `.code` gives its compile-time code:
`"A".code` is `65`, `"\n".code` is `10`. This is not a `.code` member on arbitrary char values,
a Unicode character iterator, or permission to use a multi-character literal as one character.
For a read-only string window use `Readonly<Span<char>>`, not writable `Span<char>`. Do not infer
allocation behavior or native layout from a JS implementation.

## 5. Values for data, references for sharing

| Need | Prefer | Assignment / ownership |
|---|---|---|
| Data record | `struct` | Value; copies its fields according to each field's type |
| Shared object | `interface`, `class`, `Ref<T>` | Managed reference; aliases share identity |
| Owned growable buffer | `Vec<T>` | Value; an owning copy is independent |
| Shared growable buffer | `T[]` / `Array<T>` | Managed reference; assignment aliases |
| Fixed-size storage | `T[N]` | Native: inline elements; JS: array objects |
| Window over existing elements | `Span<T>` | Non-owning, writable view; cannot resize |
| Read-only window | `Readonly<Span<T>>` | Non-owning view |
| Read-only access | `Readonly<T>` | Ownership/storage still follow `T`; not a deep clone |
| Read an existing place without copying it | local `Borrow<T>` | Read-only borrow, not an owner |
| Native address | `Ptr<T>` | Unmanaged; does not keep the pointee alive |

A struct is **not automatically stack-only or allocation-free**: strings, Vec buffers and
reference fields keep their own storage rules. Copying a struct containing `T[]` does not clone
that array. Likewise, copying a numeric native handle does not retain the resource.

An accessor that stores or returns a shared array/reference can let aliases bypass the owning
store's validation and change tracking. Comparing two wrappers afterward cannot reconstruct a
change when both already point at the modified data. Choose a deliberate owned snapshot, a
borrow with a valid scope, or mutation through the owning store. Do not blanket-convert every
field to Vec: owning copies in getters and loops are real semantic work.

Validate an identifier in its owning store. An index plus generation can reject an obsolete slot,
but does not by itself distinguish equal-looking slots in different stores. Carry or verify owner
identity at the boundary; a `distinct` wrapper prevents accidental type mixing, not forged IDs.

Add behavior with extensions, not struct-body methods or forwarding constructors:

```ms
struct Point { x: int32; y: int32; }
function total(this p: Point): int32 { return p.x + p.y; }
function shift(this ref p: Point, dx: int32): void { p.x += dx; }
function origin(out p: Point): void { p = { x: 0, y: 0 }; }

let a: Point = { x: 2, y: 3 };
let b = a;
b.shift(5);
console.log(a.total(), b.total());
origin(out b);
console.log(b.total());
```

Plain struct/Vec parameters are read-only through value-owned storage; referenced fields still
alias. Use `ref p: T` for caller mutation, or `this ref p: T` for a mutating extension.
Use a static extension (`function create(this typeof T, ...)`) for a public value-type constructor
or namespace-level operation that computes, acquires owned state or supplies defaults. A private
setup helper can stay an ordinary function. A constructor that merely forwards fields earns
neither surface: use a literal or `{ ...old, changed: value }`.

A reader whose natural receiver is a struct should use an instance extension, including a private
helper. A writer uses an explicit mutable location (`ref`, or `this ref` for a mutating extension).
Scalar arithmetic with no meaningful receiver stays a free function; do not add a wrapper/class
just to namespace it. Export and import extension names along with the receiver type.
A constructor name is not required to be globally unique across unrelated receiver types;
check resolution through the real importing module rather than inventing unique factory names
from an old limitation. Same-named source types imported under aliases are a separate case.

Prefer return values (or a tuple) for ordinary outputs. Reserve `out` for deliberate in-place
filling or a native output slot; assign it on every returning path. `ref` is a parameter mode,
not the managed pointer type `Ref<T>`.

### Classes and structural contracts

Use a class for shared identity, constructors and inherited behavior. Class methods may be in the
class; ordinary struct methods are extensions. Initialize required fields on every constructor
path; do not use a field assertion to invent valid state. `private`/`protected`, instance methods,
getters/setters, static members and checked `implements` contracts have implemented consumers.
Not every generic override, accessor, actor, extern or decorator combination is supported.

```ms
class Counter {
	protected count: int32;
	constructor(count: int32) { this.count = count; }
	read(): int32 { return this.count; }
	get current(): int32 { return this.count; }
}
class OffsetCounter extends Counter {
	constructor(count: int32) { super(count); }
	read(): int32 { return this.count + 1; }
}
function readCounter(value: Counter): int32 { return value.read(); }
const counter = new OffsetCounter(6);
console.log(readCounter(counter), counter.current);
```

The override dispatches through a base-typed reference (`7 6`). Do not extrapolate constructor
`super(...)` to `super.method()` (§19). Native interface views/`implements` are layout-sensitive:
field order and required storage matter; a method/getter does not fill a function-typed field.
Neither structural spelling nor a cast manufactures arbitrary width-subtyping or compatible ABI.

In supported interface/class property shapes, an optional `x?: T` stores `T | null` and can
carry omission semantics for a codec. A struct declaration instead writes `x: T | null`
explicitly; the checked parser refuses the `?` shorthand on a struct field. Optional parameters
also include a null default (§2). A readonly field restricts writing that field; it is not
a deep freeze of all referenced data. Private struct fields can reserve construction authority
to their declaring module; obtain such a value through that module rather than forging a literal,
a default-filled array or a cast.

## 6. Own once; view while processing; move when finished

```ms
function sum(xs: Readonly<Span<int32>>): int32 {
	let total: int32 = 0;
	for (const x of xs) { total += x; }
	return total;
}
function example(): void {
	let values: Vec<int32> = [1, 2, 3];
	let copy = values;
	copy[0] = 9;
	const tail: Span<int32> = values[1..3];
	console.log(values[0], copy[0], sum(tail));
}
example();
```

- Accept `Readonly<Span<T>>` to read elements from Vec, shared arrays or fixed arrays without
  taking ownership; use `Span<T>` when element writes are part of the contract. `a[lo..hi]`
  excludes `hi`; `a[lo...hi]` includes it. Taking a view does not copy or allocate element storage.
- Keep views local or call-scoped. Do not resize, replace or destroy their backing storage while
  they are used, including through aliases or callees. A view does not pin its source; local
  checks are not a universal lifetime proof. Return an owner, not `Span<T>`.
- A shorter local name for a Vec can mean an owning copy. Use a view for access, not
  `const local = owner.buffer` by habit. For expensive value elements, use indexed field reads
  or a local `Borrow<T>` rather than assuming `for..of` never copies.
- `const next = move pending` and `return move pending` transfer into an owning destination;
  do not reuse the moved-from source. `move` is an expression, not a parameter modifier:
  `read(move pending)` does not make an ordinary borrowing parameter consume it.
  Last-use transfer is already optimized where legal; do not scatter `move` everywhere.
- A `readonly` parameter prohibits mutation; it does not request an owning local copy.
  For scratch value storage, write `let local = parameter`; reference fields still alias.

A `sink` parameter receives ownership: passing a still-live value copies as required; an explicit
`move` can transfer an eligible value. This differs from `move` in a borrowing call. Do not use
a moved-from owner again without establishing a new valid owned value.

A `Borrow<T>` result follows caller-owned storage rooted in the first parameter/receiver, not a
local temporary or unrelated second owner. Reading it need not copy the owner. An ordinary
inferred binding can materialize an owning value; request a borrow explicitly when that is the
contract. A borrow does not pin backing storage or make it a snapshot.

```ms
function keep(sink text: string): string { return text; }
struct Row { n: int32; }
function first(rows: Row[]): Borrow<Row> { return rows[0]; }
function readFirst(rows: Row[]): int32 { return first(rows).n; }
function demonstrate(): void {
	const kept = "a".repeat(2);
	console.log(keep(kept), kept);
	const sent = "b".repeat(2);
	console.log(keep(move sent));
	console.log(readFirst([{ n: 7 }]));
}
demonstrate();
```

Native resource owners need a real retain/clone/release or transfer contract. Prefer `defer`
for scoped cleanup. Custom lifecycle hooks **replace**, not augment, generated field operations:
you must handle every owned field, not just the native handle, and tolerate moved-from zeros.
Do not assume native destruction timing or hooks are reproduced by the JS backend.

`defer statement;` or `defer { ... }` runs on leaving its enclosing scope, including an early
return or throw; multiple registrations run in reverse order. For a retained callback context:

```ms
import { Handle } from "std/ffi";

class Context { value: int32 = 7; }
function useContext(): void {
	const context = new Context();
	const handle = Handle.retain(context);
	defer handle.release();
	console.log(handle.value().value);
}
useContext();
```

This balances this scope's retained count only. If C keeps the context afterward, its own retained
count must survive until C is finished. Calling `process.exit()` is not a substitute for cleanup.

### Pointer and lifecycle toolbox

| Tool | Lifetime contract |
|---|---|
| `Ptr<T>` | Raw typed address; no ownership, bounds or pointee-lifetime guarantee. |
| `Ref<T>` | Managed heap pointer; distinct from the `ref` parameter mode. |
| `Span<T>` | Pointer plus length; bounded non-owning access, not copied elements. |
| `Borrow<T>` | Reads an existing location; its owner/storage must outlive every use. |
| `Cursor<T>` | Nullable non-owning edge; does not retain or clear itself when the referent dies. |
| `Var<T>` | Type-level mutable-location form corresponding to `ref`; ordinary APIs should spell their parameter modes. |
| `Readonly<T>` | Access restriction; storage and ownership still follow `T`. |

Native `x as Ptr<T>` can take the address of an inline place; an integer-to-pointer conversion
instead uses the integer as an address. Neither grants lifetime. A const place remains read-only.
Arrays/strings are handles: use their proper byte/element views rather than reinterpreting the
handle as its data. Raw arithmetic/reinterpretation is native-only; non-null does not prove bounds
or alignment. Keep raw access inside a small wrapper with an ordinary typed API.

Custom hooks bind in the type's own module and run on native, not JS. Leave generated hooks in
charge unless an actual resource/ownership operation requires taking over. The six public names:

| Hook | Responsibility |
|---|---|
| `onDestroy` | Release the resource and every owned field; tolerate moved-from state. |
| `onCopy` | Implement complete copy/assignment, including the destination's old state. |
| `onMove` | Implement complete transfer without leaving two owners of one resource. |
| `onMoved` | Establish the moved-from side's safe state. |
| `onClone` | Return an independently valid owned `T` for a copy into a sink position. |
| `onTrace` | Expose every managed edge required by the native cycle visitor. |

For a struct/distinct `T`, mutating hooks take `this ref value: T` (or `this value: Var<T>`);
copy/move add `source: T`, trace adds `env: Ptr<void>`. `onClone(this value: T): T` returns a fresh
value; other hooks return void. Destroy can also take a plain/read-only value receiver.
A class/interface already has reference storage: only destroy/trace apply, with a plain receiver,
not `this ref`. Do not import internal hook names or signatures from historical designs.

Hooks replace generated field operations, not just the external-resource part. Keep them
synchronous and suitable for their calling context. A custom derived destroy hook cannot assume
automatic base-hook chaining. Do not rely on leftover primitive fields after a move.

### Compose resource hooks with managed fields

Do not put a resource-only destructor on an owner that also contains strings, Vecs or references:
that would replace their generated cleanup. Put the custom resource operation on a small leaf
and leave the containing owner's hooks generated. This native example owns explicit foreign
Handle counts and an independent Vec; it needs no invented manual field-visitor API:

```ms
import { Handle } from "std/ffi";
let destroyed: int32 = 0;
class Resource {
	id: int32;
	constructor(id: int32) { this.id = id; }
}
function onDestroy(this resource: Resource): void { destroyed += 1; }
struct Token { pointer: Ptr<void> | null; }
function releaseToken(ref token: Token): void {
	const pointer = token.pointer;
	if (pointer != null) { Handle.at<Resource>(pointer).release(); }
	token.pointer = null;
}
function onDestroy(this ref token: Token): void { releaseToken(token); }
function onCopy(this ref dest: Token, source: Token): void {
	const pointer = source.pointer;
	if (pointer != null) { Handle.at<Resource>(pointer).retain(); }
	releaseToken(dest);
	dest.pointer = pointer;
}
function onMove(this ref dest: Token, source: Token): void {
	releaseToken(dest);
	dest.pointer = source.pointer;
}
function onMoved(this ref token: Token): void { token.pointer = null; }
function onClone(this token: Token): Token {
	const pointer = token.pointer;
	if (pointer != null) { Handle.at<Resource>(pointer).retain(); }
	return { pointer };
}
struct Owner { token: Token; words: Vec<string>; }
function createOwner(id: int32): Owner {
	const resource = new Resource(id);
	return { token: { pointer: Handle.retain(resource).ptr }, words: ["original"] };
}
function demonstrate(): void {
	let first = createOwner(1);
	let second = first;
	second.words[0] = "changed";
	console.log(first.words[0], second.words[0]);
	second = createOwner(2);
	const taken = move second;
	const copies: Owner[] = [first, first];
	let tokenA = first.token;
	let tokenB = first.token;
	tokenB = move tokenA;
	const tokens: Token[] = [tokenB, tokenB];
	if (tokenB.pointer == null) { throw new Error("live token required"); }
	console.log(taken.words[0], copies.length, tokens.length, first.words[0], destroyed);
}
demonstrate();
console.log("destroyed", destroyed);
```

DRC and ORC printed `original changed`, `original 2 2 original 0`, then `destroyed 2`.
Copy/clone retain, replacement releases the old destination, move transfers its count, and
`onMoved` clears the source without releasing the transferred count. `ref` is declared on the
parameter; calls such as `releaseToken(dest)` do not add a `ref` argument keyword.

`Owner` still gets generated Vec copy/destruction and moved-from handling. `Token` has no managed
field to visit: its pointer is an explicitly retained external root, released by the leaf hook.
`Resource` has only a scalar field, so its counting destructor does not conceal managed cleanup.
This is composition, not a manual `onTrace` recipe for an arbitrary managed graph. Do not hide
managed cycle edges behind raw pointers. For an actual SDK resource, use that SDK's documented
retain/release pair; `Handle.at<T>` is only for a valid matching Handle token, not an SDK address.

Reference counting alone does not reclaim ownership cycles. Use the collector mode appropriate
to the graph, or a genuinely non-owning back-edge with a proven owner lifetime. A cursor is not
a clearing weak reference. Do not disable memory management to hide an ownership bug.

## 7. Collections and iteration

Choose the storage contract before choosing an API: Vec owns its buffer, `T[]` shares it, `T[N]`
is fixed storage, and Span is a window. Mutation of a value-owned local requires `let`; a `const`
shared-array handle still allows writes to its shared elements. Use `Readonly<T>` at an API that
must not write. Returning/storing a reference deliberately shares it; returning a value may copy it.

Use `Map<K, V>` and `Set<T>` when insertion order is part of the behavior. Use `HashMap<K, V>` or
`HashSet<T>` when order is irrelevant; never make program output depend on their iteration order.
Keep keys stable while stored. Equality and identity are contracts, not interchangeable optimizations:
a struct/Vec is a value, while two equal-looking reference objects can still be different keys.

```ms
const scores = new Map<string, int32>();
scores.set("ada", 3);
scores.set("lin", 5);
const score = scores.get("ada");
if (score !== null) { console.log(score); }
for (const name of scores) { console.log(name); }

const visited = new Set<string>();
visited.add("ada");
console.log(visited.has("ada"));
```

`Map.get` returns `V | null`; narrow the result before use instead of inventing a default that
hides absence. Direct Map iteration visits keys; use an explicit value/pair API for other shapes.
Collection helpers that build arrays, iterator state or strings can allocate; `keys()`/`values()`
are not free views. Do not resize a sequence while traversing it or mutate a map/set while iterating.
Use a second collection or a separate update phase when mutation would invalidate the traversal.

Prefer `for..of` when only elements matter. Use an indexed `for` for integer ranges, matching
multiple arrays or avoiding an expensive element copy; use `while` for drains/convergence/scans
without a natural sequence. Prefer one readable loop over a chain of allocating transformations
when processing owned buffers in a hot path. Use a named tuple/struct when multiple outputs need
meaning; a short `[min, max]` pair is clearer than unrelated out parameters.

Tuples (`[T, U]`, including named/optional elements) are aggregates; each element keeps its own
ownership. Array/object declaration and parameter destructuring are not the unsupported `match`
patterns mentioned below. Use them to name meaningful components, not to conceal expensive copies.
A tuple rest parameter can describe correlated arity; do not assume every nested/rest pattern is
supported just because simple destructuring works.

For a resumable producer, a generator returns `Iterator<T>`, not `Generator<T>`. Constructing it
is not materializing every result. Check `.done` before reading `.value`:

```ms
function* integers(): Iterator<int32> {
	yield 2;
	yield 3;
}
const iterator = integers();
let next = iterator.next();
let total: int32 = 0;
while (!next.done) {
	total += next.value;
	next = iterator.next();
}
console.log(total);
let traversed: int32 = 0;
for (const item of integers()) { traversed += item; }
console.log(traversed);
```

Both traversals print `5`, but their storage/work need not be identical. The standard
`Iterator.toItems` adapter drains into an array; do not promise streaming/allocation-free
`for..of` from the generator spelling. Use checked `.next()` consumption when that distinction
matters. Keep suspension state owned; a borrowed view cannot simply remain valid across a yield.

Keep loops structured; extract a helper when multiple exit levels would obscure the operation.
Do not replace a counted `for` with a hand-maintained `while` counter. Array helpers belong to
the actual container and backend, not an assumed JS prototype: do not assume `map`, `filter`,
`reduce`, sorting or splice semantics from the spelling `T[]`. A direct loop is the clear fallback
when the helper's supported contract is not established, not a blanket ban on library helpers.
Do not assume delegation, send/throw/close or a final return payload from another generator API.

## 8. Express cases and failure, not encodings

```ms
enum Fault {
	ZeroDivisor,
}
function divide(a: int32, b: int32): Result<int32, Fault> {
	if (b == 0) { return Result.err(Fault.ZeroDivisor); }
	return Result.ok(a / b);
}
function calculate(b: int32): Result<int32, Fault> {
	const n = try divide(12, b);
	return Result.ok(n + 2);
}
const n = try calculate(3) catch 0;
console.log(n);
```

Use `try operation()` to propagate inside a Result-returning function; use `try ... catch value`
only when that fallback is meaningful. Narrow `.ok` before reading `.value` or `.error`.
Use enum errors for machine handling, strings for human diagnostics. No useful success payload:
`Result<void, E>` with `Result.ok(null)`, not a dummy count. A payload can still allocate.

Use `match` instead of enum `if/else` ladders. Keep ordinary preconditions and thresholds as `if`.
Choose the construct by what the reader must understand, not by using match everywhere:

| Decision | Prefer |
|---|---|
| One enum/literal selects a case | A match table with complete coverage |
| Discrete cases plus a guarded exception | Keep the guard beside its case |
| Every arm would be `_ when ...` | An if chain or a named helper; there is no useful case table |
| A precondition that exits early | An if guard |
| An ordinary binary condition | If/ternary; a meaningful two-variant family can still deserve match |

An enum and its complete dispatch table make the choices visible:

```ms
enum Mode {
	Read,
	Write,
}
function cost(mode: Mode): int32 {
	return match (mode) {
		Mode.Read => 1,
		Mode.Write => 2,
	};
}
console.log(cost(Mode.Write));
const modes: BitSet<Mode> = Mode.Read | Mode.Write;
console.log(modes.has(Mode.Write));
```

Cover enum members; guarded arms need an unguarded fallback. Use `_` for wildcard, `|` for
alternatives and `when` for a guard on an existing scrutinee variable. Expression block arms
need explicit `return`; parenthesize a struct-literal arm (`=> ({ ...value, x: 1 })`). Do not
assume object/tuple destructuring patterns or pattern bindings from another language are supported.

At an application boundary, handle both success and failure deliberately. Do not turn expected
failures into `-1`, a boolean-plus-out protocol or a log followed by silent success. Keep exceptions
for exceptional failures or foreign APIs that already throw; use `try/catch/finally` to translate
or clean up at that boundary, not to erase an error. Test failures and caller misuse must fail
loudly. Ordinary absence and yes/no queries remain nullable and boolean, not artificial Results.

### Enum membership is not an integer flag field

Use `BitSet<E>` instead of an integer mask when the meaning is membership in a named enum.
Members are ordinal (`0, 1, ...`), not hand-numbered powers of two. A member's ordinal and a
one-member bit mask are different values: do not write `Feature.Write as BitSet<Feature>`.
Start from empty and include it. A bare member is not a standalone set literal.

```ms
enum Feature {
	Read,
	Write,
	Trace,
}
const empty = 0 as BitSet<Feature>;
const active = empty.incl(Feature.Read).incl(Feature.Write);
const next = active.excl(Feature.Read).incl(Feature.Trace);
console.log(active.has(Feature.Read), active.size(), empty.isEmpty());
console.log(active.intersection(next).toString());
console.log(active.difference(next).toString());
console.log(active.union(next).toString());
console.log(active.symmetricDifference(next).toString());
console.log(active.isSubsetOf(active.union(next)), active.isDisjointFrom(empty));
let mask = empty;
mask |= Feature.Write;
console.log(mask.toString(), active == empty);
for (const feature of active) { console.log(feature.toString()); }
const decoded = (3 as uint8) as BitSet<Feature>;
console.log(decoded.has(Feature.Read), decoded.has(Feature.Write));
```

The methods return a new set or a query result; `next` does not mutate `active`. Intersection is
`{Write}`, difference `{Read}`, union `{Read, Write, Trace}` and symmetric difference
`{Read, Trace}`. Iteration visits `Read` then `Write`; it is ordinal, not insertion order.
Use `.has` for membership, `.isSubsetOf`/`.isSupersetOf` for containment and `.isDisjointFrom`
for disjointness. Equality compares sets of the same enum, not a set against one member.

`|`, `&` and `^` express union, intersection and symmetric difference; retain the assigned result.
Use `.excl`/`.difference` instead of treating a set or member as an arbitrary integer to complement.
Its native representation depends on the enum's size: do not assume every set is a uint32 or
uint64 ABI field. At a raw mask boundary choose the actual storage width and validate unknown bits
before constructing the set; the small checked example intentionally uses uint8 for three members.
Packed wire/native layouts may instead store an explicit integer and expose a validated typed view.
The same applies to an enum field: a small ordinal does not itself promise uint8 ABI storage.
Choose the layout's actual integer width, validate which ordinals are allowed and then convert
at the domain boundary; neither a cast nor a familiar TS enum spelling proves the external layout.

Format enum/set text explicitly with `.toString()`, including logging and wire adapters. Do not
assume `String(value)`, a template and a debug console call share the same custom dispatch.
Iteration and stringification can materialize arrays/strings, so their convenient spelling is
not an allocation-free or on-chain recipe. Native custom hashing is not JS custom-key parity (§12).

### Absence and variants

For optional data, write `T | null` and narrow with `if (x !== null)`; never disguise an empty
value as a valid `T` with a double cast.

Optional chaining/nullish fallback handle expected absence; they are not input validation.
Prefer a real checked branch over a non-null assertion when absence is an error.

A user-defined variant family can use an enum/boolean `match` type or a TS-style union sharing a
literal discriminator. Narrow before reading a payload. Choose `struct ... = match` for value
arms; an anonymous/reference arm does not become a deep copy because its carrier is a union.

```ms
interface Value { n: int32; }
function read(value: Value | null): int32 { return value?.n ?? 0; }
console.log(read(null), read({ n: 7 }));

enum Kind {
	Text,
	Count,
}
struct Data = match (kind: Kind) {
	Kind.Text => { text: string },
	Kind.Count => { count: int32 },
};
function describe(value: Data): string {
	if (value.kind === Kind.Text) { return value.text; }
	return value.count.toString();
}
console.log(describe({ kind: Kind.Count, count: 7 }));
```

## 9. One awaitable surface, three execution tools

| Work | Prefer | Reason |
|---|---|---|
| I/O that can suspend | `async` / `await` | Suspension is not parallel CPU execution |
| Independent, substantial CPU jobs | `spawn` then `Promise.all` | Submit before joining; amortize scheduling cost |
| Long-lived mutable service | `actor` | State belongs behind message methods |

An async function declares its Promise result explicitly; the entry point awaits it:

```ms
async function ready(): Promise<int32> {
	await sleepAsync(1);
	return 7;
}
console.log(await ready());
```

Submit independent jobs before joining them; use actor messages for owned service state:

```ms
actor Counter {
	private count: int32 = 0;
	add(n: int32): void { this.count += n; }
	read(): int32 { return this.count; }
}
async function run(): Promise<void> {
	const a = spawn(() => 3 * 3);
	const b = spawn(() => 4 * 4);
	const results = await Promise.all([a, b]);
	console.log(results[0], results[1]);
	const counter = new Counter();
	counter.add(2);
	console.log(await counter.read());
}
await run();
```

The tiny jobs above show syntax, not a speedup recipe. Batch real work; awaiting each spawn
inside the submission loop serializes it. Capture a per-iteration `const`, not a mutable counter.
Keep handles local and consume them once before leaving their scope.

Borrowed captures are read-only, not snapshots: keep their owners alive and unchanged until
joining. To give a worker a fresh sole-owner graph to mutate, use
`spawn(() => consume(work), { move: [work] })` and stop using `work` in the parent.
For deliberate sharing, `Arc<T>` holds immutable value data, including strings but no references
or arrays; `Locked<T>` holds plain data with no strings, arrays or references. Its
`lockedUpdate`/`lockedRead` callbacks must be short, nonblocking and contain no await, I/O or
reentry into the same cell. Do not share arbitrary mutable references or raw addresses.
Native-only ownership transfer and shared updates can be written without exposing a mutable alias:

```ms
import { lockedRead, lockedUpdate } from "std/core/promise";

interface Work { count: int32; }
struct Hits { count: int32; }
function bump(cell: Locked<Hits>): int32 {
	lockedUpdate(cell, (value: Hits): Hits => ({ count: value.count + 1 }));
	return 0;
}
async function processWork(): Promise<void> {
	const work: Work = { count: 5 };
	const moved = spawn(() => { work.count += 1; return work.count; }, { move: [work] });
	console.log(await moved);
	const hits = new Locked<Hits>({ count: 0 });
	const a = spawn(() => bump(hits));
	const b = spawn(() => bump(hits));
	const joined = await Promise.all([a, b]);
	console.log(lockedRead(hits, (value: Hits): int32 => value.count));
}
await processWork();
```

The moved input is no longer the parent's work item; only the returned result crosses back.
The lock callback returns the replacement payload; locking a separate cell does not permit
mutation of some other captured object.

Actor methods are inherently asynchronous: omit `async`; a `void` method is SEND, a value-returning
method is CALL (`await service.read()`). SEND is not a completion wait. An actor keeps its current
message through awaits; queued messages wait until it finishes. Avoid cyclic awaited CALLs.
For typed failures, async functions return `Promise<Result<T, E>>`; actor methods declare
`Result<T, E>` directly. Callers use `try await operation()`. See [concurrency](LANG.md#actors).
Actor arguments cross an ownership boundary: copy value data, explicitly `move` ownership or
share supported `Arc<T>` data. A plain const-reference borrow requires an awaited CALL; it
cannot be sent fire-and-forget or discarded. Keep its owner alive and unchanged until the reply.
Let the event loop drain; `process.exit()` bypasses pending work and orphan-failure reporting.
Native C is the concurrency target: JS result parity does not prove threads, ownership transfer,
scheduling or native resource behavior. Freestanding/on-chain code is not a concurrency target.

A native CALL/SEND pair makes the argument distinction concrete:

```ms
interface Payload { n: int32; }
actor Mailbox {
	private count: int32 = 0;
	read(payload: Payload): int32 { return payload.n; }
	store(payload: Payload): void { this.count = payload.n; }
	current(): int32 { return this.count; }
}
async function demonstrate(): Promise<void> {
	const mailbox = new Mailbox();
	const borrowed: Payload = { n: 7 };
	console.log(await mailbox.read(borrowed), borrowed.n);
	const transferred: Payload = { n: 9 };
	mailbox.store(move transferred);
	console.log(await mailbox.current());
}
await demonstrate();
```

This prints `7 7`, then `9` on native. The awaited `read` borrows `borrowed`; it remains usable
after the reply. `store` takes the moved message; do not reuse `transferred`. Submission alone
is not completion: the later CALL observes state after the earlier queued SEND in this example.
This does not grant ordering across arbitrary producers or promise that actor death ran cleanup.

### Promise, cancellation and actor lifecycle

A `Promise<T>` means eventual completion, not execution on another CPU. Prefer an async function;
use an executor to adapt a callback API. Executors run immediately and settle once. `.then`,
`.catch` and `.finally` compose values/errors/cleanup; their supported typed overloads are not an
unrestricted dynamic JS API. Return the handler's result rather than sharing a mutable result slot.

```ms
const promise = new Promise<int32>((resolve, reject) => {
	resolve(3);
	reject("late");
});
console.log(await promise.then((value: int32): int32 => value + 1));
class Ready { then(done: (value: int32) => void): void { done(7); } }
console.log(await new Ready());
const controller = new AbortController();
controller.abort("first");
controller.abort("second");
console.log(controller.signal.aborted, controller.signal.reason);
```

| Operation | Author contract |
|---|---|
| `Promise.resolve` / `reject` | Construct settled completion/failure; use an Error for meaningful failure handling. |
| `Promise.all(values)` | Input-order values; an input rejection rejects it. Empty input yields an empty array. |
| `Promise.race(values)` | First settlement wins; a rejection can win. Empty input never settles. It does not cancel the loser. |
| `Promise.any(values)` | First fulfillment wins; all-rejected/empty input rejects, without a promised AggregateError API. |
| `Promise.allSettled(values)` | Present but unsafe as its declared native result; not a recommended API on this baseline (§19). |
| `AbortController` / `AbortSignal` | Cooperative notification; aborting does not preempt arbitrary work. The first reason is retained. |
| Timers / `sleepAsync` | Schedule completion; clear handles you no longer own, especially intervals that keep the loop alive. |

Structural thenables have a statically checked callable `then` delivering a concrete value;
recursive/generic-delivered awaitables are not universally accepted. `return await` keeps
settlement inside an enclosing catch/finally. Native also permits a blocking await in an ordinary
synchronous function; JS refuses that form. Use an async function or module top-level await on JS.
Native blocking await pumps progress; async/actor await suspends its computation. Neither alone
creates CPU parallelism.

Native `AbortSignal.throwIfAborted()` and JS currently disagree (§19). Observing a flag/reason does
not certify that method or automatically abort another API: forward cancellation where supported
and handle that API's failure. A spawn timeout is not preemption; cancellation/join can outlast
the deadline. Native timed submission uses the fused `await spawn(fn, { timeout: milliseconds })`
form; do not assume the same option works on a separately stored handle. JS `spawn` scheduling
is not a native worker thread.

Actors can initialize private state in a typed constructor and expose their identity as `.pid`:

```ms
import { ExitReason, stop, nonisolated } from "std/actor";
actor Worker {
	@nonisolated readonly version: int32 = 1;
	private count: int32;
	constructor(count: int32) { this.count = count; }
	read(): int32 { return this.count; }
}
const worker = new Worker(7);
console.log(await worker.read(), worker.version);
stop(worker.pid, ExitReason.Normal);
```

This lifecycle sample is native. `std/actor` supplies `stop`, `link`/`unlink`, `trapExits`,
`monitor`/`demonitor`, `setIdleTimeout`, `registerName`/`whereis`/`unregister`. Monitoring death
notification differs from linked failure propagation. A missing registered name returns PID 0;
a PID is identity, not permission to read state. Define who stops children and owns queued work.
`onTerminate`, `onExit`, `onDown`, `onIdle` are lifecycle boundaries, not ordinary value destructors;
forced termination is not a guarantee that every cleanup hook ran. A stop request is not a
synchronous acknowledgment that every external callback/resource has gone away.

JS lifecycle links/monitors/traps/idle APIs are partly no-ops and exit-reason names differ; do not
infer native lifecycle semantics from simple CALL output parity. Import `nonisolated` from
`std/actor` to mark a field for direct external reads without a message/await (`version` above).
Reserve that exposure for immutable data: readonly does not deeply freeze referenced contents,
and the annotation is not proof of safe arbitrary sharing. Keep mutable state behind messages.
`std/actor/supervisor` has restart strategies/child specifications/introspection, but the checked
native import fails inside its implementation (§19), so it is not a green supervision recipe.

## 10. Use C directly; make the boundary explicit

Prefer real declarations: `import { twice } from "./bridge.h";` then `twice(21)` calls C.
A matching adjacent `bridge.c` is compiled automatically. For example, `bridge.h`:

```c
int twice(int value);
```

And `bridge.c` beside it:

```c
#include "bridge.h"
int twice(int value) { return value * 2; }
```

The importing module can call `console.log(twice(21))` directly; there is no handwritten marshalling
layer for this scalar ABI. See [FFI](LANG.md#extern-declarations-ffi) and
[directives](LANG.md#directives-standalone-module-level) for more native declarations.
For a hand-written ABI binding, inclusion and compilation are separate:

```ms
@include("stdlib.h");
extern function nativeAbs(n: int32): int32 from "abs";
console.log(nativeAbs(-9));
```

`from` names the C symbol, not a header. `@compile("./bridge.c")` adds source;
`@link("./library.a")` adds a link input. Use `.cms` / `.jms` or `when (c)` / `when (js)`
to separate backend implementations; a native binding does not acquire JS linkage.

Match widths, nullability, layout, allocator/free pairs and pointer retention. Use `cstring`
for read-only NUL-terminated input, not writable buffers: converting a managed string borrows
its storage, without making a writable copy. Keep it alive and unchanged; never let C write
through or retain that borrowed pointer. Writable/output APIs need independently owned mutable
storage and a matching ABI binding.

A manual extern `Readonly<Span<T>>` parameter expands to a data pointer plus `int64_t` length;
it does not adapt arbitrary pointer/count ABIs or authorize retaining a borrowed buffer.
`Ptr<T>` does not retain an object; use the [Handle contract](LANG.md#primitive-types) when C
keeps one. Copying a Handle does not create another retained count. Wrap C status-plus-output
APIs in checked `Result` APIs at the application boundary.

### ABI and retained callbacks

| Boundary | Required discipline |
|---|---|
| Header import / `extern` function, variable or constant | Match C names, types, calling convention and linkage. Extern binding is not a native implementation. |
| Opaque/header-owned `extern struct ... from ...` | C owns the layout; a declared subset of fields does not define its size/order. Do not guess packing, bitfields or alignment. |
| Fixed arrays / array parameters | Distinguish inline storage from a decayed pointer; include the API's actual length type. |
| `@exportName` | Stable symbol on an eligible nongeneric module-level function with a body and C-compatible signature. |
| Callback plus context pointer | Keep callback code and context valid until C unregisters/releases them. Capturing closures are not universal C function pointers. |
| `Handle<T>` | Explicit managed retention: `retain` adds a count, `borrow` does not; `at` reconstructs a wrapper, `value` reads it, `take` consumes the hand-off. Copying the wrapper does not retain. |

Header pointer parameters describe the C call's actual pointer, pointee and mutability contract.
An address coercion accepted for that call is not a general address-of expression and does not
make a temporary safe to retain. A scalar-pointer argument also does not prove that the following
bytes are a contiguous array. For pointer/count consumers, test multiple elements through the real
binding, including a slice and empty input; do not take element zero merely to manufacture an
address for an empty sequence. Readonly and writable pointees are different contracts.

Balance handle counts manually; do not release again after ownership-taking `take`. Never let C
retain a temporary cstring, stack address, span or unretained object. Use real writable storage
for C output and convert back under its length/terminator contract, not a managed-string cast.

### Complete retained-context handoff

This single-threaded fixture calls back synchronously from `cookbook_emit`. Successful registration
keeps the pointer but does not retain it; failure keeps nothing. Unregister clears it and leaves
no callback in flight. Save these three related files together. First, `callback.h`:

```c
#pragma once
#include <stdbool.h>
#include <stdint.h>

bool cookbook_register(void *context, bool accept);
void cookbook_emit(int32_t amount);
void cookbook_unregister(void);
void recipeOnEvent(void *context, int32_t amount);
```

`callback.c`:

```c
#include "callback.h"
#include <stddef.h>

static void *saved;

bool cookbook_register(void *context, bool accept) {
	if (!accept || saved != NULL) return false;
	saved = context;
	return true;
}

void cookbook_emit(int32_t amount) {
	if (saved != NULL) recipeOnEvent(saved, amount);
}

void cookbook_unregister(void) {
	saved = NULL;
}
```

`callbackMain.ms`:

```ms
import { Handle } from "std/ffi";
import { cookbook_register, cookbook_emit, cookbook_unregister } from "./callback.h";
let destroyed: int32 = 0;
class Context { total: int32 = 0; }
function onDestroy(this context: Context): void { destroyed += 1; }
@exportName("recipeOnEvent")
export function onEvent(pointer: Ptr<void>, amount: int32): void {
	const context = Handle.at<Context>(pointer).value();
	context.total += amount;
}
function start(accept: boolean): Result<Handle<Context>, string> {
	const context = new Context();
	const handle = Handle.retain(context);
	if (!cookbook_register(handle.ptr, accept)) {
		handle.release();
		return Result.err("registration refused");
	}
	return Result.ok(handle);
}
function demonstrate(): void {
	const failed = start(false);
	console.log(failed.ok, destroyed);
	const registration = start(true);
	if (!registration.ok) { throw new Error(registration.error); }
	{
		const handle = registration.value;
		defer { cookbook_unregister(); handle.release(); }
		cookbook_emit(7);
		console.log(handle.value().total, destroyed);
	}
	cookbook_emit(99);
}
demonstrate();
console.log(destroyed);
```

`msc run callbackMain.ms` printed `false 1`, `7 1`, then `2` under native DRC and ORC.
The failed context is released; the successful context survives `start` returning and is used
by actual C code before unregister/release. The final emit cannot call the released context.

`handle.ptr` is the pointer token; `Handle.at<Context>(pointer)` reconstructs a non-retaining
wrapper of that exact type. The callback must not release the registration's count. The successful
Result transfers the *obligation* to unregister and release exactly once, not an automatically
managed ownership count. Do not copy it into independently releasing owners. `take()` would
consume a count; this example instead ends it with `release()` and does not use it afterward.

For a real SDK, unregister must also wait for callbacks already executing and forbid future ones
before release. If callbacks come from foreign threads, runtime entry/thread attachment and
synchronization need the actual host contract; this fixture certifies none of those. Keep the
scoped cleanup, or an equivalent owner, on every exit; unregister must finish before release.
A stable exported function avoids assuming that a capturing lambda is a C ABI.

Unlike ordinary array-packed rest parameters, an extern rest tail passes each argument individually
to C. Match C's promoted argument types and the callee's format/count contract, including explicit
cstring input where required. An `unknown[]` rest spelling is not a universal boxed C ABI.

Aggregate arguments through C variadics are not portable across supported toolchains/ABIs.
Prefer a typed fixed signature or pointer/count interface, especially for structs containing
pointers. `sizeof` of a header-owned type uses its C layout, not the subset written in MetaScript.
One successful host build does not certify callbacks, layouts or another platform's ABI.

## 11. Reuse types, extend behavior and specialize work

Use generics instead of copied type-specific algorithms; ownership still follows the actual `T`.
A generic over a value type must not accidentally add an owning copy to every read. Accept a Span
for element access, `ref` for owner mutation and an owning return when a result must escape.
Prefer one clear typed implementation; add overloads only when the accepted contracts truly differ.

Use the extension receiver modes above. Export extensions that callers in another module need,
and import their names as well as the type. For a shared interface's
callback contract, a function-typed field is explicit: `onChange: (value: int32) => void`.

### Type-level computation

These operations compute types, not runtime schema validators. Name intermediate aliases rather
than exposing a clever type expression whose diagnostics nobody can understand.

| Surface | Use and boundary |
|---|---|
| Generic constraints/defaults | State required operations; do not infer application of function type-parameter defaults from parsing alone (§19). |
| Literal/union/intersection types | Real alternatives or combined contracts, not storage-repairing casts. |
| `keyof T`, `T[K]` | Derive property names and their corresponding types from the same shape. |
| Mapped types | Transform a finite key set with supported optional/readonly modifiers; not every TS extension is present. |
| `T extends U ? A : B`, `infer` | Select/extract a type from an assignability pattern; `infer` belongs inside the pattern. |
| `Partial`, `Required`, `Pick`, `Omit` | Deliberate structural input/output shapes, not partly initialized native owners. |
| `Exclude`, `Extract` | Filter union members, not runtime values. |
| `Record<K,V>` | Literal keys can form a finite record; an open string domain uses map storage, not arbitrary JS properties. |
| `Readonly` | Restrict writes; do not infer a clone, ownership transfer or immutable foreign resource. |
| Type-position `typeof` | Ordinary queries accept namespace imports, not arbitrary local values; runtime `typeof` is different. |

```ms
interface Point { x: int32; label: string; }
type Element<T> = T extends Array<infer E> ? E : T;
type Flags<T> = { [K in keyof T]: boolean };
const flags: Flags<Point> = { x: true, label: false };
const n: Element<int32[]> = 3;
console.log(flags.x, n);

type Task = { kind: "read"; key: string } | { kind: "write"; key: string; value: int32 };
function weight(task: Task): int32 {
	if (task.kind === "write") { return task.value; }
	return 0;
}
console.log(weight({ kind: "write", key: "x", value: 7 }));
```

A user-defined predicate must perform the actual check, not hide an assertion. Class `instanceof`
is useful at an `unknown` boundary; an annotation does not prove arbitrary structural fields.
Assertion-function narrowing has a separate native limitation (§19).

```ms
class Message { text: string = "hello"; }
function isMessage(value: unknown): value is Message { return value instanceof Message; }
const value: unknown = new Message();
if (isMessage(value)) { console.log(value.text); }
```

## 12. Protocols are explicit conventions

A protocol is an ordinary operation selected at a particular use site, not a registry, new
interface declaration or universal dynamic dispatch. Export/import the providing extension.
Keep protocol reads as unsurprising as the syntax they replace; bodies can still allocate,
convert, mutate shared data or fail.

| Convention | Use site and author rule |
|---|---|
| `toString` | Formatting in supported concatenation/templates; use explicit formatting at boundaries, not an assumed wire encoder or every console/String site. |
| `hash` and `==` | Native collection-key hashing/equality. Equal keys must hash alike; do not mutate key semantics while stored. There is no implicit `equals`/`hashCode` protocol. |
| `toItems` / `toPairs` | Element versus key/value traversal. Supply the required array/Iterator shape; returned views still need live owners. |
| `getDynamicField` | Otherwise unknown dotted field reads. Deliberately gives up typo checking on opted-in types. |
| `setDynamicField` | Otherwise unknown dotted writes. Define miss/write policy; known physical fields remain ordinary fields. |
| `valueOf` | One fallback read-through when the original value does not fit. Already-valid identity/inference/generic operations retain the original object. |
| Runtime `converter` | Deliberate one-step conversion to a required target type, not assertion, validation or overload scoring. |
| `then` | Checked structural adoption at supported await/settlement sites (§9), not a custom awaitable annotation. |

Dynamic field dispatch is dotted access, not universal bracket/length synthesis. Optional access,
compound writes and chained writes do not all have ordinary field semantics. Native custom hash
extensions do not make JS's separate collections custom-hash collections. Check the actual key
contract before claiming cross-backend value-key parity.

### Formatting is a protocol, not a cast

Keep formatting explicit where it becomes a user-visible or wire contract. This struct extension
is used by an explicit call, concatenation, interpolation and append:

```ms
struct Point { x: int32; }
function toString(this point: Point): string { return `point:${point.x}`; }
const point: Point = { x: 3 };
console.log(point.toString());
console.log(`at ${point}`, "at " + point);
let text = "at ";
text += point;
console.log(text);
```

C and JS print `point:3`, `at point:3 at point:3`, then `at point:3`. A separate checked
`String(point)` call also prints `point:3` on this baseline; an older blanket prohibition is
not a current language rule. This one receiver does not certify every class, enum, debug console
or overload combination. Prefer `.toString()` when the exact formatting operation is part of
the API. A debug dump is not a wire format; a formatting method is not a parser or validator.

### Dynamic fields and one-step conversions

```ms
interface Store { id: int32; fields: Map<string, int32>; }
export function getDynamicField(this store: Store, key: string): int32 {
	return store.fields.get(key) ?? 0;
}
export function setDynamicField(this store: Store, key: string, value: int32): void {
	store.fields.set(key, value);
}
const store: Store = { id: 9, fields: new Map<string, int32>() };
store.count = 7;
console.log(store.count, store.id);

interface Box { value: int32; }
export converter boxToInt(box: Box): int32 { return box.value; }
const box: Box = { value: 8 };
const n: int32 = box;
console.log(n);

struct Cell { value: int32; }
export function valueOf(this cell: Cell): int32 { return cell.value; }
const cell: Cell = { value: 10 };
const value: int32 = cell;
const original = cell;
console.log(value, original.value);
```

A runtime converter is module-level, nongeneric, has one nondefault parameter and an explicit
return type. Its source or target belongs to its declaring module, and the converter must be
visible at the use site. It does not chain, choose overloads or redefine ordinary truthiness;
numeric/distinct casts retain their cast meaning. A `Node`-source converter instead runs at
compile time (§13).

`asString`, `asInt32`, `asBoolean` and similar names are ordinary explicit accessors. Historical
`as<Type>` prose does not make every such method an implicit conversion. In particular, a parsed
format value's accessor can default: a dynamic read plus a cast is not schema validation.

### Generic protocols across modules

A generic walker can call a concrete type's caller-visible extension. Export it and import the
operations with the type. Put implementations beside their receiver type or the walker; this
co-location is discipline, not globally enforced coherence. Generic-instance caching is not a
guarantee that the same concrete type can mean different things in unrelated caller modules.

`protocolLib.ms`:

```ms
export function readWith<T>(value: T): int32 { return value.protoRead(); }
```

`protocolMain.ms`:

```ms
import { readWith } from "./protocolLib";
struct Reading { n: int32; }
export function protoRead(this value: Reading): int32 { return value.n; }
const value: Reading = { n: 7 };
console.log(readWith(value));
```

## 13. Compile-time code, macros and JSX

Use `@comptime` for genuine constants and tables, `when` for compile-time selection, and macros
only when typed functions cannot express the required code generation:

```ms
const TABLE_SIZE: int32 = @comptime { return 4 * 1024; };
@comptime function square(n: int32): int32 { return n * n; }
const FOUR: int32 = square(2);
when (c) { console.log(TABLE_SIZE, FOUR); } else when (js) { console.log(TABLE_SIZE, FOUR); }
```

Type-trait `when` can select an implementation per concrete generic instance without a runtime
branch. Import the trait; an ordinary runtime `if` does not have this specialization contract:

```ms
import { isPlainData } from "std/typetraits";

function category<T>(value: T): string {
	when (isPlainData<T>()) { return "plain"; } else { return "managed"; }
}
console.log(category(7), category("text"));
```

Use `when (c)` / `when (js)` or target flags to gate target-specific declarations. `debug` and
`testBuild` select their corresponding build contexts; OS/host flags describe the chosen target,
not a runtime test. Supply a custom flag through `-d:canonicalExample` or `build.ms` `defines`;
for example, `msc run -d:canonicalExample app.ms` selects `when (canonicalExample)`.
Untaken branches
are not type-checked; unknown flags are false, so check spelling. Comptime function arguments must
be compile-time values. Compile-time I/O is a build input, not free runtime work. Macros use
`macro`/`quote` for AST generation and are invoked as ordinary bare calls; keep generation local,
typed and necessary. Use [LANG.md](LANG.md#conditional-compilation) for the exact grammar.

### Choose the smallest compile-time tool

| Tool | Appropriate job |
|---|---|
| `when` / `else when` | Compile-time target/feature selection, not a runtime condition. |
| `@comptime` expression/block | Build-time evaluation; a statement block leaves no runtime statement. |
| `@comptime function` | Evaluate a helper whose inputs are compile-time values; arbitrary runtime APIs are not VM APIs. |
| `macro name(node: Node): Node` | Inspect/generate caller AST, not evaluated runtime arguments. Invoke with a bare call, not `@name(...)`. |
| `getType(node)` in a checked macro | Inspect checked syntax; no `typed` parameter modifier. Early declaration-generation inputs may be untyped. |
| `quote { ... }`, `${node}` | Construct/splice AST, not text pretending to be syntax. |
| `converter name(node: Node): Target` | Compile-time expansion at a supported expected-type boundary, rechecked against runtime `Target`. |
| Statement macro / `SpliceMany` | Generate declarations/sibling statements; do not assume recursive flattening of nested splices. |
| Decorator | Transform a supported declaration or preserve field metadata; not arbitrary runtime annotation execution. |
| `@emit`, native directives | Explicit backend escape hatches; own their generated code, ABI and lifetime obligations. |
| `@inline`, `@noinline`, `@computedGoto` | Specialized native code-generation hints, not portability, lifetime or speed guarantees. |

Import public APIs from `std/meta`. Macro engine syntax uses flat fields such as `node.jsxTag`;
ordinary runtime Node construction has the actual tagged Node shape. Check kinds before reading
kind-specific fields. Preserve useful source locations. Guard nullable query results and negative
unavailable sizes/offsets before using them as layouts or allocation sizes.

| API family | Purpose |
|---|---|
| `Node`, `NodeKind`, `createNode` / `createNodeAt` | Construct/inspect actual AST shapes; compiler-wire macro literals are not a universal runtime constructor shape. |
| `bindSym`, `getImpl`, `resolveType` | Refer to a real declaration/type instead of inventing an identifier spelling. |
| `getType`, `getTypeImpl`, `typeKind`, `sameType`, `symKind` | Inspect checked semantics; syntax, aliases and resolved representation are different views. |
| `childCount` / `childAt`, literal-value helpers | Traverse/query nodes from reusable macro helpers without assuming flat-wire member access everywhere. |
| `getSize`, `getAlign`, `getOffset`, `getTypeArg` | Inspect known target layout/current instantiation, not the physical layout of host JS objects. |
| `define`, `warning`, `error` | Read build definitions and diagnose the offending node. |
| `expansionFile`, `readFile` | Build-time source/resources; resolve paths deliberately instead of assuming cwd is the caller's directory. |

Quoted local declarations receive fresh names; handwritten identifier records do not inherit that
guarantee. Keep generated work visible and inspect expansions when the abstraction becomes harder
to debug than its output. Macro libraries are trusted build-time code; unexported evaluator
internals are not application APIs.

### Check a macro input before generating an expression

A normal `Node` argument can carry checked type information. Ask for it and reject an unavailable
or wrong type; do not infer semantics from identifier spelling. This expression macro accepts
an explicitly int32 value and evaluates the spliced expression once:

```ms
import { Node, getType, resolveType, sameType, error } from "std/meta";
macro addInt32(value: Node): Node {
	const actual = getType(value);
	const expected = resolveType("int32");
	if (actual == null || expected == null || !sameType(actual, expected)) {
		error("addInt32 requires int32", value);
	}
	return quote { ${value} + 1 };
}
function demonstrate(): void {
	const value: int32 = 6;
	console.log(addInt32(value), addInt32(8 as int32));
}
demonstrate();
```

C and JS print `7 9`. Replacing a call with `addInt32("bad")` or `addInt32(7 as int64)` is
refused during checking: `Macro 'addInt32': addInt32 requires int32`. There is no separate
`typed` keyword to invent.
The query is phase-dependent: an imported macro's bare module-level declaration call expands
early, before its input necessarily has a checked type. Use that position to generate declarations,
not to assume that `getType` is available there.

### Generate two declarations with SpliceMany

Here the exported macro deliberately uses syntax, not an early type query. `pairMacro.ms`:

```ms
import { Node, NodeKind } from "std/meta";
export macro declarePair(value: Node): Node {
	return {
		kind: NodeKind.SpliceMany, line: value.line, column: value.column,
		spliceNodes: [
			{
				kind: NodeKind.FunctionDecl, line: value.line, column: value.column,
				fnName: "firstValue", params: [], fnParamTypes: [], fnReturnType: "int32",
				fnFlags: "", fnDefaults: [], nativeName: "",
				nameLocation: { line: value.line, column: value.column },
				fnBody: quote { const scratch: int32 = 1; return ${value} + scratch; },
			},
			{
				kind: NodeKind.FunctionDecl, line: value.line, column: value.column,
				fnName: "secondValue", params: [], fnParamTypes: [], fnReturnType: "int32",
				fnFlags: "", fnDefaults: [], nativeName: "",
				nameLocation: { line: value.line, column: value.column },
				fnBody: quote { const scratch: int32 = 2; return ${value} + scratch; },
			},
		],
	};
}
```

`pairMain.ms`:

```ms
import { declarePair } from "./pairMacro";
const scratch: int32 = 40;
declarePair(scratch);
console.log(firstValue(), secondValue(), scratch);
```

C and JS print `41 42 40`: both siblings exist, quoted locals do not capture the caller's
`scratch`, and the spliced caller reference keeps its meaning. These are flat compiler-wire
macro literals, not the runtime tagged Node constructor shape. The caller-visible declaration
names `firstValue`/`secondValue` are fixed: invoke this recipe once per module or choose a naming
policy that diagnoses collisions. Do not promise collision-free generated names from a
handwritten `fnName`, nested-splice flattening, or automatic validity of arbitrary input syntax.

JSX is AST syntax (elements, attributes, children, fragments), not a built-in renderer. Its chosen
macro/converter/runtime defines components, props, spread and whitespace semantics. A native
macro can explicitly consume JSX without any browser/DOM runtime:

```ms
import { Node, NodeKind } from "std/meta";
macro addOne(value: Node): Node { return quote { ${value} + 1 }; }
macro tag(node: Node): Node {
	return {
		kind: NodeKind.StringLiteral,
		line: node.line,
		column: node.column,
		value: node.jsxTag,
	};
}
console.log(addOne(3), tag(<Panel enabled={true}/>));
```

Decorators execute at compilation, but their target/result contracts differ:

| Position | Contract |
|---|---|
| Class, method, getter, setter | Receive declaration AST plus `DecoratorContext`; return a compatible replacement or nothing. |
| Class field | May return `(initial: Node) => Node` to transform initializer syntax, not its runtime value. |
| Auto-accessor (`accessor x: T = init`) | Receive `ClassAccessorDecoratorTarget` with getter/setter Nodes; return `ClassAccessorDecoratorResult` with optional replacement `get`, `set`, and/or initializer transformer `init`. |
| Struct/interface data field | Retain metadata for an explicit consumer, as shown below; not a class-field runtime initializer hook. |

`context.addInitializer(statement)` registers AST for supported runtime initialization positions;
it does not immediately execute that statement as a decorator effect. `context.access` builds
member-access syntax, not a general runtime Reflect API. `metadataSet`, `metadataHas` and
`metadataGet` operate on `context.metadata`, including inherited compile-time metadata; this does
not automatically create runtime annotations or serializer behavior. Factories/composition and
member initializers have target restrictions; do not infer parameter decorators or unrestricted
static/actor/extern support.

```ms
import { Node, DecoratorContext } from "std/meta";
function unchanged(node: Node, context: DecoratorContext): Node { return node; }
@unchanged
class Decorated { n: int32 = 7; }
console.log(new Decorated().n);
```

An auto-accessor has hidden storage plus a getter/setter. This initializer transformer doubles
its initial value; compound assignment then uses the generated accessors (`7`):

```ms
import {
	Node,
	ClassAccessorDecoratorTarget,
	ClassAccessorDecoratorContext,
	ClassAccessorDecoratorResult,
} from "std/meta";
macro doubledAccessor(
	value: ClassAccessorDecoratorTarget,
	context: ClassAccessorDecoratorContext,
): ClassAccessorDecoratorResult {
	return { init: (initial: Node): Node => quote { ${initial} * 2 } };
}
class Counter {
	@doubledAccessor accessor count: int32 = 3;
}
const counter = new Counter();
counter.count += 1;
console.log(counter.count);
```

Data-field decorators can instead preserve metadata. Their arguments are unevaluated syntax,
not runtime calls or automatic validation. A consumer must actually interpret the marker:

```ms
import { Node, NodeKind, bindSym, getImpl, error } from "std/meta";
function marker(): void { }
struct Payload { @marker("wire") value: int32; }
macro firstField(node: Node): Node {
	const declaration = getImpl(bindSym("Payload"));
	if (declaration == null) { error("Payload declaration required", node); }
	const field = declaration.interfaceFields[0];
	const annotation = declaration.interfaceFieldDecorators[0][0].macroName;
	return {
		kind: NodeKind.StringLiteral,
		line: node.line,
		column: node.column,
		value: field + ":" + annotation,
	};
}
console.log(firstField(Payload));
```

This inspects the known `Payload` (`value:marker`). A reusable macro must additionally validate
declaration kind, field count and metadata shape before indexing these arrays. Merely writing a
serializer-looking marker does not give an existing codec that feature.

## 14. Validate data at the boundary

Keep untrusted JSON, CLI input, network bytes and C outputs outside trusted domain types until
both shape and business rules are checked. `JSON.parse<T>` returns a Result; it is a decoder,
not permission to skip domain validation. Use `JSON.parseValue` for unknown schemas and explicit
accessors/narrowing instead of a cast. Keep wire records separate when their shape differs from
application state, and define large-integer, enum and nullable encodings with every real consumer.

```ms
struct WireConfig { workers: int64; label: string; }
struct Config { workers: int32; label: string; }
enum ConfigError {
	Malformed,
	InvalidWorkers,
}
function readConfig(text: string): Result<Config, ConfigError> {
	const parsed = JSON.parse<WireConfig>(text);
	if (!parsed.ok) { return Result.err(ConfigError.Malformed); }
	const config = parsed.value;
	if (config.workers < 1 || config.workers > 64) {
		return Result.err(ConfigError.InvalidWorkers);
	}
	return Result.ok({ workers: config.workers as int32, label: config.label });
}
console.log(readConfig('{"workers":4,"label":"jobs"}').ok);
console.log(readConfig('{"workers":0,"label":"jobs"}').ok);
console.log(readConfig('{"workers":"four","label":"jobs"}').ok);
console.log(readConfig('{"workers":4294967300,"label":"jobs"}').ok);
console.log(readConfig('{"workers":18446744073709551620,"label":"jobs"}').ok);
```

Decode into a representation wide enough for validation, then narrow into the domain type.
Decoding directly into a narrow field can fail or lose information before your domain check runs.
Validate lengths before indexing, arithmetic ranges before narrowing, IDs against their owning
store, and a C API's status before reading its output. Static types do not authenticate a peer,
retain a native object, or prove that a buffer is still alive. Check both the successful payload
and every refusal at the actual input boundary; logging an error and then returning success does
not make an invalid value safe. A failed invariant names the case;
it does not silently default, clamp untrusted data or return a partly initialized success value.

### Serialization is a format contract, not an assertion

Typed JSON is not a complete application schema validator. Still validate bounds, discriminants,
presence and cross-field rules before constructing a domain value. Optional omission, nullable
normalization and unknown-field policy belong to the wire contract.

`JSON.stringify` omits an absent/null optional `field?`, but emits null for an unmarked `T | null`
field. Enums encode by member name in the checked example. Typed decode can normalize a missing
nullable field to null: the checked required `nul: string | null` accepted explicit null and an
absent key. Validate presence explicitly when it matters; a nullable result slot does not prove it.
Wide unsigned/bigint values need an exact chosen wire representation, not an assumed lossless
passage through a floating-point JSON number. In particular, the checked uint64 value `2^63`
is refused by typed stringify's signed-range conversion in C/JS debug; native `--danger` instead
emits `-9223372036854775808`, while JS still refuses it. Do not use that codec path as a lossless
full-uint64 encoder. Agree on an explicit representation with the consumer; debug refusal alone
is not a release-mode validation guarantee. A string wire field filled with `n.toString()` emits
`{"n":"9223372036854775808"}` on both checked targets, preserving this value. That is an explicit
wire-contract choice requiring consumer agreement, not an automatic codec repair.

The checked enum/nullable interface round trip emits `{"mode":"Write","nul":null}` on C/JS,
omits a null optional field, and decodes the enum back to its matching member. A direct
`JSON.parse<int32[]>("[1,2]")` is refused because this typed entry expects a struct/interface;
use an appropriate tree/schema consumer instead of assuming every top-level shape is supported.

| Surface | Contract |
|---|---|
| `JSON.parse<T>`, `JSON.stringify` | Typed codec for supported shapes; handle Result failure and perform domain validation. Nested/generic/union shapes still need representative consumer tests. |
| `JsonValue` / `std/serialize/json` | Dynamic tree access. Accessor/converter defaults do not prove the original field's kind. |
| `std/serialize/cbor` | Binary codec, value tree and typed helpers. Format decoding success is not strict validation of every target field. |
| `UntypedTree<V, Input>` | Shared exported capability for a format's `parseValue`, not every capability in the serialization design. |

### Required nullable JSON: distinguish missing from null

This wire contract requires a top-level `note`, either a string or null; unrelated fields are
allowed. Check the decoded object's key membership and original kind, not an accessor's default
or a textual substring. The 1024-byte limit is an application choice, not a universal JSON limit.

```ms
import { JsonKind, JsonValue } from "std/serialize/json";
struct Note { text: string | null; }
enum NoteError {
	TooLarge,
	Malformed,
	NotObject,
	Missing,
	WrongKind,
}
function readNote(text: string): Result<Note, NoteError> {
	if (text.byteLength() > 1024) { return Result.err(NoteError.TooLarge); }
	const parsed = JSON.parseValue(text);
	if (!parsed.ok) { return Result.err(NoteError.Malformed); }
	const root = parsed.value;
	if (root.kind != JsonKind.Object) { return Result.err(NoteError.NotObject); }
	let value: JsonValue | null = null;
	for (let i: int32 = 0; i < root.keys.length; i += 1) {
		if (root.keys[i] != "note") { continue; }
		value = root.values[i];
		break;
	}
	if (value == null) { return Result.err(NoteError.Missing); }
	if (value.kind == JsonKind.Null) { return Result.ok({ text: null }); }
	if (value.kind != JsonKind.String) { return Result.err(NoteError.WrongKind); }
	return Result.ok({ text: value.strVal });
}
const inputs = [
	"x".repeat(1025), "é".repeat(513), "bad", "[]", "null", "{}",
	'{"note":null}', '{"note":"hello"}', '{"extra":7,"note":""}',
	'{"outer":{"note":null}}', '{"\\u006eote":null}', '{"note":7}',
	'{"note":false}', '{"note":{"n":1}}', '{"note":null,"note":"x"}',
	'{"note":"x","note":null}', '{"note":"a","\\u006eote":"b"}',
];
for (const input of inputs) {
	const result = readNote(input);
	if (result.ok) { console.log("ok", result.value.text ?? "(null)"); }
	else { console.log("error", result.error.toString()); }
}
```

Both oversized inputs return `TooLarge`; the second has only 513 UTF-16 units but 1026 bytes.
Malformed input returns `Malformed`; array/null roots return `NotObject`. An absent key or one
present only inside `outer` returns `Missing`. Explicit null and the decoded escaped key succeed;
empty string remains empty. Numbers, booleans and objects return `WrongKind`, not null or a
coerced string. Here a null *pointer* means not found; a non-null JsonValue of kind Null is present.

**Duplicate-key policy:** the JSON parser collapses decoded duplicate keys, keeping the last value.
The final three cases succeed with `x`, null and `b`. A post-parse membership scan cannot recover
wire duplicates, including escaped spellings. If a protocol requires rejecting them, that needs a
parser contract that preserves/rejects duplicates; this recipe does not claim to supply one.
Neither `JsonKind.Number` nor a convenience numeric accessor alone proves exact wide-integer
preservation. Choose an exact wire representation when the consumer needs it.

### Strict CBOR field: kind, duplicate policy, exact extraction, then range

This contract permits other text keys but requires exactly one integer `count` in `1..64`.
A text `"4"`, float `4.0` and null are not the integer wire kind. Read `intVal` only after checking
Int, keep its int64 representation through validation, then narrow. Unlike the JSON parser above,
the CBOR value tree preserves repeated map entries, so this recipe can reject duplicate `count`.

```ms
import { Buffer } from "std/core/buffer";
import {
	CborKind, decode, encode, cborTextMap, cborMap, cborInt, cborText, cborFloat, cborNull,
} from "std/serialize/cbor";
enum CountError {
	TooLarge,
	Malformed,
	NotMap,
	WrongKey,
	Missing,
	Duplicate,
	WrongKind,
	OutOfRange,
}
function readCount(bytes: Buffer): Result<int32, CountError> {
	if (bytes.byteLength() > 1024) { return Result.err(CountError.TooLarge); }
	const parsed = decode(bytes);
	if (!parsed.ok) { return Result.err(CountError.Malformed); }
	const root = parsed.value;
	if (root.kind != CborKind.Map) { return Result.err(CountError.NotMap); }
	let found = false;
	let count: int64 = 0;
	for (let i: int32 = 0; i < root.keys.length; i += 1) {
		const key = root.keys[i];
		if (key.kind != CborKind.Text) { return Result.err(CountError.WrongKey); }
		if (key.textVal != "count") { continue; }
		if (found) { return Result.err(CountError.Duplicate); }
		found = true;
		const value = root.values[i];
		if (value.kind != CborKind.Int) { return Result.err(CountError.WrongKind); }
		count = value.intVal;
	}
	if (!found) { return Result.err(CountError.Missing); }
	if (count < 1 || count > 64) { return Result.err(CountError.OutOfRange); }
	return Result.ok(count as int32);
}
const inputs: Buffer[] = [
	Buffer.alloc(1025),
	encode(cborTextMap(["count"], [cborInt(4)])),
	encode(cborTextMap(["count"], [cborInt(1)])),
	encode(cborTextMap(["other", "count"], [cborText("x"), cborInt(64)])),
	encode(cborTextMap([], [])),
	encode(cborTextMap(["count"], [cborNull()])),
	encode(cborTextMap(["count"], [cborText("4")])),
	encode(cborTextMap(["count"], [cborFloat(4.0)])),
	encode(cborTextMap(["count"], [cborInt(0)])),
	encode(cborTextMap(["count"], [cborInt(65)])),
	encode(cborTextMap(["count", "count"], [cborInt(1), cborInt(2)])),
	encode(cborMap([cborInt(1)], [cborInt(4)])),
	Buffer.fromString("a165636f756e741b7fffffffffffffff", "hex"),
	Buffer.fromString("a165636f756e741b8000000000000000", "hex"),
	Buffer.fromString("a1", "hex"),
	encode(cborNull()),
];
for (const input of inputs) {
	const result = readCount(input);
	if (result.ok) { console.log("ok", result.value); }
	else { console.log("error", result.error.toString()); }
}
```

Outputs include `ok 4`, `ok 1`, `ok 64`, and named failures for size, absence, kind, range,
duplicates and non-text keys. The two long hex values encode `count = 2^63 - 1` and `2^63`:
the first reaches `OutOfRange`; the checked signed-int64 decoder refuses the second, reported
here as `Malformed`, rather than wrapping it into a valid count. A truncated map is `Malformed`;
a null root is `NotMap`. C, JS and native `--danger` agree on this entire matrix and the JSON one.

These recipes validate fields of successfully decoded trees, not arbitrary decoder resource/depth
bounds. Enforce transport/input budgets before buffering/parsing; the byte caps do not certify
every nesting, UTF-8, tag or allocation case. Defaulting typed conversion helpers are not strict
schema checks. Planned multi-format codecs,
shared typed serializer/deserializer, streaming/transcoding and rename/skip/default override
systems do not follow from the existing generic metadata mechanism. Type-level derive registration
was rejected for this design; do not add ceremony the current call-site type walker does not need.

## 15. Proxy and reflection

Prefer an ordinary record/class or an explicit protocol. Use `Proxy<T, H>` when interception itself
is the API: typed traps receive the target/key and `Reflect` performs the ordinary operation.

```ms
interface Value { n: int32; }
class Handler {
	get<K extends keyof Value>(value: Value, key: K): Value[K] { return Reflect.get(value, key); }
}
const value: Value = { n: 1 };
const proxy = new Proxy(value, new Handler());
proxy.n += 2;
console.log(value.n, proxy.n);
```

The supported traps are `get`, `set`, `has`, `deleteProperty`; missing traps fall back to target
behavior and a false write/delete result fails. Records, maps and dense arrays have different
key/write/delete/length policies. Arrays do not gain holes, arbitrary past-length writes or
length growth through a proxy. Do not infer prototype/descriptor/callable/ownKeys traps or a
security sandbox. `proxyTarget`/`proxyHandler` expose the underlying parts deliberately.

A refusing record setter has a concrete generic signature, not a guessed one. This separate
program catches the failed compound write and prints `1` on C and JS:

```ms
interface Value { n: int32; }
class Handler {
	get<K extends keyof Value>(value: Value, key: K): Value[K] {
		return Reflect.get(value, key);
	}
	set<K extends keyof Value>(value: Value, key: K, next: Value[K]): boolean {
		return false;
	}
}
const target: Value = { n: 1 };
const proxy = new Proxy(target, new Handler());
try { proxy.n += 1; }
catch (error) { console.log(target.n); }
```

The policy applies to writes through this proxy. The original target and other aliases are not
deeply frozen; this is not a read-only capability or a sandbox for arbitrary object graphs.

Compile-time AST reflection, Proxy interception and C layout queries solve different problems;
none is an arbitrary runtime cast or a universal dynamic object model.

## 16. Modules, builds and targets

### Imports and packages

Named imports/re-exports keep APIs explicit. Namespace imports group an API; aliases resolve name
clashes; side-effect imports request initialization. Prefer named library exports. `import type`
carries declarations for checking, not value initialization: the checked consumer prints `7`
without running its type provider's top-level initializer. Imported bindings/namespaces are not
writable copies.

Do not infer ordinary default-import support from a configuration file's `export default`.
The checked `import value from "./defaultLib"` is refused at parse time; named/namespace lookup
also found no `default` value from the checked `export default 7`. The `build.ms` loader contract
below is separate. Use an explicit named API rather than assuming TS module forms are universal.

Cycles do not authorize reading a value before initialization. Prefer extensionless imports; target variants include `.cms`, `.jms`,
`.rms`, `.wms` over the portable `.ms`, with target-specific resolution rules.

Dynamic `import()` takes a statically resolvable literal path and returns a promise of the module
namespace, not an arbitrary-path runtime loader. Initialization is once. These related files
printed `init` once then `3 3` on native, bundled JS and split JS:

`importLib.ms`:

```ms
console.log("init");
export const n: int32 = 3;
```

`importMain.ms`:

```ms
const a = await import("./importLib");
const b = await import("./importLib");
console.log(a.n, b.n);
```

Dynamic import has target/host restrictions, including bare/Solana and library output; do not
infer network code download or universal plugin loading from its spelling.

A package's `build.ms` is declarative configuration parsed by the compiler, not an arbitrary
configuration program. Nearest configuration establishes the project; CLI settings override it.
A minimal related pair:

`build.ms`:

```ms
const config = {
	entry: "./configured.ms",
	defines: { coverageExample: true },
	fmt: { printWidth: 100, useTabs: true },
};
export default config;
```

`configured.ms`:

```ms
when (coverageExample) { console.log("configured"); }
```

`msc run` and `msc run --target=js` in that directory printed `configured`. Other loader-supported
settings include entry/output, build target/toolchain, `cc`, `deps`, fmt/LSP options,
`globalImports`, and named `modulePass` transforms. The public configuration type and old prose
may lag loader fields; do not assume arbitrary root/alias/search-path options work.
A modulePass is a build-wide macro transform with an explicit AST contract, not an import resolver;
it must not rewrite import structure. Additive global imports do not override local/explicit names.

Use `deps: { name: "file:../lib" }` for a deliberate sibling dependency; import package subpaths.
Use `msc add`/`install`/`remove` and review lock state for registry/git dependencies. Registry
versions are not general semver ranges. `package.bin`/`msc x` expose package tools; publishing is
a separate action from checking/testing. Installing a package is not permission to execute
unreviewed code; macros/plugins/build actions are trusted-code boundaries.

### Select a consumer, not just an extension

| Target/workflow | Author obligation |
|---|---|
| Native C (`msc run` / `build`) | Runtime ownership, C toolchain/linkage and platform libraries. `build` produces a native artifact without running it; add `--emit=c` to stop after C emission, before compile/link. |
| JS (`--target=js`, optional `--split`) | Compatible JS host; split emits ES modules. No implied native hooks, layouts, C linkage or worker-thread semantics. |
| VM (`--target=raiser`) | Evaluator-supported APIs/extern bridges, not native/JS parity. Unbridged runtime calls are not valid merely because parsing succeeded. |
| `--app=lib` / `staticlib` | Stable exported ABI and host init/cleanup. Initialize the entry module/dependencies, not indiscriminately program-wide `MsMain`; do not depend on mangled internal names as a public ABI. |
| Bare/manual | Explicit host/allocation/runtime boundary. Removing automatic RC does not remove cleanup obligations or provide a new allocator API. |
| WASM / Emscripten | Distinct `--os=wasm` / `--os=emcc` toolchain/host paths. Mixed JS/WASM placement/ownership and `@wasm()` are design, not these target flags. |
| HCR (`--hcr`, `std/hcr`) | Explicit reload boundary and compatible state/resources. Globals persist; a changed initializer is not migration. Restart-required/rejected reloads are real outcomes. |
| Cross-compilation / mobile / UI hosts | Actual SDK, ABI, libraries and host lifecycle; a target name is not app certification. |
| Erlang | Postponed, not an alternative supported recipe. |

### Allocation-constrained and manually hosted code

For an allocation-constrained entry, start with scalars in/out, value structs, fixed inline
storage and deliberate output slots. The owner determines allocation, not the fact that the
API accepts a Span or returns a Result. Vecs, shared arrays, classes, dynamic strings, generator
adapters, codecs and some set operations can acquire storage; a linkable build does not prove
that the host supplies a safe allocator or that an operation fits a chain's compute budget.

Check module state and initialization against the actual host: a scalar constant, an aggregate
initializer and mutable global state are different requests. Do not turn an old target-specific
compile error into a permanent language rule, or work around it by silently changing ownership.
A freestanding build flag does not make I/O, native worker threads or runtime callbacks available.
Require the real host consumer for claims about account layout, deterministic execution, resource
budgets, allocation or shutdown; the ordinary C and JS examples here certify none of those.

### Reload and long-lived host resources

For HCR, `reload`/`lastReload`/`step` and `@beforeReload`/`@afterReload` delimit application work;
quiesce external callbacks/jobs or keep their resources under stable host ownership. Without HCR,
`step` invokes its body and reload reports NoChange. These are source-audited boundaries, not a
fresh HCR/platform certification. Optimization/GC flags never repair invalid code; check the same
contracts under intended release settings and benchmark only an optimized executable.

## 17. Know the library boundary

Use an existing standard module before building an application substitute. The prelude supplies
core types/common operations; explicit imports below inventory public families, not a claim that
every exported operation works on every backend.

| Family | Prefer it for |
|---|---|
| Prelude scalars, strings, Array/ArrayLike, fixed/typed arrays, Vec, Span, Map/Set, BitSet | Storage and iteration in §§3–7, chosen by ownership, shape and key semantics. |
| Prelude Result/errors, Promise/system/timers/abort | Explicit failure/completion contracts rather than an application-local future framework. |
| Prelude JSON/JsonValue, Buffer, BigInt, Math, Date, performance, console | Values, bytes, time and diagnostics; clocks/formatting are not security/determinism guarantees. Native Buffer's string backing does not authorize text-index APIs for binary offsets. |
| Prelude fetch/WebSocket | Supported-host network APIs; transport, protocol/status, cancellation and authorization are separate checks. |
| Prelude Proxy/Reflect | Deliberately intercepted object operations (§15), not universal reflection. |
| `std/io`, `std/fs`, `std/fs/path`, `std/os`, `std/process` | Streams, files/paths/globs/watch, system information, argv/env/cwd/children. Shell exec strings are not sanitized argv. |
| `std/net`, `std/http`, `std/https` | Sockets, protocol parsing/client/server/TLS integration. Check status and explicitly own connection cleanup. |
| `std/hash`, `std/crypto` | Collection hashing versus cryptographic hashing/randomness/signatures/ciphers. An exported algorithm or Math.random is not an authentication recipe. |
| `std/compress`, `std/archive/tar` | Compression/archives; bound decompressed size and validate extracted paths. Native dependencies do not imply JS/browser support. |
| `std/serialize/json`, `std/serialize/cbor` | Typed or dynamic format data with the schema/domain boundary in §14. |
| `std/meta`, `std/typetraits`, `std/build` | AST/macros/decorators/JSX helpers, compile-time traits and project configuration. |
| `std/actor`, `std/ffi`, `std/runtime/selector`, `std/hcr` | Explicit actor/native event/host/reload boundaries, including current limits. The selector is not a general reflection API. |
| `std/surreal`, `std/toycodec`, `std/solana`, `std/arbitrum` | Database/domain libraries, a codec demonstration and chain-specific SDKs; not language primitives or an application security audit. |

For explicit prelude imports use actual paths such as `std/core/array` or `std/core/string`, not
historical abbreviated paths. Solana's account/PDA/signing/CPI/IDL/simulator and Arbitrum's
calldata/storage/word/address APIs still require their domain's explicit byte/proof/error contracts.
This is a source inventory, not execution certification of every library or on-chain program.

## 18. Tests, measurement and delivery

Keep `test "invariant" { ... }` blocks at module scope beside their code, with the `assert` keyword.
Test one behavior per case: success, failure, empty/boundary input and an ownership-sensitive
variant when relevant. Use ordinary functions for setup; tests do not belong inside functions.
Do not depend on console output for an assertion. Test bodies are checked even when tests are
omitted from a normal executable, so keep their types correct in every supported target.

Start with `msc test module.ms`; imported modules' tests are included. Use `msc check app.ms` for
static diagnostics and `msc run app.ms` for the actual consumer path. Check a feature across its
real boundary: module imports, serialized data, native ABI or async completion. A passing unit
proves its unit, not a C library's lifetime or another backend's scheduling.

Profile representative optimized work with `msc run --release app.ms`, not only a tiny debug
loop. Compare equal toolchains, flags, inputs and ownership semantics; verify output before
comparing time. First remove avoidable work, owning copies, temporary collections and formatting
from hot loops; change the data layout only when measurement supports it. Never trade correctness,
validation or resource lifetime for an assumed speedup. Scope performance claims to the measured
host, target, build and workload. Use the project's release checks when publishing a release.

### Review checklist

Apply the items the change reaches; this is not a demand to run every target for every edit.

**Meaning and API**

- [ ] A discrete enum/literal dispatch is a match table; thresholds and early guards remain if.
- [ ] Recoverable operation failures use `Result`, absence is nullable and yes/no queries are boolean.
- [ ] A no-payload success is `Result<void, E>`, not a dummy count; every error reaches its consumer.
- [ ] Plain data uses value records; shared identity earns a reference/class. Constructors earn
  their work rather than hiding forwarded field names.
- [ ] Natural struct readers, including private helpers, use extensions; writers declare mutable
  locations. No globally unique factory-name convention is invented for unrelated types.
- [ ] Module/private/export boundaries, domain names and callback contracts are deliberate.

**Data and ownership**

- [ ] Counts, identifiers, arithmetic and ABI fields have intended widths; large literals are
  annotated and narrowing/signedness changes follow validation.
- [ ] Enum membership uses `BitSet`, not ordinal-as-mask casts. Set/enum formatting is explicit.
- [ ] Owned buffers, shared arrays, fixed storage and views are chosen by ownership, not spelling.
- [ ] A struct copy is not assumed to deep-clone references, native handles or store membership.
- [ ] Getters/setters and borrowed queries do not expose mutation that bypasses owner invariants;
  IDs are validated against the correct store, not generation alone.
- [ ] Views and raw addresses remain valid across every use; resize, replacement, move, suspension
  and shutdown cannot invalidate an outstanding borrow unnoticed.
- [ ] Custom hooks account for all owned fields, old destinations and moved-from states; generated
  field traversal stays in charge where no custom resource operation is required.

**Boundaries and concurrency**

- [ ] Text positions use the intended byte/code-unit space; wire and native layouts match consumers.
- [ ] Decode success is followed by required presence, original kind, exact extraction and domain
  checks. A defaulting accessor or cast is not a schema validator.
- [ ] C names, widths, pointer/count pairs and allocator/retain/release ownership match the real ABI.
- [ ] Retained callbacks are unregistered/quiesced before release, on failure and exceptional exits.
- [ ] CPU jobs are submitted before joining; local handles are consumed once and borrowed captures
  stay alive and unchanged. A moved graph is no longer the parent's mutable work item.
- [ ] Shared mutation uses the supported lock/message contract; lock callbacks never await or block.
- [ ] Actor SEND is submission, CALL is a reply; message ownership and failure/shutdown are explicit.
- [ ] Native ownership/lifecycle behavior is not inferred from JS facade output or a successful link.
- [ ] Allocation-constrained code has proven owners, host initialization and resource budgets.

**Verification and presentation**

- [ ] Module tests use assertions and cover success, refusal, boundaries and a relevant ownership
  variant; a real boundary has been exercised with its consumer.
- [ ] Library imports do not accidentally launch the application, and CLI tests guard startup.
- [ ] Target/build differences are explicit; benchmarks use representative optimized work and
  preserve inputs, toolchain and semantics.
- [ ] Names, tabs, 100-column wrapping, trailing commas and enum formatting follow §2, without
  unrelated scaffolding or formatting churn.

`assert condition, "context"` belongs inside a test block; the checked compiler refuses it outside
one. Application invariants instead need a meaningful checked error/exception at the appropriate
boundary, not a test-only statement or a silent default. `msc fmt` formats source; review its diff
rather than treating formatting as validation. `dump-tokens`, `dump-ast` and `pipeline` inspect
compiler representations, not wire schemas. Use `msc lsp` for editor integration; a language-server
roadmap is not a guarantee that every rename/refactoring/completion feature works. Diagnostics,
debug info and timing tools answer different questions from sanitizers and resource audits.

## 19. Current limits and design boundaries

Judge a capability by code plus a focused consumer check, not a historical SHIPPED label or an
accepted signature. The concrete refusal/runtime cases below were rechecked on installed
BUILD `38009de37` on macOS arm64 with Node `24.1.0`; they are still scoped observations,
not permanent prohibitions or desired future semantics. Broader design/host boundaries remain
requirements, not a claim that every combination was executed.

| Surface | Current disposition |
|---|---|
| `super(...)` / `super.method()` | Constructor chaining/override example runs; tested `super.read()` fails on C and JS. |
| `abstract` | An empty abstract class could still be constructed on C and JS; do not rely on abstractness enforcement. |
| Predicate / assertion function | Check boolean predicates separately. The tested `asserts value is Message` followed by a read emitted an invalid native void-pointer member read; JS ran. |
| Type-position `typeof local` | Refused with the namespace-import-only diagnostic; special static receiver syntax is not a general type query. |
| Template-literal types | The tested literal-union template type was rejected. Runtime string templates are a different feature. |
| Additional familiar TS surfaces | `DeepReadonly` did not resolve as a prelude type; the checked regex literal's `.test()` call was refused on C/JS. An AST node or familiar name is not an implemented runtime/type API. |
| Function generic defaults / const generics | The checked `zero<T = int32>()` call could not infer T. Use explicit supported type arguments/specialization; do not infer const generics from generic syntax. |
| `allSettled` | Declared `T[]` disagrees with native payload. Reading the checked result aborted (exit 134); JS produced a settlement object, not the declared integer element. |
| `throwIfAborted` | Native aborted signal threw AbortError; JS stopped with Error: unreachable. Flag/reason behavior does not certify this method. |
| Supervisor | The checked namespace import fails on C and JS on Promise<number> comparisons/indexing inside the implementation. Restart design/API is not a green recipe. |
| Cross-caller protocols | Caller-visible extensions work for instantiation, not guaranteed independent cached meanings for the same concrete type. Keep implementations coherent/type-local. |
| Lifetime/cross-thread law | §§6 and 9 are obligations, not proof that all retained addresses, thread affinity, shutdown races or unsafe closure shapes are diagnosed. |
| Proposed ownership syntax | `lent`, WeakRef and author acyclic/thread-bound annotations are not substitutes for the current documented model. Do not invent syntax from designs. |
| JSON width/shape | Full-uint64 stringify is not lossless: C debug refuses `2^63`, native danger writes a negative number and JS refuses it. The checked typed top-level int32-array parse is refused. |
| Serialization ecosystem | JSON/CBOR and UntypedTree do not establish planned common typed codecs, per-format overrides, rename/skip/default, streaming/transcoding or additional formats. |
| Other proposed extensions | Concepts/where constraints, custom literal suffixes, multimethod vtables, `.parallel()`, custom awaitable annotations and mixed-JS/WASM ownership are not current recipes merely because designs survive. |
| Optional struct fields | `struct Packet { optional?: string; }` is refused; spell a nullable value field explicitly. Interface optional properties are a different shape. |
| Ordinary default imports | The checked default-import spelling is refused; configuration's `export default` is not proof of runtime-module support. `import type` has a checked no-initialization consumer. |
| Assertion placement | `assert` is refused outside a test block. Assertion-function type narrowing is a separate feature with the native limitation above. |
| Full target parity | Native, JS, evaluator, bare/WASM and HCR have different consumers/limits; one target's success is not all targets' support. |

Coverage spans functions/classes/advanced types (§§2–5, 8, 11), ownership/views/hooks/FFI (§§5–6, 10),
collections/iterators/protocols (§§7, 12), async/actors (§9), AST/decorators/JSX (§13), formats and
interception (§§14–15), and packages/targets/std/tooling (§§16–18). Historical/rejected designs are
not promoted to available authoring APIs.

## Verification scope

The official-standard revision was checked on macOS arm64, Node `24.1.0`, installed
`msc 0.3.4`, binary/support BUILD `38009de37` (tree `4cfe2614d7ab4ec95d5179c9aa0959a3e75c1a5a`).
The authoring base is tree `ee4a66cb4721d597b0f64eaa5d3f7b2c9408284a`. All 50 MS blocks match
runnable entry sources or named related files; all 47 inherited blocks remain unchanged.
The four non-entry files are exercised through their macro, generic, dynamic-import or manifest
consumer. The four C blocks are the two compiled header/companion fixtures.

All 46 entry consumers ran successfully on native C. Of those, 42 produced matching JS output;
the owner-hook example intentionally produced `destroyed 0` on JS instead of native `destroyed 2`.
The three native-only bindings (Locked helpers, manual C extern, retained C callback) were not
JS recipes and failed there as expected. Matching output for Handle or actor facades does not
certify native retention, scheduling, hooks or shutdown on JS.

Commands were `msc run probe.ms`, `msc run --target=js probe.ms`, `msc run --gc=orc probe.ms`,
`msc run --danger probe.ms`, and `msc test app.ms`, with flags before source names. The module
example's test invocation passed 302 imported-inclusive tests. A separate `build --target=c`
produced an executable without running it; running that artifact afterward printed `42`.
This is not the compiler suite.

| Checked boundary | Representative result |
|---|---|
| Parameter modes / value storage | Mutable receiver/out `5 10` then `0`; Vec copy/view `1 9 5`; shared array field alias `0.5`, C/JS |
| Formatting / numeric choice | Formatting `0 1 4 3 aaaaaa`; signed division/remainder `-2 -1`; integer versus mixed Math.min `4 4.5`; ASCII literal codes `65 10`, C/JS |
| BitSet | Membership, empty/size, union/intersection/difference/symmetric difference, subset/disjointness, equality, ordinal iteration and a width-matched mask, C/JS |
| Static extensions | Two defining modules both export `create`; both import orders print `2 3`, C/JS |
| Protocols and generics | Dynamic field/converter/valueOf `7 9`, `8`, `10 10`; generic import `7`; custom formatting works at the explicitly checked sites, C/JS |
| Checked AST generation | Checked int32 macro `7 9`; string/int64 calls refused; declaration splice/hygiene `41 42 40`, C/JS |
| Decorators / Proxy | Accessor `7`, field metadata `value:marker`, interception `3 3`, refusing setter `1`, C/JS |
| Async / actor completion | Spawn/actor `9 16` then `2`; borrowed CALL/moved SEND `7 7` then `9`; executor/thenable and first abort reason run, C/JS |
| Promise.any | Rejected input plus fulfillment yields `3`; empty input rejects, C/JS |
| JSON / CBOR validation | Typed JSON `true false false false false`; 17-input JSON and 16-input CBOR tree matrices agree on C, JS and native danger |
| CBOR exact extraction | `9007199254740991`, `9007199254740993`, `9223372036854775807` on C/JS |
| Module consumers | Imported declarations/type-only use, caller-visible extensions, macro expansion, once-only dynamic initialization, custom flag selection and manifest defines run through their consumers |

Native owner, moved/Locked, actor argument/lifecycle and retained callback examples also ran
with ORC. Retained C registration prints `false 1`, `7 1`, then `2`; a forced throw in its
scope still unregisters/releases and prints `caught` before final `2`. The separate imported
header consumer prints `42`; the existing `externSpanAcrossModules` consumer prints
`6 26 30 0 13` for fixed/Vec/empty/sliced readonly and mutable Span ABI calls.

The refusals and runtime failures in §19 were measured too: they are not successful recipes.
This includes the native allSettled abort, JS abort-method failure, native assertion-function C
error, supervisor import errors and full-uint64 JSON danger corruption. `assert` outside tests,
optional struct `?` syntax and the tested ordinary default import/lookup forms were refused.
Explicit generic arguments, type-only imports, named library imports, optional interface JSON
and constructor/executor forms are positive controls, not evidence for all neighboring forms.

Source-audited API inventories are labeled separately from these executed consumers. Earlier
VM, JS-split, platform and performance observations are not freshly certified by this rewrite.
This is not a benchmark, compiler gate, exhaustive safety audit, sanitizer run, new reader study,
or a guarantee for foreign-thread callbacks, arbitrary managed-cycle hooks, every decoder input,
Windows/Linux/browser/freestanding/HCR/on-chain hosts. The applicable host and consumer still own
those checks. [Hook replacement](../src/test/handoff/userDestructor.ms) and
[formal ownership](../src/test/corpus/programs/parameterHookDemand/main.ms) are implementation
regression consumers, not additional test runs claimed here.
