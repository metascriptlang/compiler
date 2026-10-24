# MetaScript: preferred idioms

Write TypeScript-shaped code with explicit ownership, native layouts and deliberate concurrency.
MetaScript combines values, non-owning views, ownership transfer, compiler-managed native
lifetimes and compile-time execution. Choose semantics first; measure the hot path second.

Use this guide for choices, [LANG.md](LANG.md) for syntax and
`~/metascript/docs/CODE-STYLE.md` for full style rules. Older examples are not a capability
checklist; the verification scope below bounds these recommendations.

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

## 2. Values for data, references for sharing

| Need | Prefer | Assignment / ownership |
|---|---|---|
| Data record | `struct` | Value; copies its fields according to each field's type |
| Shared object | `interface`, `class`, `Ref<T>` | Managed reference; aliases share identity |
| Owned growable buffer | `Vec<T>` | Value; an owning copy is independent |
| Shared growable buffer | `T[]` / `Array<T>` | Managed reference; assignment aliases |
| Fixed-size storage | `T[N]` | Inline elements; no separate buffer allocation |
| Window over existing elements | `Span<T>` | Non-owning, writable view; cannot resize |
| Read-only window / shared view | `Readonly<Span<T>>`, `Readonly<T>` | View, not an owning snapshot |
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

## 3. Own once; view while processing; move when finished

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
- `const next = move pending` explicitly transfers ownership; `consume(move pending)` and
  `return move pending` are expressions, not parameter modifiers. Do not reuse the old value.
  Last-use transfer is already optimized where legal; do not scatter `move` everywhere.
- `Readonly<T>` is not the `readonly` parameter modifier: the latter requests a local value copy.
  Neither copying a wrapper nor declaring a view deep-clones its referenced objects.

Native resource owners need a real retain/clone/release or transfer contract. Use `defer` for
scoped cleanup; custom lifecycle hooks must tolerate a zeroed moved-from value. Do not assume
native destruction timing or hooks are reproduced by the JS backend.

## 4. Express cases and failure, not encodings

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

Use `match (mode) { Mode.Read => 1, Mode.Write => 2, }` instead of enum `if/else` ladders.
Cover enum members; guarded arms need an unguarded fallback. Use `_` for wildcard, `|` for
alternatives, and explicit `return` in expression block arms. Do not copy destructuring or
binding-pattern examples from older notes without checking support.

Use `BitSet<E>` instead of integer masks: `const rights: BitSet<Right> = Right.Read | Right.Write`;
query `.has`, keep the result of `.incl`/`.excl`. Empty is `0 as BitSet<Right>`, not a cast of
one enum member. Format enum/set text with `.toString()`; set iteration/stringification may
allocate. For optional data, write `T | null` and narrow with `if (x !== null)`; never disguise
an empty value as a valid `T` with a double cast.

## 5. One awaitable surface, three execution tools

| Work | Prefer | Reason |
|---|---|---|
| I/O that can suspend | `async` / `await` | Suspension is not parallel CPU execution |
| Independent, substantial CPU jobs | `spawn` then `Promise.all` | Submit before joining; amortize scheduling cost |
| Long-lived mutable service | `actor` | State belongs behind message methods |

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
For deliberate sharing, use `Arc<T>` for eligible immutable data or `Locked<T>` with a plain-data
payload; `lockedUpdate`/`lockedRead` callbacks must be short, nonblocking and contain no await,
I/O or reentry into the same cell. Do not share arbitrary mutable references or raw addresses.

Actor methods are inherently asynchronous: omit `async`; a `void` method is SEND, a value-returning
method is CALL (`await service.read()`). SEND is not a completion wait. Prefer
`Promise<Result<T, E>>` with `try await operation()` for typed asynchronous failures.
Let the event loop drain; `process.exit()` bypasses pending work and orphan-failure reporting.
Native C is the concurrency target: JS result parity does not prove threads, ownership transfer,
scheduling or native resource behavior. Freestanding/on-chain code is not a concurrency target.

## 6. Use C directly; make the boundary explicit

Prefer real declarations: `import { twice } from "./bridge.h";` then `twice(21)` calls C.
A matching adjacent `bridge.c` is compiled automatically; see [C interop](LANG-INTERLOP.md).
For a hand-written ABI binding, inclusion and compilation are separate:

```ms
@include("stdlib.h");
extern function nativeAbs(n: int32): int32 from "abs";
console.log(nativeAbs(-9));
```

`from` names the C symbol, not a header. `@compile("./bridge.c")` adds source;
`@link("./library.a")` adds a link input. Use `.cms` / `.jms` or `when (c)` / `when (js)`
to separate backend implementations; a native binding does not acquire JS linkage.

Match widths, nullability, layout, allocator/free pairs and who may retain a pointer. Use
`cstring` for the C string ABI, not a managed `string` declaration. A manual extern
`Readonly<Span<T>>` parameter expands to a data pointer plus `int64_t` length for a matching API;
it does not adapt arbitrary ABIs or authorize retaining a borrowed buffer. `Ptr<T>` does not
retain an object; use the explicit [FFI Handle contract](../std/ffi/index.cms) when C keeps one.
C status-plus-output APIs should become checked `Result` APIs at the application boundary.

## 7. Specialize work before runtime

Use generics instead of copied type-specific algorithms; ownership still follows the actual `T`.
Use `@comptime` for genuine constants and tables, `when` for compile-time selection, and macros
only when typed functions cannot express the required code generation:

```ms
const TABLE_SIZE: int32 = @comptime { return 4 * 1024; };
@comptime function square(n: int32): int32 { return n * n; }
const FOUR: int32 = square(2);
when (c) { console.log(TABLE_SIZE, FOUR); } else when (js) { console.log(TABLE_SIZE, FOUR); }
```

Type-trait `when (isPlainData<T>())` can select a generic instance's implementation without a
runtime branch. Unknown build flags are false: check spelling. Compile-time I/O is a build input,
not free runtime work. See [metaprogramming](LANG-METAPROGRAMMING.md) and
[conditional compilation](LANG.md#conditional-compilation).

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
parameter and a direct Span return. This is syntax/behavior evidence, not a benchmark, exhaustive
safety audit, sanitizer run or guarantee for Windows, Linux, browser, freestanding or on-chain.
