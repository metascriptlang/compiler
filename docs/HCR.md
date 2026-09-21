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
| Per-module shared libraries | Not implemented |
| Cross-module vtable calls | Not implemented |
| Transactional current/old/candidate loader | Not implemented |
| Windows, iOS and automated watch/deploy loops | Not implemented |
| Neon Fast Refresh integration | Contract defined here; implementation belongs to the Neon repo |

Implementation anchors: `src/transform/native/hcrLift.ms` `liftHcrState`, `runtime/hcr.h`,
`runtime/hcrHost.c`, and the `--hcr` branch in the compiler build driver.

## Architecture decision

MetaScript uses **cooperative indirection**, not debugger-driven binary patching:

- persistent data lives outside reloadable code;
- calls crossing a reload boundary use a module function table;
- private and same-module calls remain direct;
- the host publishes a replacement only after load, validation and initialization succeed.

**Data is permanent; code is transient.** Everything is gated by `--hcr`; a normal build
pays no vtable cost and must remain output-identical.

The design combines four proven contracts:

- explicit lifted state and function tables from native C game/tool hosts;
- dependency-order initialization, copy-load artifacts and generation cleanup from nimhcr;
- incomplete-image retry and rollback from cr.h;
- BEAM's current/old generations and external-call switch boundary.

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

1. **Re-pin the foundation:** recreate a minimal single-image POSIX probe proving state
   survives a body-only reload and incompatible layout fails loud.
2. **Input-keyed per-module build:** skip emission/compile/link for unchanged modules and
   produce one generation artifact per alive module.
3. **Module ABI manifest:** assign stable exported slots and classify reload, dependent
   reload, or restart.
4. **VTable transform:** rewrite cross-module exported calls through current module tables;
   keep private/same-module calls direct. This belongs in native transform, not C codegen.
5. **Transactional loader:** current/old/candidate registry, copy-load, dependency ordering,
   bad-image retry, rollback, handlers and safe-point API.
6. **DRC/TypeInfo contract:** stable TypeInfo ownership and exactly-once destructor behavior
   across accepted reloads.
7. **Watch/deploy adapters:** save-triggered rebuild, host notification, Windows copy-load,
   macOS/iOS Simulator loading, and development-signed iOS device deployment.
8. **Diagnostics and measurement:** exact rejection reason and edit-to-visible timing.

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

This is architecture scope. The current implementation is only a single-image POSIX
prototype.

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
- [nimhcr](https://github.com/nim-lang/Nim/blob/devel/lib/nimhcr.nim) — dependency-order
  reload, generation cleanup and lifecycle handlers.
- [Visual Studio C++ Hot Reload](https://learn.microsoft.com/en-us/visualstudio/debugger/edit-and-continue-visual-cpp)
  — stale-frame constraints; not an implementation dependency.
