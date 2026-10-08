# WASM — one program across JS and wasm

Status: surveyed design, 2026-10-04. **NEW MECHANISM; approval required before implementation.**
The probes below establish transport capabilities and current compiler behavior, not a working
mixed-backend compiler. No compiler implementation is included in this design.

## The app author's contract

A browser app keeps its DOM and reactive owner tree in JS and calls C-backed rendering in wasm
through ordinary imports, functions and callbacks. The author writes no transport, pointer casts,
registration table, or call-site decorator. Native builds remain one C program.

Intended consumer fragment, not a currently working mixed-backend example; `context` and `button`
are supplied by the app:

```ms
import { Scene3D, setVisible, closeScene } from "void/src/void3d/scene";

const scene = Scene3D.create(context);
const root = scene.rootId();
button.onclick = () => setVisible(scene, root, false);
closeScene(scene);
```

These are the current Void spellings: creation takes a context, setters are free functions, and
terminal disposal is `closeScene(scene)`, not an assumed `scene.close()`. Crossing must preserve
aliases of `scene`; it must not turn it into a copied record. A stale bridge handle and a stale
Void node id are different checks, both required.

The consumer constraint is `neon/docs/VISION.md`, “Across the boundary”: one owner tree, with
cleanup reaching the inner root. Synchronous interop alone does not prove reactive tracking,
context propagation, cleanup, or the one-displayed-frame requirement. Those need a Neon consumer
run after the compiler pin. `neon/src/platform/browser/dom.ms` is the DOM-host anchor;
`void/scripts/build-web.sh` and `void/web/void2d.html` are the web-build and loader anchors.

## Recommended cut and marker

1. **JS is the default; place whole modules in wasm.** A C-dependent module is a placement seed,
   not a reason to move every importer into wasm. An importing JS module calls its exports through
   generated bindings. A wasm module can likewise call a JS export through an import thunk.
2. **Infer mandatory placement from active C dependencies.** Header imports and active C build
   directives seed wasm placement. Do not grep raw source: comments, inactive `when` branches,
   and backend variants must not force a cut. Backend-dependent conditions and variant selection
   must converge to one placement; contradictory JS-only and C-only requirements are errors.
3. **Propose a module directive `@wasm();` for elective placement.** Put it at module scope to
   move a pure-MetaScript module. Reuse the standalone-directive idiom used by `@compile(...)`;
   this is a proposed new directive, not supported syntax for placement today. Reject its use as a
   function decorator rather than silently giving it module-wide meaning.
4. **Keep `.wms` as a backend variant, not a placement marker.** Select `.wms` then `.cms` for an
   already wasm-assigned module; do not reinterpret the existing extension as a new effect.
5. **One logical application module, one home, one global instance.** Do not compile a shared
   stateful module twice to satisfy the two graphs. Pure type declarations and backend runtime
   support may need representation-specific instances; they are not duplicated application state.
   A cross-boundary type needs one logical identity and a verified conversion, not equal names.

A proposed pure computation module looks like this; its caller still writes `evaluate(...)`:

```ms
@wasm();
export function evaluate(value: int32, callback: (value: int32) => int32): int32 {
    return callback(value) + 1;
}
```

A function/fragment cut is possible in principle: the typed-binding references below demonstrate
function-level interfaces. It is not rejected as impossible or presumed slower. It additionally
needs rules for captures, shared globals, recursive calls and placement of callees; no performance
comparison was measured here. The module cut uses the existing compiler's resolution unit and is
the recommended first contract. The author loses per-function placement within one module; that
tradeoff needs approval. Whole-app wasm is another valid cut, but does not remove the DOM bridge
and should not silently replace the requested JS-rooted app.

## Boundary contract proposed for approval

| Surface | Proposed transport and invariant |
|---|---|
| Booleans, enums, integers through 32 bits | Typed scalar values; preserve signedness and width. |
| `int64`, `uint64` | Wasm `i64` and JS `BigInt`, never a precision-losing `Number`. Normalize unsigned results with `BigInt.asUintN(64, ...)`; the tested raw export returns a signed BigInt bit pattern. |
| `float32`, `float64` | `f32`/`f64`; retain the existing per-operation float32 rounding and no-contraction contract. The probe verifies finite values and negative zero, not NaN payload preservation or all arithmetic. |
| Strings | Length-delimited copying through the existing WTF-8 conversion semantics, including embedded NUL and lone UTF-16 surrogates. Do not use C-string length or generic `TextEncoder`/`TextDecoder` as the complete codec. |
| Value structs, tuples, tagged results | Recursively marshal fields and discriminants, not raw C struct bytes or padding. A struct containing references is not thereby a plain value. Reject fields without a supported representation/lifetime contract. |
| Packed owning `Vec<T>` of supported scalar values | Copy across distinct JS/wasm heaps; preserve value semantics. Scratch storage and returned owning storage have distinct cleanup. No borrowed heap view exposed to the author. |
| `T[]`, mutable `Span<T>`, `ref`/`out`, pointers | No silent copy where shared mutation or address identity is expected. Require an explicit safe reference/borrow protocol; otherwise diagnose the boundary declaration. Ordinary references within one backend are unchanged. |
| Resource owners | Canonical identity-preserving proxies backed by typed, generation-checked handles. Disposal must use the declared terminal operation; do not infer ownership or termination from a method's name. |
| Closures | Typed trampolines plus rooted environment. Proven nonescaping callbacks borrow for the call. Retained callbacks require a declared deterministic owner and are invalidated/released when that owner ends. Unaccounted escape is an error. |
| Cross-boundary `Promise`/`await`, exceptions | Require a designed settlement/unwinding protocol before acceptance. Initial recommendation is a boundary diagnostic, not fire-and-forget, an invented default return, or a swallowed error. This is a proposed surface restriction, not a claim that current checking can enforce it. |

Copies for owning values are the safe default, not a zero-copy performance claim. A future
borrowed-view path must prove no invalidating growth, owner release or reentrant mutation during
the borrow. “Valid until this call returns” is insufficient: a callback can grow memory before
the original call returns. Shared-memory buffers have different growth behavior; they were not
probed and are not this proposal's transport.

### Deterministic lifetime is a prerequisite, not glue already provided

`std/ffi/index.cms` `Handle.retain`/`release` supplies an existing native rooting idiom;
`std/ffi/index.jms` is its same-heap JS counterpart. Neither is already a JS/wasm resource table.
The generated bridge must retain a native owner once while its exported identity is live, keep
aliases on the same identity, and release that bridge hold exactly once at invalidation. Native
references held by other owners remain governed by the existing lifecycle hooks.

A declared terminal operation runs the real owner cleanup. It must invalidate aliases and attached
callback leases without freeing an owner still borrowed by an active call. Closing from a callback,
reentrant calls, closing parent/child owners in either order, and stale generations need explicit
pins. Cross-heap cycles must not be advertised as collected by either heap's collector.

The compiler cannot infer this contract from `interface`/`class` alone, or from a `close` spelling:
Void uses `closeScene`. **Before implementing owner support, define declaration metadata for the
terminal symbol and callback retention/escape rules.** That metadata and any new checking effects
are part of the NEW MECHANISM and require review; no new annotation spelling is approved here.
An unsupported owner is diagnosed rather than copied, pinned forever, or freed by a guessed rule.
JS finalizers cannot be the correctness mechanism for GPU resources or callback environments.

`externref` is available in the tested C toolchain for parameters, locals and returns, but C
struct fields reject it as sizeless. It is therefore not a replacement for the bridge's lifetime
model. Choose integer handles for persistent resource identity; use direct `externref` only where
the toolchain representation and its root lifetime are established.

## Compiler and browser shape

Existing integration anchors: `src/compiler/compile.ms` `buildResolverConfig`/`loadAndCheckGraph`,
`src/module/resolver.ms` `createDefaultConfig`, `src/module/loader.ms` `inlineHeaderImports`,
`src/checker/orchestrator.ms` `checkModuleGraph`, and `src/checker/checkPass.ms`
`preludeContextFor`/`loadPreludeOne`. Follow those idioms, not a second language frontend.

The proposed additions are:

- Placement-aware logical module graph and backend-specific resolution. Resolve each module's
  active variant and prelude under its assigned backend before checking its implementation.
- One checker implementation, **backend-specific contexts**, and a shared logical boundary
  contract. The current graph check takes one backend extension and target information; passing
  one context over both representations is not established. Prelude/compiler-global registry
  isolation must be proven before relying on sequential JS and wasm checks in one process.
- A typed boundary manifest containing logical types, widths, representations, lifetime/effect
  contracts, imports/exports and stable identities. Both generated halves consume it.
- Lower cross-boundary calls and resource operations before emission. JS and C codegen remain
  thin emitters; no ownership inference or graph partitioning inside C codegen.
- Generate Emscripten C imports/exports and JS adapters directly from checked types. Use
  synchronous wasm calls and generated JS-library/`EM_JS` transport, not JSON messages, JSI or
  per-call `ccall` signature discovery. Embind is a lifetime/design precedent, not a required C++
  runtime for the C emitter.
- Generated async startup loads and instantiates wasm before executing app top-level code. Do
  not turn an ordinary synchronous function into a Promise or reorder module initialization to
  hide an unready instance. Cross-backend initialization cycles need the same defined ordering
  or a diagnostic; they were not exercised here.
- One JS app and a compatible wasm artifact per GPU backend. Void currently builds WebGPU and
  WebGL2 separately under Emscripten 5.0.5. Generate the selection/loading manifest rather than
  making the app write it. Select once before app initialization; both artifacts must agree on
  boundary ABI and state layout. `navigator.gpu` presence alone is not proof adapter creation
  succeeds; loader failure must be explicit and any fallback must precede app initialization.
- Include placement, boundary manifest, backend variants, toolchain identities, GPU flags and
  referenced C inputs in existing build identities. A compatible-looking stale half must be
  refused before calls, not accepted because the export names happen to match.

**NEW MECHANISM adds:** per-module placement inside one build, paired typed lowering/bindings,
backend-context isolation, cross-heap handles and lifetime/effect contracts, coordinated startup
and artifact identity. **Can regress:** type identity and overload resolution across variants,
global initialization, numeric/string parity, GC/DRC safety, cache correctness, debug names and
stack traces, and Neon reactive ownership during reentry. No speedup or “zero-cost boundary” was
measured or promised.

## Measurements and limits

Measured on 2026-10-04, compiler source `6a0c386d4b23b49737b763ee656b284b9db75b27`, source tree
`3aa4cc2268276a6536d5ce0fdd46e1204da1255d`, provisioned `msc` v0.3.0, Node 24.18.0,
Emscripten 5.0.5 (`bc569045b14c3fa7b960734ed2c50da7b20adea4`), Chromium 154.0.0.0.
Builder SHA-256: `399c7ae75f1485211adf133efe7c6de474a8e830ed9ad1fac09ff3f7a97c3c90`.
The builder was provisioned from the main checkout, not rebuilt from this source tree during
the survey; its exact producing source commit was not independently established.
Throwaway probes used `msc build <probe>.ms --output=<probe>.exe` and ran the executable;
JS used `msc build <probe>.ms --target=js --output=<probe>.js` followed by `node <probe>.js`.

| Probe axis | Observed result |
|---|---|
| C header dependency: `int add_one(int)` from a companion `.h`/`.c`; app calls `add_one(41)` | Native C prints `42`; JS build succeeds, then Node reports `ReferenceError: add_one is not defined`. No generated bridge on this path. |
| Import `./variant` with `.cms`, `.jms`, `.wms` siblings | C prints `variant=c`; JS prints `variant=js`; `--os=emcc --emit=c` emits the `.wms` translation unit. Full MetaScript emcc linking was not run. |
| Explicit `./variant.wms` import under `--target=js` | JS prints `variant=wasm`; importing that extension alone did not select wasm emission. |
| Standalone `@wasm();` versus `@wasm()` on a function | Standalone JS build runs and prints `marker=module`, without establishing placement; function decorator is refused: `Decorators are not valid here`. Neither is a working placement feature. |
| C/JS numeric controls | Both print `scalars=ok strings=ascii,astral,lone-surrogate`; checks cover positive/negative integers past 2^53, `uint64` maximum minus one, float32 `0.1` and its product by three. |
| C/JS string controls | ASCII, astral pair and lone high surrogate round-trip through `asBytes().asString()`; astral `.length` is 2, lone surrogate's code unit is 55296. Embedded NUL and lone low surrogate were not run. |
| C/JS packed controls | Both print `Vec=copy uint8,float32 array=shared`; mutation after `Vec` assignment leaves the source unchanged, while `T[]` aliases observe mutation. |
| Real Emscripten transport, Node and Chromium | JS → wasm → JS → wasm reentry yields `42` and `-3`; signed i64 boundaries and unsigned maximum round-trip, callback i64 stays exact, float32 product and negative zero match; `externref` object identity/mutation and null survive. |
| Same transport, memory growth | A cached view becomes zero-length after growth to 32 MiB; the refreshed Emscripten view has 33554432 bytes. A separate Node factory-load measurement reports `initial-heap=16908288` bytes. |
| C `struct StoredRef { __externref_t value; };` with `-mreference-types` | Refused: `field has sizeless type '__externref_t'`. |
| JS encoder control | UTF-16 lone high surrogate round-trip through `TextEncoder`/`TextDecoder` changes the string. |

Transport command: `emcc transport.c -O2 -mreference-types -ffp-contract=off -sWASM_BIGINT=1
-sMODULARIZE=1 -sEXPORT_ES6=1 -sALLOW_MEMORY_GROWTH=1 -sEXPORTED_RUNTIME_METHODS=HEAPU8
-sENVIRONMENT=web,node --no-entry -o transport.mjs`. Windows invoked the installed `emcc.py`
with the SDK Python and `EM_CONFIG`; Node imported the generated factory. The browser loaded
that same module over local HTTP, and its observed surface read:

```text
PASS: JS → wasm → JS → wasm
i64/u64 exact; f32 + negative zero exact
externref identity/null; cached memory view detached
TextEncoder loses lone surrogate
```

The transport was hand-written **only as a capability probe**, not offered to app authors and
not retained as an implementation. Not verified: mixed MetaScript generation, resource teardown,
retained closures, cross-boundary exception/async cleanup, full C/JS arithmetic equivalence,
Safari/Firefox, WebGPU/WebGL2 rendering, ABI rejection, cache invalidation or crossing costs.

## References consulted

The standard compiler checkout was `dcec8e1cd1a33b3dfa6a9fa38784d0c9195b6aca`:
`compiler/main.nim` `commandCompileToC`/`commandCompileToJS`, `lib/system/platforms.nim`
`CpuPlatform`, the Emscripten branch in `lib/system/osalloc.nim`, and the backend guard in
`lib/js/jsffi.nim`. These are separate whole-program backend paths, not an existing mixed-program
partitioner. Extending that mechanism to one logical program is NEW MECHANISM.

Primary references read for this survey; their runtimes were not independently built except the
installed Emscripten probe above:

- [wasm-bindgen design](https://wasm-bindgen.github.io/wasm-bindgen/contributing/design/index.html),
  [paired export shims](https://wasm-bindgen.github.io/wasm-bindgen/contributing/design/exporting-rust.html),
  [JS-object heap design](https://wasm-bindgen.github.io/wasm-bindgen/contributing/design/js-objects-in-rust.html),
  [closure lifetime](https://wasm-bindgen.github.io/wasm-bindgen/reference/passing-rust-closures-to-js.html):
  generated typed adapters and distinct borrowed/retained lifetimes. The internal-design pages
  contain historical limitations; they are not proof modern wasm lacks reference types or multivalue.
- [.NET source-generated interop](https://learn.microsoft.com/en-us/aspnet/core/client-side/dotnet-interop/?view=aspnetcore-10.0):
  generated marshalling, explicit 64-bit representation choices, callbacks and Promise/Task maps.
  Its GC-managed proxy disposal is not proof of deterministic GPU disposal for this runtime.
- [Kotlin/Wasm JS interop](https://kotlinlang.org/docs/wasm-js-interop.html): external declarations,
  `@JsExport`, restricted interop types, opaque `JsReference`, BigInt and JS exception handling.
- [AssemblyScript host bindings](https://www.assemblyscript.org/compiler.html#host-bindings):
  generated ESM/raw bindings, copied strings/arrays, and opaque reference-counted object pointers.
- [Emscripten interaction](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/Interacting-with-code.html),
  [EM_JS](https://emscripten.org/docs/api_reference/emscripten.h.html#c.EM_JS),
  [Embind](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/embind.html):
  import/export transport, explicit deletion, finalizer limitations and unsafe borrowed memory views.
  Installed SDK anchors: `test/core/test_externref_emjs.c` and `test/test_core.py` `test_externref_emjs`.
- [WIT resources](https://component-model.bytecodealliance.org/design/wit.html#resources) and
  [Canonical ABI](https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md):
  own/borrow/drop vocabulary and type-directed lifting/lowering. This proposal does not claim
  Component Model compatibility, adopt its full ABI, or add a `jco`/`wit-bindgen` build dependency.
- [jsbind](https://github.com/yglukhov/jsbind#readme): one binding declaration works in separate JS
  and Emscripten builds; retained callbacks explicitly need `jsRef`/`jsUnref`.
  [wasmrt](https://github.com/yglukhov/wasmrt#readme): a C-to-wasm route with JS bootstrap and imports;
  neither README establishes one compiler-partitioned JS/wasm program.
- [neon-bindings Root](https://docs.rs/neon/latest/neon/handle/struct.Root.html) and
  [JsBox](https://docs.rs/neon/latest/neon/types/struct.JsBox.html): rooting versus GC-owned native
  storage. This is the Rust/Node project, not the MetaScript Neon UI framework; N-API is not a
  browser transport.
- [React Native JSI](https://reactnative.dev/architecture/landing-page#fast-javascriptnative-interfacing):
  native JS-engine/C++ interop, not a browser JS/wasm API. Browser wasm imports/exports supply the
  synchronous transport tested here.

## Approval and implementation acceptance

Approval must settle the JS-rooted module cut, proposed module directive, value-copy policy,
deterministic owner/callback contract, and whether the initial async/exception/reference
restrictions are acceptable. A general “go” for surveying is not approval of those language losses.
If seamless async, exceptions or arbitrary shared references are required immediately, expand
the design before implementation rather than delivering a narrowed compiler feature.

After approval, the implementation arc's first pin must be one `--target=js` MetaScript program
calling a wasm module and receiving its callback, with no hand-written bridge, built and run for
**both WebGPU and WebGL2**. Include a reentrant variant and values beyond 2^53; prove red on the
current compiler and green on the candidate. Then pin owner aliases/terminal disposal, escaped
callbacks, stale handles, strings, value containers, backend-variant type identity, initialization
ordering and artifact mismatch. Consumer verification must exercise a real Neon `<Void>` owner
cleanup, not just independent JS and wasm examples. No implementation or acceptance pin exists yet.
