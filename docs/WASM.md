# WASM — one program across JS and wasm

A `--target=js` build places every `@wasm` function, and the functions it calls, in a wasm half
built by Emscripten; the compiler generates both sides of the boundary. The same program built
for C or with `--wasm-placement=off` prints the same output, which is what the oracle checks.

```ms
@wasm
export function evaluate(value: int32, callback: (value: int32) => int32): int32 {
	return callback(value) + 1;
}
```

The caller still writes `evaluate(3, (v) => v * 2)`. Where things live:
`src/compiler/wasmBoundary/` (`manifest.ms` decides what crosses and refuses the rest,
`jsSide.ms`/`jsGlue.ms` emit the JS half, `wasmSide.ms` the wasm entry, `placement.ms`/
`placementBuild.ms` the cut and the child emcc build), `src/checker/sendable.ms`
(`checkWasmFunctions`, the compile-time refusals), `std/ffi` (`Handle`, `VecBox`, `view`), and the
oracle `src/test/wasmmix/run.ms` with its programs.

## What crosses, and what the author gets

Each row is pinned by the wasmmix programs named in it; every program builds C, JS and mixed
unless its `@columns` says otherwise.

| Surface | Contract | Pins |
|---|---|---|
| Numbers, bool | typed scalars; `int64`/`uint64` as BigInt, exact | `scalars`, `wireMatrix` |
| Enums | an exported enum as itself, on the wire as its storage integer; the wasm side rebuilds it with the checked `as`, and a foreign JS caller's value outside it is a `RangeError` naming the enum; an unexported enum and an enum member type are refused | `enumCrossing`, `enumAsInt` |
| Strings | copied as WTF-8 both ways; lone surrogates, BOM, NUL survive | `strings`, `stringsLong`, `bomStrings`, `decodeWtf8`, `interned` |
| Structs, `Vec<T>` of scalars, nullable | copied; nested fields by leaf | `copies`, `nullableCopies`, `nullableScalars`, `structResultNested` |
| A TS typed array result (`Float32Array`, `Int32Array`, … the nine classes), nullable | copied into a new array of the same class over a copy of its whole buffer, `byteOffset` and `length` kept; the call throws when the array is still held on the wasm side, when its `ArrayBuffer` is held by another view, or when its class extends the declared one. A typed array parameter takes a `Span<T>`, which a typed array passes to | `typedArrayResults`, `typedArrayMisuse` |
| `Span<T>` | lent for the call; a writable Span is copied back; two views of one array share one copy | `spans`, `spanOverlap`, `spanLendResize`, `scratchArena` |
| Callbacks | lent for the call; one the wasm side keeps (any use but a direct call of it, through helpers too) stays callable until the wasm side drops its last reference, which frees its JS slot; called while a `Span` copy is live it throws | `callback*`, `keptCallback*`, `closureEnvDestroy` |
| A callback's `Span<T>` parameter | a typed array over wasm memory for the call, so a write lands in place, also one made before a throw, and two Spans of one Vec see each other's writes; a `Span<boolean>` is a copy written back after the call, two of them sharing one copy; a boundary call while it is open throws | `spanCallback`, `callbackSpanViews`, `spanOverlap`, `spanReentry`, `exportsHeap`, `typedSet` |
| `ref`, `out` and `sink` parameters | `ref`/`out` of a number, bool, exported enum, string or struct of those (nullable too): copied in from the caller's variable and written back after the call and when it throws; refused beside a callback, and at the call when two arguments reach one variable or one names an element a `Span` argument views; a kept callback called during the call throws. `sink` of a string, struct or `Vec`: the adopted copy is moved into the parameter. A `ref`/`out` `Vec`, `Span`, `Handle` or callback and a callback's own mode are refused naming the mode | `refOutScalars`, `refOutStructs`, `sinkCopies`, `refAliased`, `keptCallbackDuringRef`, `refForeign`, `refusedModes` |
| Errors | a JS throw in a callback reaches the JS caller as the same object; a wasm throw reaches it as an Error; a trap ends the instance and every later call says so | `callbackThrow*`, `spanThrow`, `handleTrap` |
| Owner `Handle<T>` of an exported class | wasm owns it, JS holds a counted reference: `release`, `retain`, `[Symbol.dispose]`; a release while a call lends it waits for that call. The JS side reaches the object as `h.value().member`: a method call and a getter or setter run in wasm on the handle, a read or write of a number, boolean or enum field is done by the JS side in wasm memory, and any other field goes through a call; `h.value()` used any other way, and a write or method call through a copied struct or `Vec` field, are refused. `Handle.retain(new C(…))` written on the JS side builds the object in wasm; any other `Handle.retain`, `Handle.borrow` or `Handle.at` of the class there is refused, so a `Handle<C>` on the JS side always holds a wasm object | `handleBasic`, `handleRetain`, `handleMisuse`, `handleDestroy`, `handleMembers`, `handleMemberRelease`, `handleFieldKinds`, `handleFieldMisuse`, `handleConstruct`, `refusedHandleRead`, `refusedHandleCopyWrite`, `refusedHandleMake` |
| `Handle<VecBox<T>>.view(f)` | a Span over wasm memory, no copy, only inside `f`; a boundary call while it is open throws (it could grow memory) | `handleView*`, `refusedKeptView*` |
| Classes, unions, arrays, functions, module state shared by both halves | refused with a named reason at the declaration | `refused*` |

The enum row was measured 2026-11-09 on m1m with a candidate of `wt/js-wasm-one-program` (base
64cc68a8a1f): `wasmmix: 11/11 pass`, `enumCrossing` among them on C, JS, mixed, the foreign caller
and Chrome (a `uint8`, a `uint16` and a negative `int32` enum; a nullable struct field; a callback
result). Not measured: a `Vec` or `Span` of an enum, an `extern enum`, `--danger`.

The kept callback row was measured 2026-11-09 on m1m with a candidate of `wt/js-wasm-one-program`
(base 06957a98188): `wasmmix: 16/16 pass` on C, JS and mixed, `keptCallback*` red on the installed
compiler cc97a2f5818 (refused). 70000 kept callbacks replaced one by one stay within the 65536-slot
table, directly and through an owning object; a handler that drops itself mid-call returns cleanly.
The release rides on a closure environment's destroy, pinned by `closureEnvDestroy` (columns c and
mixed): clearing or replacing a stored closure runs the `onDestroy` of a struct and of a class it
captured at that moment on the wasm half; JS runs no hooks. The bench on the same base: `accept.mjs`
exit 0, `callback 1k` 6.797 us against the baseline's 6.7-6.82, because a lent callback's glue is
emitted unchanged. Not measured: a kept callback in `--danger`, one held only by a JS-to-wasm cycle
(reported as a leak).

The `ref`/`out`/`sink` row was measured 2026-11-09 on m1m with a candidate of `wt/js-wasm-one-program`
(base 9904cc564d4, tip 044a13c5cc0): `WASMMIX_BROWSER=1 check.sh` passed 91 of the 91 programs in the
tree on C, JS, mixed, the tree build and Chrome (its other 3 FAILs are deleted programs m1m still holds),
units 187/187; the seven new programs are red on the installed compiler cc97a2f5818 (`wasmmix: 0/7
pass`, refused as having no boundary form). A write before a `throw` reaches the caller on every
column (`caught boom after the writes: 5 2 text written`), an `out` parameter whose callee throws
before writing leaves the caller's value (`caught boom before the write: 3`), and the adopted copy of
a `sink` string is moved into the parameter with no incref in the wasm entry's C. Not measured:
`--release`/`--danger`, a `ref` of a generic struct, a Node host other than m1m's.

The member row was measured 2026-11-10 on m1m with a candidate of `wt/js-wasm-one-program` (base
dcdd70aad13): `WASMMIX_BROWSER=1 check.sh` passed all 95 programs of the tree on C, JS, mixed, the
tree build and Chrome (its other 3 FAILs are deleted programs m1m still holds), units 190/190; the
three member programs are red on the installed compiler 60ecbc206ed (`wasmmix: 0/3 pass`, refused as
reading a wasm-owned handle). `handleMembers` runs a method, a getter and setter, field reads and
writes (`=`, `+=`, `++`, a struct field), a callback parameter, and a method named `release`, which
stays the class's method and not the handle's. Not measured: an overloaded or inherited method, a
member of a class two placed modules export, `--release`/`--danger`, and members for a foreign JS
caller, which still gets only `release`, `retain` and `[Symbol.dispose]`.

The constructor and the direct member calls were measured 2026-11-10 on m1m with a candidate of
`wt/js-wasm-one-program` (base f0d98fca7d4): `WASMMIX_BROWSER=1 check.sh` passed all 97 programs
of the tree on C, JS, mixed, the tree build and Chrome (its other 3 FAILs are deleted programs m1m
still holds), units 192/192; `handleConstruct` and `refusedHandleMake` are red on the installed
compiler 60ecbc206ed. `handleConstruct` builds a `Counter` with a default argument and with both,
passes it to a `@wasm` function that reads it, and keeps a plain `new Counter(…)` on the JS side,
which stays a JS object and prints the same. Not measured: an overloaded constructor, a generic
class, a constructor with a callback parameter.

The one-flag entry, the borrowed receiver, the struct result slots and the direct field access were
measured 2026-11-12 on m1m with a candidate of `wt/js-wasm-one-program` (compiler sources as landed on
main `f380b4503b95` plus the field access): `WASMMIX_BROWSER=1 check.sh` passed 100 of the 100
tracked programs on C, JS, mixed, the tree build and Chrome, units 80, 32, 44, 7, 7, 9, 4 and 11.
`handleFieldKinds` reads and writes an `int8` to `uint64`, a `float32`, a `float64`, a `boolean` and
two enums of a wasm-owned object, also after a 3000000-element `Vec<float64>` grew wasm memory;
`handleFieldMisuse` reads and writes a field after the last release and gets `use of Handle<Counter>
created at … after release`; `handleMemberRelease` releases the handle from a callback during a
method of it and the object is destroyed when that method returns; `structResultNested` takes a
struct result inside the callback of another call that returns one. Not measured: an inherited
field, a field of a generic class, `--release`/`--danger` for these four programs.

Dev builds (default mode) add: argument type checks on the functions the entry re-exports, and
the site in handle messages (`use of Handle<Counter> created at core.ms:8 after release`); at exit
they print `msb leak: … never released` for every handle and kept callback still held, and `MSB_LEAKS=error` turns
that into exit code 1 (an exit code the program set is kept). Release and danger builds keep the
three handle checks and drop the site.

## Decisions and rejected paths

- **A function marker, not a module directive.** The 2026-10-04 survey proposed `@wasm();` at
  module scope; the person rejected marking a whole file (2026-10-30), so `@wasm` marks an
  exported function and its callees follow it through the child build's dead-code elimination.
  The old statement is refused with a pointer to the function marker. Module state reached from
  both halves is refused (`refusedSharedState`), because each half would hold its own copy.
- **A module's top-level code runs on the JS side only** (2026-11-13). The JS prelude calls the
  wasm half's `MsMain()`, which runs every alive module's `__Init000`, and the child build rooted
  every top-level statement, so a `console.log` at the top of a module with `@wasm` functions, or of
  a helper module it imports, printed twice. The child now gets `--wasm-half`: before transform it
  drops each user module's top-level code (`placement.ms` `withoutJsSideCode`) and the initializer
  of each module variable that no code it keeps names (`withoutUnreadInitializers`); the alive set
  then stops the build with an internal error if wasm-placed code reaches such a variable anyway,
  because a dropped initializer would read as zero. The checker already keeps top-level code from
  touching state that wasm-placed code uses (`refuseJsSideHit`), so dropping it changes no wasm
  result. Pin `wasmmix/programs/topLevelOnce`: on main's compiler mixed printed `helper ready`,
  `unread initialized`, `placed ready` twice; with the fix all four columns print each once, and
  the full `check.sh` reads `wasmmix: 103/103 pass` (m1m, 2026-11-13). An initializer that
  wasm-placed code reads still ran on both halves then; the next bullet closes that.
- **An initializer wasm-placed code reads runs once, in wasm, where its declaration stands**
  (2026-11-13). Calling a module's whole `__Init000` from its JS body would still run `helper base`
  before `helper a` when top-level statements and initializers interleave, so the unit is the
  declaration: a module variable, a static field or a destructuring whose initializer calls,
  constructs or reads a variable (`initOnce.ms` `runsCode`). The JS build reaches from the `@wasm`
  functions and the handle classes through names, `new` and the initializers it reaches
  (`planInitThunks`); each declaration reached gets a thunk `msbInit<n>`, an ordinary `@wasm`
  function the wasm half appends to the module's source (`--wasm-half=<plan>`), checks and wraps,
  with the initializer moved into its body after checking. The JS initializer becomes a call to the
  thunk's wrapper, so it runs at its place in the JS init order, which is the all-C order; it
  returns the value when JS-side code reads it too, through the result forms every `@wasm` function
  has (a getter per name for a destructuring). The wasm half drops every other initializer that
  runs code, and the alive-set check still stops the build if wasm-placed code reaches one. An
  initializer of literals stays in both halves. Pin `wasmmix/programs/initOnce` (interleaved
  prints, a static field, a destructuring, a block, `Math.random()`): red on the previous
  compiler (mixed printed `helper base` first), green on the candidate, and the full `check.sh`
  reads `wasmmix: 104/104 pass` (m1m, 2026-11-13); the probe of a random constant prints
  `same true`, where it printed `same false`. Not measured: the startup cost of one boundary call
  per moved initializer.
- **The entry module can hold `@wasm` functions** (2026-11-13). It was refused because its
  top-level code would run again in wasm; the wasm half now drops every user module's top-level
  code and moves the initializers wasm code reads into thunks (the two bullets above), the entry
  included, so the refusal had no reason left. Pin `wasmmix/programs/entryPlaced` (top-level
  prints around two `@wasm` functions in `main.ms`, one reading an initializer that prints):
  refused on the previous compiler in the mixed and tree columns, the same output as all-C in
  c, js, mixed and tree on the candidate (m1m, 2026-11-13). A lazily imported module stays refused.
- **The JS side runs the wasm half's event loop** (2026-11-18). A timer or a promise callback
  wasm-placed code schedules sits in the Emscripten dispatcher (`runtime/promise/dispatchEmcc.c`),
  which an emcc program drains itself by sleeping through JSPI; the wasm half is a library whose
  host is the JS prelude, so it linked JSPI and failed to load on Node 24 (`WebAssembly.Suspending
  is not a constructor`) as soon as a `@wasm` function called `setTimeout`. The half is now built
  with `MSOS_HOST_PUMPED` and without JSPI: the dispatcher calls the import `msb_wake` when its
  callback queue stops being empty (a microtask) or a timer becomes the earliest (a `setTimeout`),
  and the host calls the export `msb_pump`, which runs callbacks, due timers and callbacks again,
  the order of the all-C drain, and returns when to come back. This is wasm-bindgen's executor
  (one `queueMicrotask` per non-empty queue, `crates/js-sys/src/futures/queue.rs`, 706a03dc) with
  timers added. A synchronous wait that the queue cannot finish in wasm-placed code aborts with
  `... cannot finish: the JS side runs the event loop only between boundary calls, so await the
  value instead` (not pinned). Pin `wasmmix/programs/timersInWasm` (a timeout, a zero timeout, an
  interval cleared after three ticks, a `then`): red on the previous compiler in mixed and tree
  (the load error), the all-C order in all four columns on the candidate, full `check.sh`
  `wasmmix: 106/106 pass` (this Mac, 2026-11-18). Not measured: the order of a wasm timer against
  a JS-side timer with the same deadline, which the all-C program keeps in one heap.
- **Copies by default; zero copy only through a view.** A writable Span copied back measured
  2680 ns for 1000 floats where a view measured 1090 (table below), so views exist; a view is
  only safe because nothing can grow memory while it is open, which is enforced at runtime by the
  same counter that refuses re-entry while a Span is lent to a callback.
- **A callback's Span is a view of wasm memory, not a copy** (2026-11-09). The callback cannot
  call a wasm function while it holds one, as under `view(f)`, so no call grows memory under it;
  it reads and writes the elements the all-C program's callback would, and the copy into a JS
  `Array` and the copy back after the call bought nothing. A `Span<boolean>` stays a copy,
  because wasm stores a bool as a byte and the callback must read `true`/`false`. A typed array's
  own store conversion changes no result: the JS backend traps or wraps integer arithmetic before
  the store (`msOverflowI32`, `& 255`, `BigInt.asUintN` in the emitted code; a `--danger` probe
  printed the same wrapped `int32`, `uint8`, `int64` and `uint64` values on C and JS) and rounds a
  float32 with `Math.fround`. A writable float32 callback Span no longer makes the wasm companion
  export `HEAPF32`. A `Handle` released inside the callback or inside `view(f)` still runs its
  destroy at once, as in the all-C program; when that destroy grows wasm memory, a view made
  before it would stop seeing memory (and a slice cut from it too), so the release throws `wasm
  memory grew while a Span view was open, so the view stopped seeing it: …` and the callback's end
  checks again (pin `callbackSpanGrowth`: a 10-element destroy releases and the write lands, a
  20000000-element one throws; the copy glue before this change printed the write instead). Measured on m1m (Apple M1 Pro, Node 24.1.0, headless Chrome
  149.0.7827.114, `--danger`) with a throwaway program, a `@wasm` function calling its callback
  1000 times with the same 1000-element `Span<float32>`: installed msc `cc97a2f5818` (before)
  against a candidate of base `9904cc564d4` (after), five interleaved rounds in a `--quiet 6`
  window (load 10.1 before from outside work, 11.8 after; a row's five medians spread at most 3.4%
  in Node and 6.7% in Chrome).
  Median ns per callback:

  | the callback | Node before → after | Chrome before → after |
  |---|---|---|
  | sums all 1000 (`Readonly<Span>`) | 4439 → 2821 | 4361 → 2822 |
  | scales all 1000 in place (`Span`) | 3483 → 545 | 4123 → 1709 |
  | reads one element | 1664 → 40.8 | 1589 → 41.2 |
  | writes one element | 2860 → 38.4 | 2437 → 37.9 |
- **Two views of one array share one copy**, so a write through either is seen by the other, as
  in the all-C program.
- **A callback error crosses as itself.** The glue records the thrown object, the wasm side
  unwinds with its message, and the export rethrows the original object when the messages match.
  A trap cannot be unwound, so it poisons the instance instead of leaving half-run frames.
- **`Handle<Vec<T>>` cannot exist**: a `Vec` is a value with no heap header to count, and
  `Handle.retain(vec)` does not type-check. The boxed form is the std class `VecBox<T>`, written
  out by the author (decided 2026-11-03). Boxing a `Vec` implicitly would allocate the same heap
  object, so the choice is spelling, not cost.
- **No finalizer** releases a handle: a GC finalizer runs late or never, which is wrong for GPU
  resources and callback environments; the dev leak report names what was never released.
- **A typed array result is a copy only when nothing else can see the original.** A typed array is
  a class instance with an identity, so the wasm side hands it over only when it holds the sole
  reference to the array and to its `ArrayBuffer` and the instance is of the declared class;
  otherwise the call throws naming `Float32Array.from(x)`, because a copy would split one object
  into two that stop seeing each other's writes. Measured 2026-11-08 on m1m (Node): a `makeVec`
  of 1000 written through a `Span` of the array returns in 0.69 us against wasm-bindgen's 0.89;
  written through `out[i]` it takes 1.28 us, the typed array subscript's own cost in std.
- **A kept callback is freed by the wasm side's destroy, not by JS.** The wasm closure built for a
  kept parameter captures a small owner object whose `onDestroy` frees the JS slot, so the slot
  lives exactly as long as the last wasm reference to the closure, as a closure environment's
  captured values do in the reference's ARC (`nimDestroyAndDispose` on the last environment
  reference). The owner is a class (`MsbKept`), not a struct, because a moved-from struct copy is
  destroyed too, with zero fields (LANG.md: "A struct `onDestroy` hook must tolerate a zeroed,
  moved-from value"), and a copied owner would free the slot
  twice. Whether a parameter is kept is decided the safe way round: it is lent only when every
  use calls it or passes it to a direct callee that only calls it, because a keep the analysis
  missed would fail at run time while a lent callback taken as kept only costs one allocation. The
  compile-time refusal it replaced searched for a keep instead and missed two: a store into a field
  of a fresh local object later stored (`const l = new Listener(); l.visit = cb; owner = l`) and a
  push into a fresh local array later stored; the actor borrow check shares that search (inbox card
  `2026-10-26-a-call-receiver-writes-returns-or-outlives-its-borrowed-argument.md`).
- **A wasm-owned object is released by the author, not at scope end, on the JS side** (traced
  2026-11-10). The JS half has no destroy, and no reference supplies one for a class on a GC host:
  Nim's JS backend never runs a `ref object`'s `=destroy`, and runs a value object's only for a
  local, not for one in a `seq` (probe with `nim js`, Nim 2.2.2); wasm-bindgen asks for `free()`,
  offers `[Symbol.dispose]` for TS `using`, and adds a `FinalizationRegistry` backstop. Releasing
  at scope end as the all-C program does would mean counting every JS-side place a wasm object can
  be stored. So `Handle.retain(new C(…))` builds it, `release()` or `defer h.release()` frees it,
  and the dev leak report names what was never released. That the JS backend runs no struct
  `onDestroy` while Nim's JS backend does is on compiler card
  `2026-11-10-js-backend-runs-no-struct-ondestroy-where-nim-js-does`.
- **A member call is a direct call of its wrapper.** The compiler rewrites `h.value().m(…)`,
  `h.value().f` and `h.value().f = v` (as a statement) on the JS side into one call of the
  member's wrapper, as wasm-bindgen's class method calls one shim; a compound assignment or `++`
  goes through a proxy object that `value()` returns, one call per read and per write. A handle
  argument of a call that runs no JS (no callback parameter, no kept callback in the program) is
  only checked live, through the wasm pointer kept on the handle and zeroed at its release, as
  wasm-bindgen keeps `__wbg_ptr`; with a callback it is lent, so a release from the callback waits
  (RT-48). Measured on m1m 2026-11-10 (not quiet, 5 rounds): `method x1000` 20.11 → 3.84 ns per call on
  Node (wasm-bindgen 12.97), `field x1000` 20.31 → 3.92 (wasm-bindgen 2.85); in Chrome 4.19 and 4.40
  against 4.47 and 4.27.
- **The checks stay; the time was in two places** (2026-11-12). Removing the dead-instance test,
  the `try` that poisons, the `dirty` test or the handle's liveness test one at a time moved no
  row, and removing all of them 0.05 to 0.07 ns (`src/bench/wasmBoundary/baseline.md`, 2026-11-12,
  hand-edited glue). The time was `__msb.enter()` as a method call testing a closure variable, now
  `if (__msb.lent !== 0) __msb.enter()` with `die` making `lent` `Infinity` so one field carries
  both the open views and the dead instance; and the member entry counting its receiver up and
  down. The entry now reads the receiver as a `Cursor<C>`: the JS handle's own count spans the
  call, because either no JS runs during it or a release is deferred to its end (RT-48).
- **The trap guard stays** (2026-11-13). Without the `try` that ends the instance on a trap, a JS
  caller that catches a trap thrown in the middle of an update and calls again reads a wrong total
  that nothing reports (probe: 90 for 100); the all-C program dies at the trap. Measured on m1m
  with the bench bundle of main 27db20347291's compiler hand-edited, 5 Node and 3 Chrome rounds
  interleaved, medians in ns for the guard / a call counter instead / no guard: `add x1000` 2.84 /
  5.52 / 2.75 on Node and 3.16 / 5.45 / 2.98 in Chrome; `mid x1000` 5.23 / 10.03 / 9.51 and 5.62 /
  9.52 / 8.96; `method x1000` 3.14 / 5.57 / 3.16 on Node; the other rows equal. The guard costs at
  most 0.2 ns a call. Why the bundle without the `try` is slower on `mid` is not explained. The
  host was not quiet (load 9.75 at the start, 2.8 at the end), so the rows compare with each other,
  not with other tables.
- **A struct result of scalar leaves is read from a slot, not handed to an import.** The wrapper
  takes `8 * leaves` bytes from the glue's scratch arena, passes the address first, the entry stores
  each leaf in its 8-byte slot (`msbPut_<letters>`) and the wrapper reads them from the Emscripten
  heap views after the call, as wasm-bindgen passes a `retptr` taken from the wasm stack
  (`crates/cli-support/src/js/binding.rs`, `__wbindgen_add_to_stack_pointer`, 706a03d). A slot per
  call, not one static area, because a callback of the call may call another function that returns
  a struct. `mid x1000` went from 53 to 5.1 ns on Node and from 58.6 to 5.7 in Chrome. A struct
  with a string leaf keeps the import, because the string must be decoded while the wasm side
  still holds it; a `ref`/`out` write-back keeps it too (not measured). A conversion that throws
  on the JS side now throws after wasm returned, so it no longer ends the instance.
- **A number, boolean or enum field of a wasm-owned object is read and written by the JS side.**
  The wrapper keeps the flag test and the liveness test, asks the wasm half once for the field's
  offset (the entry is `@emit` of `&${self.f}` minus the object's address, so the C compiler
  answers and an inherited or reordered field cannot be guessed wrong) and then indexes the
  Emscripten heap view of the field's type, which Emscripten replaces when memory grows.
  `offsetOfField` (`src/checker/types.ms`) answers for structs only, which is why the offset is
  asked and not computed. `field x1000` went from 3.2 to 1.44 ns on Node (wasm-bindgen 3.23, and
  2.85 at its best) and from 3.86 to 1.30 in Chrome (4.46). A string, struct or nullable field
  stays a call.
- **A release while a call lends the handle is deferred to the end of that call**, a deliberate
  divergence recorded as `paper/NIM-REF.md` RT-48.
- **A `ref` or `out` parameter is a copy written back, through the result takers.** Wasm cannot
  address the caller's JS variable, so the wasm export copies the value into a local passed by
  reference and hands it back through the `msb_rs_*` import a struct result with a string leaf uses, after the
  call and in its `catch`, before the result; the JS glue writes it to the `[object, key]` pair the
  JS backend passes for a `ref` argument. Two arguments that reach one variable are refused at the
  call rather than shared, because the all-C program writes one variable through both (`f(x, x)`
  prints `2` on C and JS where two copies print `1`); a struct or `Vec` argument beside a `ref` of
  its field needs no check, because the JS callee copies it on entry as the wasm side does. A
  `ref`/`out` `Vec` is refused although `let b = a` before the call copies on C and JS alike
  (probe 2026-11-09: `7,2,9 | 1,2 | 1,2` on both), because no program needed its copy-back yet.

- **Glue changes measured and rejected** (m1m, real bench, 3 interleaved runs, 2026-11-07/08):
  caching heap views, `malloc` and exports in locals (no row faster, strLen 8% slower); a string
  result through a kept wasm-side slot instead of an import (echo 148 against 144 ns, and it broke
  `resultThrowPoison`); building the adopted Vec by spread or by an indexed copy after presizing
  (sumVec unchanged: the cost was the second block, removed by adopting the payload); caching
  `Module["msb"]` in the wasm loader and one shared string taker instead of a closure per call
  (echo 121.0 against 121.1 and 118.5). Echo's remaining cost is the JS-side `malloc`, the wasm
  free, and the copy a function makes when it returns its borrowed parameter.
  A typed array result (m1m probe, Node 24.1.0 and Chrome 149, 5 interleaved rounds, 2026-11-08)
  stays `new C(HEAPU8.slice(p, p + n).buffer, o, k)`: wasm-bindgen's `new C(HEAPU8.buffer, p + o,
  k).slice()` measured the same at 1000 floats (Chrome 0.60-0.64 us both, Node 0.51-0.55) and only
  cut the fixed cost of an empty array (Chrome 0.21 to 0.10 us, Node 0.14 to 0.096), while it hands
  a subarray result a buffer of its own length at offset 0 instead of the shape JS gives it;
  `ArrayBuffer.prototype.slice` measured slower on both (empty 0.28 and 0.26 us).
  A wrapper that holds its wasm export in a closure, `const name = ((wasm) => function name(…) {
  … wasm(…) … })(__msbMod._export)` (m1m, 2026-11-12, `baseline.md` of that day): on Node `add`
  2.88 to 2.71 ns and `method` 3.17 to 3.07, which is what stands between `add` and wasm-bindgen
  there; in Chrome 149 `mid` 5.67 to 9.0 ns with every wrapper in that form, and `add` 3.15 to 3.26
  and `add64` 4.24 to 4.42 with only the wrappers that have no cleanup. No variant left every row
  as fast, and the browser is the runtime this ships to, so the wrappers stay function
  declarations. Such a `const` is also not hoisted: the wrappers would have to follow the prelude,
  because a placed module that initialises a constant from its own `@wasm` function at top level
  (pin `wasmModuleTopLevel`) otherwise reads the wrapper before it exists. Not explained: why
  Chrome slows `mid`.
- **No zero-copy path for JS-owned data.** Wasm cannot address a JS `ArrayBuffer`, so a `Span` of
  JS data is copied in and back, as wasm-bindgen's `&mut [f32]` glue does; data the wasm side
  holds is shared without a copy through `Handle<VecBox<T>>` (bench row `scaleBox`).

## Is it still green

Two checks answer it, both outside the land gate and the core tests, run on a host with Emscripten:

- **Correct:** `src/test/wasmmix/check.sh` runs every wasm boundary unit test and every wasmmix
  program in all its columns; `WASMMIX_BROWSER=1 CHROME=<path>` adds headless Chrome. It ends with
  `js-wasm check: GREEN` and exit 0. 2026-11-12 on m1m with `WASMMIX_BROWSER=1`, a candidate of `wt/js-wasm-one-program`: 100/100 tracked programs, units green. 2026-11-09 on m1m with `WASMMIX_BROWSER=1`: main
  `379c2cb440b` units 188/188 and wasmmix 93/93. A `run-remote.sh` directory on a host keeps files
  deleted from the tree, so a program removed since that directory's first run is built there and
  fails (`refusedEnum`, `refusedKeptCallback*` on m1m); count the programs of the tree, and read a
  red there against `git ls-files`.
- **Fast enough:** `CHROME=<path> src/bench/run.sh wasmBoundary` then `node src/bench/wasmBoundary/accept.mjs`
  times the same rows in MetaScript and wasm-bindgen on Node and in headless Chrome, and prints which
  rows meet wasm-bindgen on the same runtime (exit 0 when all do); neon-bindings, a native Node-only
  addon, is a reference column, not the bar (the person, 2026-11-08). Recipe, arms and the recorded
  table: `src/bench/wasmBoundary/baseline.md`; its 2026-11-08 ship baseline reads 11 of 12 rows on Node,
  the twelfth (`primes`, wasm code rather than the boundary) parked on a compiler card, and 12 of 12
  in Chrome; its 2026-11-12 table, with the `x1000` rows warmed, reads 13 of 15 on Node (`add x1000`
  13% above, `primes` parked) and 15 of 15 in Chrome, and says which wasm-bindgen rows depend on
  the row's shape.

## Measurements

Boundary cost, 2026-11-03, m1m (Apple M1), node 24.1, Emscripten 5.0.5, `--danger`, tree
`47acdbe353ec5d54c942752bfd612023e140423a`; median of 7 timed runs after 3 warmups, three runs
agreeing within 10%. ns per call; JS is the same program built with `--wasm-placement=off`; neon is
a neon-bindings 1.x (N-API) addon with the same functions in Rust, release with LTO, on the same
machine, given a `Float32Array` where ours takes a `Vec<float32>`.

| call | JS | mixed | mixed after | neon |
|---|---|---|---|---|
| `add(int32, int32)` | 0.5 | 2.8 | 3.0 | 49 |
| `add64(int64, int64)` | 14.7 | 16.1 | 17.0 | 70 |
| `strLen(16-char string)` | 6.3 | 101 | 44.7 | 78 |
| `echo(16-char string)` | 0.5 | 297 | 155 | 93 |
| `mid(struct {x, y})` | 0.9 | 90 | 55 | 440 |
| `sumVec(Vec of 1000 float32)` | 3100 | 3340 | 2701 | 60000 |
| `sumSpan(Span of 1000 float32)` | 2680 | 2205 | 1541 | 1090 |
| `scaleSpan(writable Span of 1000)` | 635 | 2680 | 2709 | 162 |
| `view` of 1000 float32, scaled in JS | 668 | 1090 | — | — |
| `makeVec(1000)` result | 3270 | 2550 | 2576 | 1330 |
| 1000 callbacks in one call | 420 | 11060 | 11736 | 56300 |
| `primes(2000000)` sieve | 19.6 ms | 5.7 ms | 5.86 ms | 4.1 ms |

"mixed after" is tree `d132af374ab58b513efbf36134dd75ced160970b` (the glue fast paths: ASCII string encode
and decode, result imports without rest parameters, one typed `set` for a whole array, Span copy
loops moved out of `try`), measured interleaved against its parent in one job (median of 5);
`scaleSpan` moved 3185 → 2709 in that pairing, the host ran slower than the first column's run.
Three gaps are the bench, not the boundary: a `Vec<float32>` is a JS `Array` while neon is handed
a `Float32Array` (with a `Float32Array` input `sumSpan` measured 1073 against neon's 1090); neon's
`makeVec` returns a `Float32Array`; the Rust sieve presizes with `vec![true; n]` while ours pushes
2M times (presized, the wasm half runs 4.45 ms, and it equals the native C build, 5.79 ms against
5.85 ms unpresized). Emscripten flags (`-O2`, `-flto`, `-msimd128`, emmalloc, no memory growth)
moved the sieve under 1%; the earlier `-msimd128` probe cut the `scaleSpan` wasm loop 434 → 105 ns.
An earlier one-export sieve ran at 8.8 ms against 5.85 ms with the full export list;
the array-growth trace below resolves that cliff.

The MetaScript bench is `src/bench/wasmBoundary/main.ms` and `benchWasm.ms`; the neon crate
`lib.rs`/`bench.mjs` remains outside the repo (m1m `~/neonbench`). Not measured: browsers,
Windows since these changes, the browser column of the oracle.

Fixed SIMD, 2026-11-05, m1m, Node, Emscripten, `--danger`: source tree
`f6b1c221ec1f182946426b6188950cb5aba6697e` (the retained bench differs only in whitespace and
an import trailing comma). Build control/candidate compilers with `--danger --lto=off`, then
`build src/bench/wasmBoundary/main.ms --target=js --danger --output=<arm>/main.mjs` and run
`node <arm>/main.mjs`: three alternating control/candidate pairs, each median of seven timed
runs after three warmups. `scaleSpan1k` medians **2704.0 → 2370.6 ns** (12.3% faster); all three
pairs improved. Sum, callback and sieve rows showed no consistent improvement. The disassembly
pin reported `control no f32x4.mul; candidate f32x4.mul present`; wasm grew **27490 → 27656 bytes**.
The candidate reported `wasmmix: 74/74 pass` and 256 passing boundary-unit tests. These prove
fixed SIMD code generation and existing Node oracles, not browser support, GPU output, other
hosts or rebased-main integration. No relaxed SIMD or fast-math. Full raw evidence:
m1m `~/work/rr-recompiler-441c019f/out/simd-proof/`.

Array-growth cliff, 2026-11-05, m1m, Node 24.1.0, emcc 5.0.5, Binaryen 129 (`0bb686f83`).
The single-export arm isolates `primes` from the same bench into its own module; no kernel
changes. Three alternating seven-arm rounds, each median of seven batches of ten calls after
three warmup batches; every call asserted 148933 primes. Probe medians, ms/call:

| single | full exports | single + keep table | noinline only | LTO | keep + LTO | keep + noinline + LTO |
|---|---|---|---|---|---|---|
| 8.746 | 5.912 | 5.899 | 8.737 | 7.069 | 9.094 | 6.048 |

The root is optimizer shape, not array growth or ownership. Binaryen `0bb686f83`
`src/passes/Inlining.cpp:157–158` inlines a single-reference function aggressively;
`:230–232` counts function-address references too. The named-symbol trace and timed wasm
have different whole-file hashes, but their prime bodies match after ignoring only function
and call indices: **1558 WAT lines/21 locals → 176/8**, replacing the inlined allocation/growth
body with one helper call. The LTO trace also exposes an allocation branch inside the hot loop;
the Emscripten-only `noinline` keeps it behind the growth helper. These are emitted-code
constraints, not a change to the algorithm in `msArrayPrepareAdd`.

Production source tree `84d3c1eef183d6e7a24a9d8734607e920c77e4e6`, three paired runs:
single-export **8.692 → 5.880 ms** (32.35% faster), wasm **18182 → 18311 bytes**; full bench
**27656 → 27708 bytes**. Scalar-only probe: **9323 → 9526 bytes**, same result 5. That small
retention cost is paid even when the boundary exposes no arrays. Full-bench callback median
was 2.08% slower with noisy opposite-direction pairs; no callback gain is claimed. Generator
pins failed twice on the control, then reported `Tests 30 passed (30)`; six named wasmmix
consumers reported `wasmmix: 6/6 pass`. This is not a new 74-program sweep or browser/GPU
certificate. LTO rows above are probes rebuilding the generated half with explicit `-flto`
at compile and link, not evidence that the parent CLI's LTO option reaches it. Raw artifacts:
m1m `~/work/rr-recompiler-441c019f/out/r9-proof/`, `r9-trace/`, and `r9-fixed/`.

LTO option flow, 2026-11-05, same m1m/Node/emcc toolchain, source tree
`0a473950c980c4226b6c817df62fc72cb8eb0cd4`: actual parent CLI builds, not manually rebuilt
halves, using `build src/bench/wasmBoundary/main.ms --target=js --danger --lto=<strategy>`.
The unwritten default matched thin; explicit off and full produced distinct artifacts. Three
interleaved rounds, medians of the bench's per-process medians:

| | off | thin | full |
|---|---|---|---|
| wasm bytes | 27708 | 30395 | 30146 |
| callback1k, ns | 11565.3 | 6885.9 | 6930.3 |
| primes2M, ms | 5.689 | 5.953 | 5.941 |

Thin made this callback workload 40.5% faster, with 9.7% larger wasm and a 4.6% slower sieve;
full had the same broad trade-off. These are three rounds on one host, not a universal speed
claim. The driver uses the existing compiler policy and `--lto=off` remains the opt-out;
see `src/compiler/cc.ms` `cliCompileFlags` and `wasmBoundary/placementBuild.ms` `wasmHalfOptions`.
Compile/link option assembly follows Nim `15dd34468` `compiler/extccomp.nim:494–546`;
no ownership or growth-policy change was needed.

The control failed the emcc strategy and child-forwarding pins; the candidate reported 170
passing unit tests. Each of thin/full passed 14 Danger consumer programs and the original
bounds-trap program at Debug. `compile.ms` `nativeCtx.boundChecks` explains why that program's
out-of-range read is not a trap oracle under Danger: the Danger/off control also did not trap.
`src/test/wasmmix/programs/trapPoison` instead forces an engine trap independently of bounds
checks. It passed both optimized strategies and its default mixed cell; disabling `die` made
`blocked` and `cause` false, so the oracle rejects a missing poison guard. Its retained sources
differ from the optimized-run inputs only in whitespace. No full suite, browser/GPU or
rebased-main integration was certified. Raw m1m artifacts under the same work dir:
`out/lto-fixed/`, `out/lto-remaining/`, `out/lto-final/`.

Child build options, 2026-11-05, m1m/Node 24.1.0/emcc 5.0.5, checked tree
`c3411bdcc7b62a8cdb97b4d3b9b696057d1710c4`: the old parent CLI's
`-d:probeMarker` printed `0` from the wasm half rather than `1`, and
`--passL=-sMSB_DELIBERATELY_INVALID_SETTING=1` incorrectly succeeded. The corrected actual
CLI rejected that setting with emcc's `Attempt to set a non-existent setting`; a valid
`--passL=-sASSERTIONS=1` plus `-d:label=CLI=x with space λ` printed exactly
`15 / CLI=x with space λ / true / true` (four lines). The retained `childOptions` mixed
program also checks project-config defines and project identity against the parent while
observing the child's own C/emcc, not JS, target facts. Owner pins changed from five expected
failures and two passes to seven passes; `WASMMIX_ONLY=childOptions,scalars` reported `2/2 pass`.

The distinction reuses `defines.ms` `isOptionDefine`, rather than forwarding the parent's
whole target table. Reference anchors: Nim `15dd34468` `compiler/condsyms.nim` `defineSymbol`
and `initDefines`, `compiler/commands.nim:767–775` define parsing, and
`compiler/extccomp.nim` `getLinkOptions`. The source contract is in `placementBuild.ms`
`wasmHalfOptions`. Raw m1m artifacts: `out/m5-flags-green/`; executable SHA256
`ba9735ac6418ff2352f8217bbfc00add3bf36ae5168c496b94af911e40e71d67`.
This proves option propagation, not a returning browser lifecycle, a Void build, WebGPU/
WebGL2 screenshots or M5 completion. The verification recipe's final hash glob encountered
a generated directory after all assertions passed; explicit-file hashes subsequently matched
without rerunning the product checks.

Callback-specialization reassessment, 2026-11-05: inspected the checked R8 tree
`1fafa1c260a74e86fbd2fc9763fe8bf0473a15a3` benchmark's wasm with `wasm-dis` from the same
emcc SDK. The companion maps `_msb_benchWasm_each` to export `D`, function `$37`; its loop
calls `$fimport$14` directly, which the import table maps to `msb_cb_i_i`. All three remaining
`call_indirect` sites in that function are outside every loop. The audited wasm has the same
`cf4729b1…` SHA256 recorded below. Raw proof: m1m `out/r8-green/r7-direct-loop-proof.txt`
and `callback-export.wat`.

The old specialization experiment targeted the closure-thunk/indirect hop in this hot loop.
Existing thin LTO has already removed it, consistent with the measured callback reduction
from 11.57 to 6.89 ns per callback above. Adding a compiler specializer solely to reproduce
that result would duplicate existing work. This is a finding about this benchmark, not proof
that every recursive, multi-callback or nested callback shape is devirtualized. Reopen that
optimization when a named real-consumer hot loop still contains the indirect hop under the
chosen LTO strategy; no callback registry, generation check or failure guard was removed.

Result-import wrapper check, 2026-11-05, m1m/Node 24.1.0/emcc 5.0.5, tree
`1fafa1c260a74e86fbd2fc9763fe8bf0473a15a3`: three interleaved rounds of the real generated
`src/bench/wasmBoundary/main.ms` bundle, built with `--target=js --danger` (default thin LTO).
Control and candidate wasm were byte-identical, SHA256
`cf4729b17843086ab64944b464e9dcf676fe3959c280d57dc90047f90d2bec1e`.

| ns/call, median of per-process medians | control | candidate |
|---|---|---|
| echo16 | 154.5 | 145.4 |
| mid | 55.6 | 54.4 |
| makeVec1k | 2677.3 | 2655.6 |

All six runs printed `sink true`. Echo improved 5.9%; the Vec difference is too small to
claim a general gain. A preceding same-wasm, emitted-JS three-arm probe found no consistent
extra gain from fixed arity alone. Reusing the existing `ii` parameter path removes the
Vec-specific rest/spread case, rather than adding a new fast path. This is single-host Node
evidence, not a browser or multi-engine result; no confidence interval was established.

`wasmSide.ms` `jsLibraryOf` and `jsSide.ms` `guardedCall` carry the implementation contract.
Four old shape pins failed before the change; the candidate passed all 30 owner pins and six
named consumers. `resultThrowPoison` injects host failures into Vec allocation and long-string
decoding on separate fresh instances. The generated candidate preserved the original error,
poisoned subsequent calls and retained its cause. Removing the enclosing export guards made
both blocked-call oracles false; callback and escape import guards were unchanged. No wire,
ownership or wasm code change was needed. Raw m1m artifacts: `out/r8-probe/`, `out/r8-red/`,
`out/r8-safety/`, `out/r8-green/`. Earlier companion-path and host-admission setup failures
produced no safety verdict; only their missing controls were subsequently run. This does not
certify M5, GPU screenshots, the full suite or integration after a rebase onto current main.

Float32 copy-in, 2026-11-06, m1m/Node 24.1.0/emcc 5.0.5 (SDK `d7b4130`), tested tree
`37b75ef0a7a66d9ae6713d246f9a46fd4a93ec91` (the arc rebased onto main `7228a864969`), candidate
SHA256 `9fbb6c8c52e09f3b8c94e36e8d57e1f214288df499bdfbb378d283ada08b7176`. `jsGlue.ms`
`__msbCopyTo` writes a `Float32Array` span through the SDK's live `HEAPF32` at an element offset,
after an alignment and bounds check, instead of building a fresh view per call; copy-back and Vec
results keep their per-call views, because the prototypes measured them slower with the shared
view. Three interleaved rounds of the real generated `src/bench/wasmBoundary/main.ms` bundle
(`--target=js --danger`, wasm SHA256 `2b7898ca…`); the control is the same bundle with only the
Float32 branch removed from `__msbCopyTo`.

| ns/call, median of per-process medians | plain n=4 | plain n=64 | plain n=1000 | typed n=4 | typed n=64 | typed n=1000 |
|---|---|---|---|---|---|---|
| sum, control → candidate | 59.1 → 42.1 | 142.1 → 130.9 | 1555.5 → 1545.3 | 73.7 → 55.4 | 129.4 → 116.0 | 1090.1 → 1076.8 |
| scale, control → candidate | 101.2 → 74.4 | 184.3 → 164.2 | 1498.2 → 1481.0 | 120.8 → 98.6 | 133.4 → 113.5 | 313.2 → 295.5 |

The candidate was faster in all 12 rows, by 18–29% at n=4 and 1–6% at n=1000. All 12 runs passed
their value, range/alignment, real memory-growth, special-float (`-0`, `NaN`, `±Infinity`) and
sink oracles. Restoring a stale pre-growth `HEAPF32` made the candidate throw, and removing the
bounds guard made the range oracle fail, so the oracles reject both mistakes. The four named
consumers `copies`, `spans`, `spanCopyPaths` and `spanCallback` (the latter now also edits
Float32 spans in a callback) each reported `wasmmix: 1/1 pass`, and each generated companion
assigns `HEAPF32`. The host's 1-minute load average was 16.6 before the rounds, so treat the
small n=1000 differences as noise. This is single-host Node evidence, not a browser result. Raw
m1m artifacts: `out/r3-generated/`.

Earlier transport probe, 2026-10-04 (hand-written Emscripten module, Node 24.18 and Chromium 154):
JS → wasm → JS → wasm re-entry, exact i64 and float32 negative zero, `externref` identity, a
cached memory view detached by growth to 32 MiB, and `TextEncoder` losing a lone surrogate, which
is why strings use the WTF-8 codec instead.

## References consulted

The standard compiler checkout was `dcec8e1cd1a33b3dfa6a9fa38784d0c9195b6aca`:
`compiler/main.nim` `commandCompileToC`/`commandCompileToJS`, `lib/system/platforms.nim`
`CpuPlatform`, the Emscripten branch in `lib/system/osalloc.nim`, and the backend guard in
`lib/js/jsffi.nim`. These are separate whole-program backend paths, not a mixed-program
partitioner.

- [wasm-bindgen design](https://wasm-bindgen.github.io/wasm-bindgen/contributing/design/index.html),
  [closure lifetime](https://wasm-bindgen.github.io/wasm-bindgen/reference/passing-rust-closures-to-js.html):
  generated typed adapters and distinct borrowed/retained lifetimes.
- [wasm-bindgen "JS objects in Rust"](https://wasm-bindgen.github.io/wasm-bindgen/contributing/design/js-objects-in-rust.html):
  a JS value Rust keeps is an owned slot of a slab freed when the `JsValue` drops, the prior art
  for kept callbacks (read 2026-11-09). `Closure` is the other direction, a Rust closure handed to JS.
  Nim at 15dd34468: `compiler/liftdestructors.nim` `atomicClosureOp` and `lib/system/arc.nim`
  `nimDestroyAndDispose`, the environment destroy the release rides on.
- [Emscripten interaction](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/Interacting-with-code.html),
  [Embind](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/embind.html):
  import/export transport, explicit deletion, finalizer limitations, unsafe borrowed views.
- [WIT resources](https://component-model.bytecodealliance.org/design/wit.html#resources):
  own/borrow/drop vocabulary; no Component Model compatibility is claimed.
- [neon-bindings JsBox](https://docs.rs/neon/latest/neon/types/struct.JsBox.html): GC-owned native
  storage, the contrast to the explicit release here; N-API is not a browser transport.
- [AssemblyScript host bindings](https://www.assemblyscript.org/compiler.html#host-bindings),
  [Kotlin/Wasm JS interop](https://kotlinlang.org/docs/wasm-js-interop.html): copied strings and
  arrays, opaque reference-counted objects.
