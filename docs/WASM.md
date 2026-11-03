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
| Numbers, bool, enums | typed scalars; `int64`/`uint64` as BigInt, exact | `scalars`, `enumAsInt`, `wireMatrix` |
| Strings | copied as WTF-8 both ways; lone surrogates, BOM, NUL survive | `strings`, `stringsLong`, `bomStrings`, `decodeWtf8`, `interned` |
| Structs, `Vec<T>` of scalars, nullable | copied; nested fields by leaf | `copies`, `nullableCopies`, `nullableScalars` |
| `Span<T>` | lent for the call; a writable Span is copied back; two views of one array share one copy | `spans`, `spanOverlap`, `spanLendResize`, `scratchArena` |
| Callbacks | lent for the call; one kept past the call is refused at compile time | `callback*`, `refusedKeptCallback*` |
| Errors | a JS throw in a callback reaches the JS caller as the same object; a wasm throw reaches it as an Error; a trap ends the instance and every later call says so | `callbackThrow*`, `spanThrow`, `handleTrap` |
| Owner `Handle<T>` of an exported class | wasm owns it, JS holds a counted reference: `release`, `retain`, `[Symbol.dispose]`; a release while a call lends it waits for that call | `handleBasic`, `handleRetain`, `handleMisuse`, `handleDestroy` |
| `Handle<VecBox<T>>.view(f)` | a Span over wasm memory, no copy, only inside `f`; a boundary call while it is open throws (it could grow memory) | `handleView*`, `refusedKeptView*` |
| Classes, unions, arrays, functions, module state shared by both halves | refused with a named reason at the declaration | `refused*` |

Dev builds (default mode) add: argument type checks on the functions the entry re-exports, and
the site in handle messages (`use of Handle<Counter> created at core.ms:8 after release`); at exit
they print `msb leak: … never released` for every handle still held, and `MSB_LEAKS=error` turns
that into exit code 1 (an exit code the program set is kept). Release and danger builds keep the
three handle checks and drop the site.

## Decisions and rejected paths

- **A function marker, not a module directive.** The 2026-10-04 survey proposed `@wasm();` at
  module scope; the person rejected marking a whole file (2026-10-30), so `@wasm` marks an
  exported function and its callees follow it through the child build's dead-code elimination.
  The old statement is refused with a pointer to the function marker. Module state reached from
  both halves is refused (`refusedSharedState`), because each half would hold its own copy.
- **Copies by default; zero copy only through a view.** A writable Span copied back measured
  2680 ns for 1000 floats where a view measured 1090 (table below), so views exist; a view is
  only safe because nothing can grow memory while it is open, which is enforced at runtime by the
  same counter that refuses re-entry while a Span is lent to a callback.
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
- **A release while a call lends the handle is deferred to the end of that call**, a deliberate
  divergence recorded as `paper/NIM-REF.md` RT-48.

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
moved the sieve under 1%; `-msimd128` cut the `scaleSpan` wasm loop 434 → 105 ns and is not on.
Not explained: a wasm half exporting one function ran the sieve at 8.8 ms against 5.85 ms with
the full export list, from the same C.

The bench sources are `main.ms`/`benchWasm.ms` and the neon crate `lib.rs`/`bench.mjs`; they
live outside the repo (m1m `~/neonbench`). Not measured: browsers, Windows since these changes,
the browser column of the oracle.

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
