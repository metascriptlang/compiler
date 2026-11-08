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
| A TS typed array result (`Float32Array`, `Int32Array`, … the nine classes), nullable | copied into a new array of the same class over a copy of its whole buffer, `byteOffset` and `length` kept; the call throws when the array is still held on the wasm side, when its `ArrayBuffer` is held by another view, or when its class extends the declared one. A typed array parameter takes a `Span<T>`, which a typed array passes to | `typedArrayResults`, `typedArrayMisuse` |
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
- **A typed array result is a copy only when nothing else can see the original.** A typed array is
  a class instance with an identity, so the wasm side hands it over only when it holds the sole
  reference to the array and to its `ArrayBuffer` and the instance is of the declared class;
  otherwise the call throws naming `Float32Array.from(x)`, because a copy would split one object
  into two that stop seeing each other's writes. Measured 2026-11-08 on m1m (Node): a `makeVec`
  of 1000 written through a `Span` of the array returns in 0.69 us against wasm-bindgen's 0.89;
  written through `out[i]` it takes 1.28 us, the typed array subscript's own cost in std.
- **A release while a call lends the handle is deferred to the end of that call**, a deliberate
  divergence recorded as `paper/NIM-REF.md` RT-48.

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
- **No zero-copy path for JS-owned data.** Wasm cannot address a JS `ArrayBuffer`, so a `Span` of
  JS data is copied in and back, as wasm-bindgen's `&mut [f32]` glue does; data the wasm side
  holds is shared without a copy through `Handle<VecBox<T>>` (bench row `scaleBox`).

## Is it still green

Two checks answer it, both outside the land gate and the core tests, run on a host with Emscripten:

- **Correct:** `src/test/wasmmix/check.sh` runs every wasm boundary unit test and every wasmmix
  program in all its columns; `WASMMIX_BROWSER=1 CHROME=<path>` adds headless Chrome. It ends with
  `js-wasm check: GREEN` and exit 0. 2026-11-07 on m1m, main `804c40e867a`: units 170/170, wasmmix 79/79.
- **Fast enough:** `CHROME=<path> src/bench/run.sh wasmBoundary` then `node src/bench/wasmBoundary/accept.mjs`
  times the same rows in MetaScript and wasm-bindgen on Node and in headless Chrome, and prints which
  rows meet wasm-bindgen on the same runtime (exit 0 when all do); neon-bindings, a native Node-only
  addon, is a reference column, not the bar (the person, 2026-11-08). Recipe, arms and the recorded
  table: `src/bench/wasmBoundary/baseline.md`; 2026-11-08 it read 10 of 12 rows on Node and 11 of 12
  in Chrome.

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
