# MetaScript authoring guideline

Write TypeScript-shaped code with explicit ownership, native layouts and deliberate concurrency.
MetaScript combines values, non-owning views, ownership transfer, compiler-managed native
lifetimes and compile-time execution. Choose semantics first; profile representative work with
`--release`, keeping target, toolchain, flags and inputs identical between variants.

This is the standalone gold standard for writing MetaScript: everyday syntax, code organization,
ownership, safety and performance practice in one place. Follow the defaults; use the exceptions
when their contract is the one your program needs. [LANG.md](LANG.md) remains the authoritative
detailed language reference, not a prerequisite for ordinary authoring.

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
Use tabs, semicolons, braces and code lines no wider than 100 columns. Break long fields,
arguments, imports and parameters one per line with trailing commas; put enum members on separate
lines. Prefer early guards to deep nesting. Comments explain a non-obvious constraint, not the code.

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

Save as `app.ms`: `msc check app.ms`, `msc run app.ms`, `msc test app.ms`.
Compiler options precede the file: `msc run --release app.ms`, `msc run --target=js app.ms`.
Guard a CLI entry with `when (!testBuild)` so testing its module does not start the application.
Keep library imports free of unrelated startup effects. Use `.cms` for native implementations,
`.jms` for JS implementations, and `.ms` for portable code; native success is not backend parity.

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
before narrowing or crossing signedness. An explicit `as` expresses a conversion, not proof that
the value belongs to your domain. Do not rely on build-mode-dependent overflow checks as validation.
Keep wire formats explicit for large integers: the external consumer may not represent them exactly.

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

Never feed a byte offset into a code-unit API or the reverse. Neither length counts user-perceived
graphemes. `char` is an 8-bit byte character, not a Unicode code point; hold code points in `int32`.
`'A'` is a string, not a char literal. String `for..of` visits UTF-8 bytes, not Unicode characters;
choose an explicit index space rather than using it as a Unicode loop. Supply both slice endpoints.
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
Use `function create(this typeof T, ...)` only when construction computes or supplies defaults;
otherwise use a literal or `{ ...old, changed: value }`.

Prefer return values (or a tuple) for ordinary outputs. Reserve `out` for deliberate in-place
filling or a native output slot; assign it on every returning path. `ref` is a parameter mode,
not the managed pointer type `Ref<T>`.

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

Use `BitSet<E>` over an ordinal enum (default `0, 1, ...`, not power-of-two flag values).
Query `.has`, keep the result of `.incl`/`.excl`. Empty is `0 as BitSet<Mode>`, not a cast of
one enum member. Format enum/set text with `.toString()`; set iteration/stringification may
allocate. For optional data, write `T | null` and narrow with `if (x !== null)`; never disguise
an empty value as a valid `T` with a double cast.

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
Let the event loop drain; `process.exit()` bypasses pending work and orphan-failure reporting.
Native C is the concurrency target: JS result parity does not prove threads, ownership transfer,
scheduling or native resource behavior. Freestanding/on-chain code is not a concurrency target.

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

## 11. Reuse types, extend behavior and specialize work

Use generics instead of copied type-specific algorithms; ownership still follows the actual `T`.
A generic over a value type must not accidentally add an owning copy to every read. Accept a Span
for element access, `ref` for owner mutation and an owning return when a result must escape.
Prefer one clear typed implementation; add overloads only when the accepted contracts truly differ.

Use the extension receiver modes above. Export extensions that callers in another module need,
and import their names as well as the type. For a shared interface's
callback contract, a function-typed field is explicit: `onChange: (value: int32) => void`.

Convention protocols are ordinary extensions with special names. Define `toString` for the type's
human-readable form, `toItems` for iteration, and named `as<Type>` conversions where meaningful.
Prefer explicit calls when conversion or formatting matters. A protocol can still allocate or
return shared data: inspect its implementation, do not assume the spelling makes it zero-cost.
Do not use runtime reflection or a macro where a field, typed function or generic says the same thing.

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

Use `when (c)` / `when (js)` or target flags to gate target-specific declarations. Untaken branches
are not type-checked; unknown flags are false, so check spelling. Comptime function arguments must
be compile-time values. Compile-time I/O is a build input, not free runtime work. Macros use
`macro`/`quote` for AST generation and are invoked as ordinary bare calls; keep generation local,
typed and necessary. Use [LANG.md](LANG.md#conditional-compilation) for the exact grammar.

## 12. Validate data at the boundary

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
retain a native object, or prove that a buffer is still alive. A failed invariant names the case;
it does not silently default, clamp untrusted data or return a partly initialized success value.

## 13. Tests, measurement and delivery

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

Before considering a module finished:

- Its API makes value ownership, sharing, mutation, absence and errors deliberate.
- Its data widths, text offsets and wire/native layouts match the consumer's contract.
- Views cannot outlive or invalidate their owners; native retention/cleanup is balanced.
- CPU jobs are submitted before joining; actor and lock rules remain valid on every exit.
- Tests cover boundaries and failure paths; supported backends keep the intended results.
- The code is formatted, named and organized for its reader, without speculative machinery.

## Verification scope

Checked on macOS arm64, installed `msc 0.3.4`, binary/support BUILD `6b8655024`, Node `24.1.0`;
source survey tree `888671e9c130e7778600088efda81e0216e8e0dc`. Commands:
`msc run probe.ms`, `msc run --target=js probe.ms`, and `msc check [--target=js] reject.ms`.

C/JS probes printed `5 10` then `0` (mutable receiver/out), `1 9 5` (Vec copy/slice),
`6` (Result), `9 16` then `2` (spawn/actor), and `4096 4` (comptime).
Additional variants covered shared reference fields, fixed-array/Vec/shared-array Span inputs,
Borrow reads, move, enum dispatch, BitSet and generic traits. Native-only probes printed `42`
(header import + companion C), `9` (manual extern), and `6` then `2` (moved capture/Locked).
The native `externSpanAcrossModules` corpus consumer printed `6 26 30 0 13` for readonly/mutable
Span ABI calls across modules, including fixed arrays, a Vec, an empty array and a slice.
Both checkers refused value-parameter mutation, a Borrow write, an incompletely written out
parameter and a direct Span return. The audit additionally checked ordinal-enum refusals on C/JS,
actor Result replies and mailbox order on C/JS, and move into borrowing parameters on C/JS.
Native probes printed `after custom 0` / `after automatic 1` for custom-hook field cleanup;
[hook replacement](../src/test/handoff/userDestructor.ms) and
[formal ownership](../src/test/corpus/programs/parameterHookDemand/main.ms) retain the contracts.

The standalone revision additionally exercises modules/test entry, distinct IDs, Unicode index
spaces, Map/Set iteration, match/BitSet, trait specialization, async entry, moved/Locked work,
Handle/defer and JSON validation. All 16 MS code blocks match checked runnable sources: 14 have
C/JS results, two are native-only; the original six retain unchanged verified code. The module
example passes `check` and `test` (302 tests including imported std tests). JSON validation returns
`true false false false false` on C, JS and C `--danger`, including integers beyond int32 and int64.
Unknown scalar/array/map admissions are refused on C/JS; class narrowing and LIFO defer order run
on both. The companion-header C example prints `42`.

This is syntax/behavior evidence, not a benchmark, exhaustive safety audit, sanitizer run or
guarantee for Windows, Linux, browser, freestanding or on-chain.
