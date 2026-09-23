# Hot Code Reload

This document owns the architecture and user contract for native MetaScript hot code
reload (HCR). Source files own implementation details; the HCR worktree card owns current
execution state.

## Goal

A Neon/lightcube developer saves a MetaScript file and sees the new native behavior without
restarting the process or losing editor state. The common path requires no plugin-style
source annotations. Compiler errors and invalid candidates leave the running application
untouched.

The target experience matches Flutter's useful contract:

- load changed code;
- preserve durable application state;
- rebuild the framework-owned view tree and callbacks;
- distinguish hot reload, dependent reload, and restart-required changes;
- never rerun first-load initialization implicitly.

Unlike Flutter debug mode, the changed code still runs through MetaScript's native C
backend and DRC/ORC runtime.

## Current status

| Capability | State |
|---|---|
| `--hcr` and module-global state lifting | Implemented |
| Structural hash rejecting changed `_GlobalState` layout | Implemented |
| Single-image POSIX `dlopen` host | Re-pinned by `examples/hcrProbe/run.sh` (2026-09-22, run, not read): body-only reload preserves lifted state (same `_GlobalState` pointer, `PROBE PASS`), layout change + truncated image rejected loud, current stays live. Executes via `--os=linux --cc=zig` cross-build + WSL: this Windows host's toolchains ship no `dlfcn.h` |
| Single-image Windows `LoadLibrary` host | Implemented by `examples/hcrProbe/hostWindows.ms`, guarded by `src/test/hcr/run.ms` (`hcrWindowsReload`): body-only reload preserves lifted state; layout and bad-image candidates fail loud while current stays callable |
| Per-module native object cache | Implemented by generated-C fingerprints; `src/test/hcr/run.ms` proves a body-only edit recompiles only the changed module |
| Per-module shared libraries | Windows x64: a non-reloadable `<stem>.core.dll` (runtime, std, registry) plus one DLL per project module, guarded by `src/test/hcr/run.ms` (`hcrIndirect`): the unrebuilt app calls a reloaded `logic` image. Linux and macOS link flags exist but are not verified |
| Cross-module vtable calls | Lowered by `src/transform/native/hcrIndirect.ms` and replaced at runtime by publishing a reloaded image's table, guarded by `src/test/hcr/run.ms` (`hcrIndirect`) |
| Full transactional current/old/candidate module registry | Not implemented; the Windows single-image host proves candidate-before-publish and retained accepted generations |
| iOS and automated watch/deploy loops | Not implemented |
| Neon Fast Refresh integration | Contract defined here; implementation belongs to the Neon repo |

Implementation anchors: `src/transform/native/hcrLift.ms` `liftHcrState`,
`src/compiler/cache.ms` `moduleCompileFp` / `isCCodeCached`, `runtime/hcr.h`,
`runtime/hcrHost.c`, `examples/hcrProbe/hostWindows.ms`, `src/test/hcr/run.ms`, and the
`--hcr` branch in the compiler build driver.

## Architecture decision

MetaScript uses **cooperative indirection**, not debugger-driven binary patching:

- persistent data lives outside reloadable code;
- calls crossing a reload boundary use a module function table;
- private and same-module calls remain direct;
- the host publishes a replacement only after load, validation and initialization succeed.

**Data is permanent; code is transient.** Everything is gated by `--hcr`; a normal build
pays no vtable cost and must remain output-identical.

The contract is platform-neutral; the artifact pipeline is not. Each supported target uses
its native object format, linker, loader, generation-retention rules and, where required,
sign/deploy flow. The core must neither impose PE import mechanics on ELF/Mach-O nor depend
on POSIX unresolved-symbol behavior that Windows cannot provide.

The design combines these proven contracts:

- explicit lifted state and function tables from native C game/tool hosts;
- immutable generation paths and retained accepted modules from native C/C++ reload hosts;
- dependency-order initialization, copy-load artifacts and generation cleanup from nimhcr;
- incomplete-image retry from cr.h;
- BEAM's current/old generations and external-call switch boundary.

The Windows foundation deliberately does not copy cr.h's unload-current-before-load order:
the candidate is loaded, resolved and handed over before publication, so rejection cannot
remove the callable current generation. Accepted prior DLLs remain loaded until a later safe
point can prove they are unreachable.

Rejected foundations:

- MSVC Edit and Continue or Live++ binary patching: debugger/proprietary coupling and
  binary-format-specific stale-frame repair;
- writable executable jump tables: architecture-specific instruction encoding plus
  MAP_JIT/codesign constraints on Apple Silicon;
- Raiser as the primary Neon runtime: suitable for logic-only eval, not the native render
  path.

## Runtime invariants

1. **Off means absent.** `--hcr` off emits no HCR ABI or indirect calls.
2. **Calls select a generation deliberately.** Cross-module calls enter the current module
   table. A direct call already executing old module code stays old until it returns.
3. **Publication is transactional.** The loader holds `current`, `old` and an unpublished
   `candidate`. Candidate failure leaves current callable.
4. **Old is the rollback generation.** A successful publish rotates current to old. Old is
   retained until the next verified safe point.
5. **A third generation requires quiescence.** If a reloadable frame, thread, timer or raw
   callback can still reach old code, reload fails loud instead of unloading live code.
6. **Persistent references are indirect.** Hosts, registries and long-lived callbacks hold
   stable vtable handles, never raw pointers into a reloadable image.
7. **State compatibility is strict today.** Any persistent-state structural-hash change
   requires restart. Append compatibility and migration are separate future mechanisms.
8. **TypeInfo identity survives accepted reloads.** Live DRC objects can retain TypeInfo
   pointers and destructor dispatch; unchanged layouts require stable addresses and an
   atomic function-table update.
9. **Never load the build output in place.** Copy a complete artifact to a generation path.
   A watcher observing an incomplete image retries that candidate without disturbing
   current.

## Generation lifecycle

At a Neon frame boundary, the non-reloadable host performs:

1. detect a complete changed artifact;
2. copy it to an immutable generation path;
3. load candidate without publishing it;
4. validate module ABI and persistent-state manifests;
5. initialize dependencies, handover state and register TypeInfo/vtables;
6. atomically publish candidate tables;
7. rotate previous current to rollback-old;
8. rebuild framework-owned views and callbacks;
9. purge the previous old generation only after the next safe-point proof.

A bad image is retried. A candidate rejected during load/handover/init is unloaded. A
candidate that fails after publication rolls back to old. Compile failures never reach the
runtime.

State migration is deliberately outside this lifecycle. A future `code_change`-style API
may suspend users, transform state and resume them, but initial HCR rejects layout changes.

## Module ABI and reload classification

Each reloadable module needs a manifest covering exported function signatures, stable slot
identity, persistent layouts, TypeInfo identity, runtime/GC mode and toolchain stamp. The
compiler, not the developer, classifies a change:

| Change | Result |
|---|---|
| Function body or private implementation | Reload changed module |
| Exported ABI change with compatible persistent layouts | Rebuild/reload affected dependents |
| Persistent layout, runtime ABI, native platform code or incompatible TypeInfo change | Hot restart/full restart required |
| Compile, link, load or init failure | Keep current generation |

The manifest prevents a new module from publishing a table that existing callers interpret
with an old signature.

## User code contract

### Hot-safe by default

Ordinary imports, exports, pure functions, component render code and function-body edits need
no HCR syntax. Module globals are lifted by the compiler. Private implementation changes do
not alter the cross-module ABI.

### Compiler-enforced rebuild or restart

The compiler owns exported-signature compatibility, vtable layout, persistent-state layout,
TypeInfo identity and toolchain/runtime compatibility. A developer receives an exact reason
for dependent rebuild or restart; unsafe code is never loaded speculatively.

Global/static initializers are first-load behavior. Changing an initializer does not mutate
already-live state during hot reload.

### Explicit lifecycle required

These cannot silently survive a reload:

- threads, actors, timers or jobs executing reloadable code;
- callbacks registered with native libraries;
- raw function pointers stored across frames;
- closures whose code or captured-environment layout belongs to an old generation;
- raw `@emit` globals/statics outside compiler state lifting;
- GPU/window/socket resources owned by a reloadable image.

They must quiesce, re-register through stable handles, or move ownership into the
non-reloadable host. Reload lifecycle hooks will be explicit; their source syntax is not yet
chosen.

## Compiler work

The recompiler arc proceeds in this order:

1. **Re-pin the POSIX foundation:** recreate a minimal single-image probe proving state
   survives a body-only reload and incompatible layout fails loud.
2. **Establish the Windows-native foundation:** build generation-unique DLLs, load and
   validate a candidate before publication, keep current callable on rejection, and keep the
   production host/state machine in MetaScript.
3. **Per-module object cache:** fingerprint each emitted C module together with its compile
   command and retain one target-native object per fingerprint. A body-only edit recompiles
   only the changed module; C emission remains the correctness boundary. Loadable per-module
   libraries wait until the next two steps define their link boundary.
4. **Module ABI manifest:** assign stable exported slots and classify reload, dependent
   reload, or restart.
5. **VTable transform and module packaging:** rewrite cross-module exported calls through
   current module tables; keep private/same-module calls direct, then package each module
   through the target's native shared-library adapter. This belongs in native transform and
   platform tooling, not C codegen.
6. **Transactional loader:** current/old/candidate registry, copy-load, dependency ordering,
   bad-image retry, rollback, handlers and safe-point API.
7. **DRC/TypeInfo contract:** stable TypeInfo ownership and exactly-once destructor behavior
   across accepted reloads.
8. **Watch/deploy adapters:** save-triggered rebuild, host notification, Windows copy-load,
   macOS/iOS Simulator loading, and development-signed iOS device deployment.
9. **Diagnostics and measurement:** exact rejection reason and edit-to-visible timing.

S1 deliberately keeps the generated-C fingerprint boundary instead of adding a pre-emission
semantic hash. On Windows 11 x64, source tree
`65f14fd864208b09f7c04b84e4a118485a3e58f9`, an isolated two-module
`<candidate> build <temp>/app.ms --hcr --verbose --time --output=<temp>/module.dll` rebuild
after changing only `logic.ms` compiled `logic`, reused `app`, and linked once in 1.34 s.
Emission cost 5.8 ms wall / 15.8 ms summed over 11 workers. Changing only the imported
function's return type then recompiled both `logic` and unchanged `app`, proving a module
source hash cannot safely predict emitted C. A correct early key would need canonical
lowered-AST, type, symbol, flag, reachability and global-emission inputs; that new cache
mechanism was rejected rather than risk serving stale native objects for the measured
sub-percent wall-time gain.

S2 writes one deterministic `<output>.hcrabi` bundle after a successful HCR link. The
bundle contains one compile-ABI manifest per project module: project-relative module and
slot identity, canonical exported-function signatures, project dependencies, target,
GC/runtime and toolchain identity. Standard-library and runtime modules stay outside the
reload set and are covered by the toolchain stamp. Persistent layouts, TypeInfo and vtable
shape remain owned by the later packaging and DRC steps; S2 does not claim compatibility
for them.

On 2026-09-23, Windows 11 x64,
`MSC=out/msc-hcr-s2.exe bash src/test/hcr/run.sh` returned
`ok   hcrModuleAbi`. The cold build wrote manifests for `app` and `logic`; a body-only
`logic` edit compiled one module and reported
`HCR reload module: implementation changed (logic)`; changing `value` from `int32` to
`int64` reported
`HCR reload dependents: export signature changed (logic::value#0)`.

S3a lowers cross-module calls through module tables inside today's single image; S3b will
link each project module as its own image. The host owns one handle per module at a
stable address; the handle's `current` points at the slot table of the module's current
image, in S2 manifest slot order. Each module publishes its table and resolves the handles
of the other project modules in its DatInit, and every DatInit runs before any Init, so
cyclic imports see published tables. A caller reaches an export through a macro over its
native symbol, `#define f ((__typeof__(&f))_ms_hcr_m0->current[k])`: direct calls,
out-parameter struct returns and function values all enter the current table, while
same-module and private calls stay direct. Publish and rollback are one pointer store.
This is the data-table form of the reference's stable-address trampolines, which the
rejected-foundations list above excludes as writable executable memory. A MetaScript
function-typed struct field was measured as the alternative and rejected: it emits
`msClosure` with an `env ?` branch per call.

Exported functions of project modules are dead-code roots under `--hcr`, because the
manifest promises every slot. The image links the project dispatcher and exports it as
`DatInit000`/`Init000`, so dependency and standard-library inits run in load order; before
this, a host ran only the entry module's inits. Standard-library modules are excluded from
module identity even when the project root contains `std/`; without that,
`examples/hcrProbe/runWindows.sh` failed its build on `main` with
`HCR ABI cannot represent generic export 'std/core/system/index::!='`.

On 2026-09-23, Windows 11 x64, source tree `6d66e6d4` plus the S3a working tree,
`MSC=out/msc-s3a.exe bash src/test/hcr/run.sh` printed `ok   hcrModuleAbi`,
`ok   hcrIndirect` and `ok   hcrWindowsReload`. The two-module fixture's host call
returned `HCR-HOST call -> 37` through a plain call, an out-parameter struct return and a
function value. The same runner on the `6d66e6d4` compiler stopped at
`FAIL hcrIndirect: cross-module call to logic::value is not lowered through its table slot`.
Not verified: a POSIX host run (this runner checks emission only off Windows), and
replacing a table at runtime, which needs S3b's separate images.

### Per-module images (S3b)

`msc build app.ms --hcr --output=D/module.dll` links `D/module.core.dll` from the runtime,
the standard-library modules, the registry (`runtime/hcr.c`) and a core dispatcher, and one
image per project module: the entry becomes `D/module.dll`, every other module
`D/module.<id>.dll`. Core exports all its symbols through an import library
(`D/module.core.lib`); a module image links against it and imports nothing from another
module image, so its only cross-image edges are the handle tables, the TypeInfo registry and
the core runtime. Each image exports `DatInit000`, `Init000` and, when it lifts state,
`_hcr_handover`; its `DatInit000` first calls the idempotent `msHcrCoreInit()`, which runs the
standard-library inits once. A module id `core` is rejected, because it would collide with
the core image name.

The layout follows the reference's split, where the registry and runtime are the only
non-reloadable libraries, with one intentional divergence: the standard library lives in
core instead of reloading per module, so a change that alters core is a restart. A loaded
core is locked on Windows, so every image keeps its own link cache and an unchanged core
is not relinked.

Three edges that a single image resolved by the linker needed a mechanism across images:

- **Runtime thread-locals.** A DLL cannot import a `_Thread_local` from another DLL on this
  toolchain: lld reported `unable to automatically import from msErr with relocation type
  IMAGE_REL_AMD64_SECREL`, and `-femulated-tls` failed with `undefined symbol:
  __emutls_get_address`. Core publishes its `_tls_index` and each exported variable's offset
  (`MS_TLS_PUBLISH`, `runtime/hcrTls.h`), and a module image compiled with
  `-DMS_HCR_MODULE` reads the variable inline through the x64 TEB, the same instruction
  sequence a compiler emits for in-image TLS. A hand-written C probe measured 200M
  check-and-set iterations at 0.349 s through an accessor call and 0.129 s through the TEB.
  Other Windows architectures fail at compile time with a named `#error`; ELF and Mach-O use
  native cross-library TLS.
- **TypeInfo identity.** `instanceof` on a class from another module emitted `extern msTypeInfo
  …TypeInfo`, which fails a split link. Every class and interface of a project module is
  reached through `#define <C>TypeInfo (*_ms_hcr_tiN)`, resolved in DatInit from
  `msHcrTypeInfo(owner, name)`: registered once by name and returned at the same address
  across generations, as the reference registers type info in its registry.
- **DRC hooks.** Hooks were generated by the first module that needed them and declared
  extern elsewhere. Each project module now owns the hooks it needs, while the standard
  library keeps one shared owner set inside core.

Methods of exported classes were missing from the S3a DCE roots although their table slots
referenced them (`use of undeclared identifier 'Shape_area__…'`); every manifest function is
now a root. A project module importing an exported variable of another project module is
rejected before codegen with `HCR cannot share exported variable '<id>::<name>' with module
'<id>' across module images`. Without that check both `export const` and `export let`
failed the link with `undefined symbol`.

On 2026-09-23, Windows 11 x64 with zig 0.16.0, the S3b branch rebased on `f9ce6c7b`,
`MSC=out/msc-s3b2.exe out/msc-s3b2.exe run src/test/hcr/run.ms --target=raiser` printed
`ok   hcrModuleAbi`, `ok   hcrIndirect` and `ok   hcrWindowsReload`. The host loaded `logic`, `shapes` and `app`
from `g1`, then published `g2/module.logic.dll` built after a body edit; the app image was
not reloaded:

```
HCR-HOST gen1 hcrIndirectValue -> 37
HCR-HOST gen1 hcrShapeValue -> 9
HCR-HOST gen1 hcrErrorValue -> 1
HCR-HOST gen1 hcrTickValue -> 1
HCR-HOST reloaded g2/module.logic.dll
HCR-HOST gen2 hcrIndirectValue -> 163
HCR-HOST gen2 hcrShapeValue -> 9
HCR-HOST gen2 hcrErrorValue -> 1
HCR-HOST gen2 hcrTickValue -> 11
```

`hcrShapeValue` crosses images with `instanceof` and a dispatched method, `hcrErrorValue`
catches an exception thrown in another image through the TLS error flag, and `hcrTickValue`
keeps `logic`'s lifted counter across the reload (`1`, then `1 + 10`). Before the port to
`run.ms`, the same cases in the shell runner stopped on the S3a compiler at `FAIL hcrIndirect: the app image DatInit does not initialize the
core image first`. Not verified: Linux and macOS images (this machine's `--os=linux --cc=zig`
cross-build fails at `runtime/core/system.c (exit -1)` without `--hcr` too, and the session
could not run WSL), Windows ARM64, and an object of a previous generation checked with
`instanceof` after its module reloaded. Standard-library generics instantiated for a project
class link and run across images in one probe: `Shape[]` with `map` and `Map<string, Shape>`
in `app` over `shapes` returned `PROBE 17` (4 + 9 + 4); other generic shapes are not covered.

## Neon Fast Refresh boundary

This compiler document defines the contract; implementation must be designed and committed
from a session started in the Neon repository.

### Durable state

The Neon integration must preserve application/editor model state, documents, selections,
undo history, host services, window/GPU/native handles, and component state that can be keyed
by a stable component identity.

### Ephemeral state

After publication Neon must discard and rebuild the view/render tree, layout and derived
caches, closures, event handlers and other code-bearing registrations. An old closure must
not keep an old dylib alive indefinitely or continue running stale behavior.

### Required Neon work

1. define stable component/state identity independently of code addresses;
2. add a frame-boundary `reassemble` lifecycle driven by the HCR host;
3. rebuild the view tree and rebind all callbacks after publication;
4. park/resume framework jobs and native callbacks around the safe point;
5. keep compile/load failures visible as an overlay while current code continues;
6. surface hot reload, dependent reload and restart-required as distinct outcomes;
7. add save-to-visible integration tests on macOS and iOS Simulator.

The compiler must not silently expand into Neon implementation. The shared ABI/event contract
is finalized in the compiler; the framework behavior is owned by Neon.

## Experience target

For a warm macOS/iOS Simulator development loop:

- save triggers reload automatically; no terminal key or manual host action;
- body-only edits preserve model/component state and update the next frame;
- invalid code leaves the running editor usable;
- old closures/handlers are not invoked after reassembly;
- restart-required changes name the incompatible state, ABI or runtime contract;
- edit-to-visible target: less than 500 ms for the two-module contract demo.

Physical iOS devices add deploy/sign latency; the semantic contract stays identical.

## Platform contract

| Platform | HCR target |
|---|---|
| macOS | First-class `.dylib`/`dlopen`; no RWX or MAP_JIT requirement |
| iOS Simulator | Same loader model as macOS; primary iOS development loop |
| iOS device, development-signed | Signed dylibs deployed inside the app bundle/container; host deploy/sign step required |
| iOS App Store/release | Unsupported by platform policy; HCR is development-only |
| Windows | `LoadLibrary` with versioned copies; never overwrite/eagerly unload current or rollback-old |
| Linux | `.so`/`dlopen`; reference POSIX implementation |

These adapters implement one publication, compatibility and state-survival contract; they
do not share a lowest-common-denominator linker strategy. A target is supported only when
its native adapter proves that contract end to end.

The current implementation has single-image foundations for POSIX and native Windows.
Per-module artifacts, vtable dispatch, the full module registry and automated deployment
remain later slices.

On 2026-09-22, Windows 11 x64 source tree
`112b9d0a69e7a1058ba3931d15f69dec3e61a9a0` was built as a candidate compiler, then
`MSC=<candidate> bash examples/hcrProbe/runWindows.sh` completed four generations with one
stable state pointer and values `10`, `40`, `60`, `80`. The layout and truncated-image
candidates both failed loud; the accepted generation remained callable after each rejection.
`llvm-readobj --coff-exports` reported the fixed ABI names `DatInit000`, `Init000`,
`_hcr_handover` and `hcrProbeBump`. A temporary Win32 C oracle and the MetaScript host both
exited zero with the same eight normalized transition lines and both error contracts. The
same candidate also passed `examples/hcrProbe/run.sh` through WSL. The temporary C oracle was
then deleted; production orchestration is MetaScript and `runtime/hcr.h` is only the Win32
loader/raw-function-pointer ABI edge.

## Verification

### Compiler contract

`examples/hcrApp/` is recreated with `app.ms` calling `logic.ms`:

- only `logic` rebuilds for a body-only change;
- unrecompiled `app` observes new behavior through the current vtable;
- persistent state survives;
- incomplete artifacts retry without disturbing current;
- load/init failure and candidate crash preserve or restore current behavior;
- a layout change reports restart-required;
- a live DRC object destroys exactly once through the accepted TypeInfo generation;
- old code purges only after safe-point proof;
- `--hcr`-off C output is byte-identical to a build without HCR Phase 3.

### Neon contract

A Neon demo preserves editor/model and stable component state across a render-function edit,
shows the new frame, drops old handlers, remains interactive after compile failure, and
reports restart-required for persistent layout changes.

Measurements are recorded only after running these contracts, with tree and platform named.

## References

- [Flutter hot reload](https://docs.flutter.dev/tools/hot-reload) — state preservation,
  framework rebuild and reload/restart classification.
- [Erlang compilation and code loading](https://www.erlang.org/doc/system/code_loading.html)
  — current/old generations and external-call switching.
- [Erlang release handling](https://www.erlang.org/doc/system/release_handling.html) — state
  migration as synchronized, explicit work.
- [cr.h](https://github.com/fungos/cr) — versioned copies, incomplete-image retry and
  rollback.
- [Runtime Compiled C++](https://github.com/RuntimeCompiledCPlusPlus/RuntimeCompiledCPlusPlus)
  — unique temporary module paths and retention of loaded module handles.
- [nimhcr](https://github.com/nim-lang/Nim/blob/devel/lib/nimhcr.nim) — dependency-order
  reload, generation cleanup and lifecycle handlers.
- [Visual Studio C++ Hot Reload](https://learn.microsoft.com/en-us/visualstudio/debugger/edit-and-continue-visual-cpp)
  — stale-frame constraints; not an implementation dependency.
