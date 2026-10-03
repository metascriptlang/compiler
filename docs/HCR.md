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
| Per-symbol state cells | Windows x64 and Linux x64: `hcrRegistryVariables` checks add/remove/reintroduce state, selective integer/string resets, initializer rollback/recovery and preserved values |
| POSIX `dlopen` probe host | Native Linux `examples/hcrProbe/run.sh`: stable count storage, calls 10→40→30, added variable accepted, corrupt image rejected and current call returns 40 |
| Windows `LoadLibrary` probe host | `hcrWindowsReload` now accepts an added variable while preserving count storage; corrupt images leave current callable |
| Per-module native object cache | Implemented by generated-C fingerprints; `src/test/hcr/run.ms` proves a body-only edit recompiles only the changed module |
| Per-module shared libraries | Windows x64 and Linux x64: a non-reloadable `<stem>.core.<ext>` (runtime, std, registry) plus one image per project module, guarded by `src/test/hcr/run.ms` (`hcrIndirect`): the unrebuilt app calls a reloaded `logic` image. macOS link flags exist and have never run |
| Cross-module symbol cells | Windows x64 and Linux x64: `hcrIndirect`, `hcrSharedVariable` and `hcrRegistryGeneric` check unchanged callers, exported state/consts and private dependencies of concrete instances |
| Transactional registry | Windows x64 and Linux x64: `hcrEngine` and `hcrRegistryVariables` check staging, publish, rollback and recovery. Existing shared-value mutations are not undone |
| `@beforeReload` / `@afterReload` handlers | Windows x64 and Linux x64 checked by `hcrEngine`: old handlers quiesce, new handlers resume; a throw restores publication |
| TypeInfo across reloads | Windows x64 and Linux x64 checked by `hcrEngine`: stable class identity/method dispatch, restored metadata after rollback; incompatible class layout still requires restart |
| Watch build (`msc build --hcr --watch`) | Windows x64 (`ReadDirectoryChangesW`) and Linux x64 (inotify): rebuilds after each source save through a kept build session, guarded by `src/test/hcr/run.ms` (`hcrWatchWarm`: the C of a warm build equals a cold build's at every step of a replayed edit sequence, including constructor defaults, removed overrides and generic hook instances). macOS has no file-watch backend: `std/fs/watch` aborts with `file watching has no backend for this platform yet` |
| Crash rollback (`step(body)`) | Windows x64 and Linux x64, `hcrStepCrash`: a fatal runtime error, a stack overflow, an access violation or segmentation fault and an uncaught exception inside `step` each revert the last accepted reload and the program keeps running on the previous generation; the crashed image is skipped until the next build. One level |
| Old-generation purge | Not built: no accepted image is unloaded (see "Accepted generations stay loaded") |
| Function values across reloads | Windows x64 and Linux x64, `hcrFunctionValues`: a named function's value taken before a reload, a private one, one stored in a module-level object and code of the old generation all reach the newest generation; a closure keeps its own body; a held function writes the new cell after a type reset |
| Dependency reload | Windows x64 and Linux x64, `hcrFileDependency`: an edit of a `file:` dependency reloads its module image in the running app; `hcrImageNameCollision`: two modules mapping to one image name stop the build |
| `msc run --hcr app.ms` | Windows x64 and Linux x64, guarded by `hcrRun`: builds the images, watches the sources and runs the program under the host from `std/hcr`; see "Running an app" |
| iOS and automated deploy loops | Not implemented |
| Neon Fast Refresh integration | Contract defined here; implementation belongs to the Neon repo |

On 2026-09-27, tree `565df01d46c8`, `MSC=./msc ./msc run src/test/hcr/run.ms --target=raiser`
printed `ok` for twelve cases on Windows 11 x64 (zig; `hcrCoreLinkClang` skipped) and for
twelve on WSL Ubuntu x64 with a gcc-built compiler of the same tree (`hcrWindowsReload` runs on
Windows only).

Registry cutover, 2026-10-01, Windows x64, candidate `mscRegistry.exe`: sixteen focused
consumer cases passed, zero failed. The three new registry cases also fail on the old compiler
with its matching `std`/`runtime`: exported variables and generic exports are refused; the
eight-generation state program answers `RestartRequired` instead of accepting additions.
Measured source/fixture tree: `f2440d43f9bf197f5d0982826fcee0573c1ed8d6` (`68f9b701`).
Commands: `MSC=./mscRegistry.exe msc run out/registrySmoke/registryCases.ms --target=raiser`,
the boundary/adjacent harnesses in the same directory, and the matching old-control harnesses.
Those harnesses only selected permanent cases from `src/test/hcr/run.ms` and were removed
after proof; the indexed runner and fixtures retain the behavior matrix.
Linux x64: the three registry cases and `hcrIndirect`/`hcrEngine` passed; the native POSIX
probe printed `PROBE PASS` with 10→40→30→40 and one stable count address. The Linux candidate
was bootstrapped with clang; a gcc bootstrap attempt failed on pre-existing anonymous-pointer
emission incompatibilities and is not counted as a registry failure or a passing build.
Native POSIX script uses gcc. The Windows-to-Linux script retains zig but was not rerun.
The origin/main crash investigation, full gate, macOS, new Linux watch timing and call cost
are not covered by these proofs.


Implementation anchors: `src/transform/native/hcrLift.ms` `liftHcrState`,
`src/compiler/cache.ms` `moduleCompileFp` / `isCCodeCached`, `runtime/hcr.h`,
`runtime/hcrHost.c`, `examples/hcrProbe/hostWindows.ms`, `src/test/hcr/run.ms`, the
`--hcr` branch in the compiler build driver, and `src/compiler/buildSession.ms` with
`cmdWatchC` for `--watch`.

## Architecture decision

MetaScript uses **cooperative indirection**, not debugger-driven binary patching:

- persistent data lives outside reloadable code;
- functions and variables crossing a reload boundary resolve stable symbol cells;
- calls inside the emitted unit remain direct, including private functions;
- the host publishes a replacement only after load, validation and initialization succeed.

**Data is permanent; code is transient.** Everything is gated by `--hcr`; a normal build
pays no cell-indirection cost. The off-mode consumer was checked on C and JS; broader output
identity is not claimed by that control.

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

### Per-symbol registry (selected 2026-09-30)

The previous module-grained representation caused the gaps measured on this arc: adding a
variable required restart, exported variables could not cross images, private state could not
be reached by a moved instance, and adding an export invalidated every unrebuilt dependent.
The old evidence below records the trigger; the registry pins above record the cutover.

Measured on 2026-09-29, Windows x64, `mscB2.exe` (compiler sources of `c4db5a18`, tree std of
`1c67043b`), probe `out/pc/cst` (`msc run app.ms --hcr`, the app rewrites `logic.ms` and calls
`reload()`): `const SPEED = 5` → `7` printed `start 501`, `reloaded logic 702` (the new value,
because `constFold` inlines numeric and boolean module consts at every use), while
`const TITLE = "ab"` → `"abcd"` printed `start 201`, `reloaded logic 202` (the old value: the
string const is lifted state and its initializer ran only on first load). That discrepancy
is pinned by the registry's numeric/string exported-constant edit consumer.

How the references answer the same questions. "read" = code or documentation read this
session; nothing in this table was run except the MetaScript column.

| question | Nim (read: `lib/nimhcr.nim`, `compiler/cgen.nim`, `ccgstmts.nim`, `ccgexprs.nim`, `sighashes.nim`) | C / C++ / Rust / Zig (read) | Flutter, Erlang | MetaScript before cutover (run) | registry contract |
|---|---|---|---|---|---|
| where state lives | one heap allocation per global, `hcrRegisterGlobal(module, name, size)`; the global becomes a pointer (`genGlobalVarDecl`) | cr.h: byte copy of the `.state` section (`CR_STATE`); subsecond: "Globals are tracked across patches"; RCC++: objects serialize themselves, shared state in the host-owned `SystemTable` (`ObjectInterfacePerModule.h`); VS C++ Hot Reload: "Most changes to global or static data" unsupported | Flutter: "Global variables and static fields are treated as state"; Erlang: no module variables, state lives in processes | one `_GlobalState` per module | one registry cell per variable, keyed by module, name and type |
| add a variable | allowed: "new globals can be introduced when reloading"; its initializer runs because registration returns `true` | subsecond: "You may add new globals at runtime"; cr.h default `CR_UNSAFE` accepts a grown section by size only | — | restart (layout hash) | allowed; only its initializer runs |
| change a variable's type | the key is name + owner chain (`hashNonProc`), and an existing entry is returned whatever `size` is passed: the new code overruns the old allocation | subsecond: "renames are considered to be _new_ globals", layout change: "the program will crash"; cr.h `CR_UNSAFE`: size must fit | — | restart | fresh typed storage; incompatible surviving bindings reject |
| edit an initializer | not re-run; a `const` is re-copied on every load (`genConstDefinition`: "the constant is reloadable & updatable") | subsecond: "Changes to static initializers will not be observed" | Flutter: "`const` fields are treated like aliases instead of state" | numeric/boolean const visible, string const ignored (above) | a `const` whose initializer folds to a literal is re-assigned on every load; everything else keeps its value |
| which functions another image can call | every proc: `hcrRegisterProc` / `hcrGetProc` by module and name | Zig #5260: "each reference to a global declaration is indirect, through the table of offsets"; subsecond: "detouring function calls through a jump table"; Live++: "linking it against existing code" | Erlang: fully qualified calls switch to the current module version | exported functions only | every function the image emits |
| form of the indirection | x86 jump instructions in executable memory; own TODO "ARM support for the trampolines" | Zig and subsecond: a data table | — | data: `handle->current[k]` | data: one cell per symbol, no executable writes |
| consistency at bind | none (`HcrGetSigHash` only answers "has it changed") | Live++ and VS: structural changes refused | — | one ABI key per module: any export change rejects unrebuilt dependents | per bound symbol: signature key for functions, type key for variables |
| removed symbol | global freed (`cleanupGlobal` → `dealloc`), proc entry dropped | subsecond: destructors of globals "will never be called" | — | n/a (layout change) | retired: storage and value kept until restart |

Decision:

- **One core-owned registry.** Identity includes module, C symbol and signature/type contract.
  Old contract versions remain distinct, so an old binding never reinterprets new storage.
  This extends the existing TypeInfo identity idiom rather than making reloadable images own
  persistent data. Registration/binding lookup is hashed; reads/calls do not perform lookup.
- **Images describe themselves per symbol.** Each image lists what it publishes (symbol,
  signature or type key) and what it binds from other modules (module, symbol, key); the
  engine checks every bind of the post-transaction image set before anything is published and
  names the image and symbol that must be rebuilt. This replaces the per-module
  `HcrAbiKey000` comparison and the manifest slot order; `HcrImports000` keeps only the edges
  that order initialization and handlers.
- **A caller binds what it uses.** The native transform lists, per unit, the other project
  modules' functions and variables its C references (moved generic instances included) and
  resolves those cells in `DatInit000`; calls inside a module stay direct. A reference the list
  misses cannot link, because an image links against core only.
- **Variables.** Registration is get-or-create; initialization follows dependency order.
  Pre-commit discard frees only fresh, uninitialized storage. After publication, rollback
  retains rejected storage/images because a callback may have escaped. A removed or replaced
  value also remains retained; reintroducing its name allocates fresh storage. Same-key value
  mutations are not undone. These boundaries are checked by `hcrRegistryVariables`.
- **C representation stays typed.** `liftHcrState` uses a one-field `StructDecl` per variable
  and the normal emitter spells its type. This reuses the old typed-field idiom without a
  whole-module layout: nested `Ptr`/`Ref` modifiers collapse in our C type representation, so a
  bare pointer-to-pointer would not represent a variable slot. The wrapper's field is the value;
  no hand-written C type table or pointer-depth rule is added to the emitter.
- **Init runs on every load.** `Init000` runs for every candidate after commit, not only for a
  new module: a statement runs on first load only, an initializer when its cell is new, a const
  alias always. An initializer that throws rolls back like a throwing after-handler. Nim does the
  same through `if (hcrRegisterGlobal(...)) { init }` inside `Init000` (`ccgstmts.nim`).
- **Replaced:** `_GlobalState`, `_MS_STRUCT_HASH`, `_hcr_handover` and the engine's handover
  step; `hcrSharedVariable`; module slot tables. Kept: TypeInfo registry and `HcrTypeKeys000`
  (class layouts still restart), transactions, handlers, generations.

Rejected:

- **Extending module tables to private functions:** adding any function would change the table
  every dependent indexes, so a private helper added to `logic` would force `app` to rebuild.
- **Slot indices kept stable by the compiler across builds** (append-only in the `.hcrabi`
  bundle): ties an image's meaning to the bundle's history, the dependency "Images describe
  themselves" rejected for the ABI key.
- **An append-only `_GlobalState`** (cr.h `CR_UNSAFE` style): inserting, reordering or removing
  a variable shifts every later field, and it still gives other images nothing to bind.

Selected type-change contract: give that variable a fresh cell and initializer, retain the old
value, and name the reset in `lastReload().reason`. A surviving caller bound to the previous
type makes the transaction `Rejected`, naming the caller and symbol to rebuild. Integer and
string type changes, and incompatible imported bindings, are separate checked variants.

Selected function-value contract (2026-10-02): every published named function begins with
`if (msHcrMoved(self, &F)) return current(args)`, so a call that lands on an older
generation's body continues in the current one; a closure pair of a named function holds
`msHcrFunctionValue(cell)`, the address of the first committed generation, which is the same
value before and after a reload. Lifted lambdas and generated functions keep their generation:
their names are positional. A changed signature is a new cell, so a held value of the old
signature keeps the old body. Rejected paths: snapshot semantics with handler rebinding (a held
`onFrame(update)` and old-generation calls stay old, and after a type reset a held function
writes the retired cell, measured 2026-10-02: `held-tick 12, 13` against `snapshot 100`), and a
per-function trampoline in the owner image (needs a cloned signature per function; the
prologue reuses the existing cell and parameter names). Nim forwards only calls made through
its trampoline and keeps same-module calls of old code on `_actual`; this contract also
forwards those, as Dart and Live++ do. Measured: `hcrFunctionValues` red on `b5857d02`, green
on the candidate, Windows x64; green on Linux x64 (WSL Ubuntu, a zig cross-built compiler of
`5ef59610`, the whole hcr runner 23 ok). Not measured: raw C
function pointers to a named function, `==` between function values (C rejects it on `main`
too: inbox `2026-10-02-function-value-equality-c`).

Per-call cost, `examples/hcrBench` (50M calls of `x + 1`, Windows x64, zig, 2026-10-03, shared
machine): at the default `-O0` a plain build takes 1.48 ns per same-module call and 1.51 ns per
cross-module call; `--hcr` took 6.7 and 7.7–8.0 ns, and 3.3–3.6 and 3.6–3.9 ns once the cell
reads, the prologue check and the Windows image TLS base were forced inline without UBSan checks.
The rest at `-O0` is the prologue's loads and the `msErr` check after each call reaching core
TLS. At `--release` a plain cross-module call takes 0.74 ns and an HCR one 1.07–1.09 ns; a
same-module call is inlined away in a plain build and costs 0.47–0.62 ns under HCR.

Selected dependency contract (2026-10-02): a module of a `file:` dependency or of a locked git
or registry dependency builds its own image, id `<package>/<path>`, exactly like a project
module; std, the runtime and a module outside the project and its dependencies stay in the
core image. `msc run --hcr` and `--watch` also watch each `file:` dependency's folder. Two
modules whose ids map to one image name (`a/b.ms` and `a.b.ms`) stop the build and name both.
The reference reloads every module but the main one and those marked non-reloadable
(`isReloadable`, ccgtypes.nim:1235); a package is an ordinary module there. Measured on Windows
x64: `hcrFileDependency` answered `RestartRequired` ("the core image changed") on `bcdf6556` and
reloads the dependency with its new body on the candidate; `hcrImageNameCollision` built three
images into two files on `bcdf6556` (one overwritten) and stops on the candidate. Both pass on
Linux x64 in the same WSL run. An edit of the dependency also reloaded the entry image
(`reloaded greeter/index,app`) on `8cf8901c`: the prelude replays its own type instances
(`UntypedTree<JsonValueData, string>`, `Map<number, string>`) into whichever module check asks
for it first, so a cold build gave them to the entry module and a warm one did not. The
prelude's rows now carry a flag and always join the shared rows (`collectTypeInstanceRows`'s
first module); instances a module creates over its own types stay with it
(`hcrNewInstance`). `hcrFileDependency` now expects `reloaded greeter/index` alone.

Not verified: how Live++ keeps globals (its
documentation does not say); whether Zig's issue #5260 design is what ships.

## Runtime invariants

Automatic safe-point detection, old-image purge and rebuilding long-lived closures are not
claimed. Those remain explicit application lifecycle responsibilities.


1. **Off means absent.** `--hcr` off emits no HCR ABI or indirect calls.
2. **Calls select a generation deliberately.** Cross-image calls enter the current symbol
   cell, and a named function's body forwards to the current generation when it is not it. A
   frame already executing old module code stays old until it returns.
3. **Publication is transactional.** The loader holds `current`, `old` and an unpublished
   `candidate`. Candidate failure leaves current callable.
4. **Old remains available.** Rollback restores the previous publication; accepted and
   exposed rejected generations remain mapped until restart.
5. **No speculative purge.** Repeated reloads retain old code/storage rather than freeing
   memory that a frame or callback might still reach. Purging requires a separate safe-point proof.
6. **Function identity is the first generation.** A named function's value is the address of
   its first committed generation and forwards; a closure keeps its own body. Re-create
   long-lived closures in handlers.
7. **Variable and object compatibility are distinct.** Adding/removing module variables is
   allowed; a changed variable type resets that value only, subject to surviving binding checks.
   A class/interface/struct layout change still requires restart.
8. **TypeInfo identity survives accepted reloads.** Live DRC objects can retain TypeInfo
   pointers and destructor dispatch; unchanged layouts require stable addresses and an
   atomic function-table update.
9. **Never load the build output in place.** Copy a complete artifact to a generation path.
   A watcher observing an incomplete image retries that candidate without disturbing
   current.
10. **A crash reverts one accepted reload.** `step(body)` runs the body under a guard; a fault,
   fatal runtime error or uncaught exception reverts every module of the last accepted
   transaction to the cells, storage and TypeInfo it replaced, re-runs the restored after-reload
   handlers, and marks the crashed image's file identity so it is not loaded again. State the
   crashed pass wrote stays as written; values its abandoned frames owned are leaked, not freed.

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
non-reloadable host, from the `@beforeReload` / `@afterReload` handlers ("Host runtime (S4)").

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
module image, so its cross-image edges are symbol cells, the TypeInfo registry and core.
Each image exports initialization and publish/bind metadata; `DatInit000` registers storage
and functions and first calls the idempotent `msHcrCoreInit()`, which runs the
standard-library inits once. A module id `core` is rejected, because it would collide with
the core image name.

The core image takes the target's shared-library extension (`.dll`, `.so`, `.dylib`)
whatever `--output` is named, because on Linux and macOS it is a link input of every module
image, and zig's driver classifies inputs by extension. Measured with zig 0.16.0 on
2026-09-24, linking an image against a core named `core.hcr` fails with `unrecognized file
extension` for both `aarch64-macos` and `x86_64-linux-gnu`; the same file named `core.so`
links; `-l:core.hcr` panics (`TODO`) for macOS and is not found for Linux. A macOS host
reported the failure as `FAIL hcrModuleObjectCache` under the default `zig cc`. The Windows
lane pins the name (`hcrModuleObjectCache`) and the naming rule (`hcrCoreImagePath` test).
Not verified: the macOS and Linux lane after the fix, including `hcrCoreLinkClang`, which is
skipped on Windows because `--cc=clang` there targets msvc and rejects `-fPIC`.

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
  …TypeInfo`, which fails a split link. The TypeInfo of a project module's class, interface
  or boxed array cell is reached through `#define <C>TypeInfo (*_ms_hcr_ti_<C>)`, resolved
  in DatInit from `msHcrTypeInfo(owner, name)`: registered once by name and returned at the
  same address across generations, as the reference registers type info in its registry.
  An image declares that pointer only when its own code uses the TypeInfo, as the reference
  declares another module's type info only where it is used, so an edit that gives a module a
  new type leaves its importers' C unchanged. Until 2026-10-03 every image declared every project TypeInfo, and an array edit
  in `logic` reloaded `app` too (`hcrTypeInfoLocality`, red on the old compiler for an array
  cell and for a class).
- **DRC hooks.** A lifecycle operation has one definition, in the module whose lowering
  first needs it. Another project image that calls it reaches it through the owner's handle
  table: after DCE the owner appends every generated operation another image uses
  (`compile.ms` `completeHcrTables`), and its ABI key covers those slots; a reload that
  changes them is not measured. A reference array's cell TypeInfo is registered
  by its owner in the core registry, like a class's. Per-image copies were tried first; the
  C emitter keeps one definition per `__` name, so the consumer kept only a declaration and
  failed the split link (`hcrArrayOwner`).

Methods of exported classes were missing from the S3a DCE roots although their table slots
referenced them (`use of undeclared identifier 'Shape_area__…'`); every manifest function is
now a root. A project module importing an exported variable of another project module is
rejected before codegen with `HCR cannot share exported variable '<id>::<name>' with module
'<id>' across module images`. Without that check both `export const` and `export let`
failed the link with `undefined symbol`.

On 2026-09-23, Windows 11 x64 with zig 0.16.0, the S3b branch rebased on `f9ce6c7b`,
`MSC=out/msc-s3b2.exe out/msc-s3b2.exe run --target=raiser src/test/hcr/run.ms` printed
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

### Host runtime (S4)

The reload engine is `std/hcr/engine.cms`, linked into the core image; the registry and the
Win32 loader edge stay C (`runtime/hcr.c`, `runtime/hcrEngine.h`). A thin host copies
`<stem>.core.dll` into `<dir>/.hcr/<pid>/core/`, loads it, calls `msHcrLaunch(dir, stem)` and then
`msHcrEngineStart`; the fixture host is `src/test/hcr/fixtures/engine/host.ms`. The program
imports `reload` from `std/hcr` where it wants reloads to happen and calls it at its safe point
(the Neon frame loop); it answers `NoChange`, `Reloaded`, `Pending`, `Rejected` or
`RestartRequired`, and `lastReload()` gives the modules and the reason of the last call.

`std/hcr` (`std/hcr/index.ms`) builds on every backend, with or without `--hcr`. `reload` is a
macro chosen by `when (hcr)`: under `--hcr` it expands to a call into the engine, which only then
is imported; without it, to the constant `ReloadKind.NoChange`, so a production build emits no
call and links no engine. The reference ships the same pair: `lib/core/hotcodereloading.nim` is
imported explicitly and turns `performCodeReload` and the handler templates into `discard` when
`hotcodereloading` is not defined, and `--hotcodereloading:on` defines that symbol
(`compiler/commands.nim`); `--hcr` defines `hcr` the same way. The import stays explicit, not a
global import: a program decides where it reloads. On 2026-09-28, Windows x64, `hcrReloadOff`
ran a loop over `reload()` without `--hcr` on C and JS (`no change`, no warning), and no C file
of that build named the engine; the compiler of `91dbf527` failed it (JS cannot import the
C-only engine).

The shape follows nimhcr (`lib/nimhcr.nim`: `hcrInit`, `recursiveDiscovery`, `initModules`,
`hcrPerformCodeReload`, `hcrAddEventHandler`) with these decisions:

- **Images describe themselves.** Every module image exports `HcrModuleId000`,
  `HcrAbiKey000` and `HcrImports000`, the analogue of nimhcr's `HcrGetImportedModules` and
  `HcrGetSigHash`. The key is `hcrExportKey` over the S2 manifest without its dependency
  list, so it changes exactly when a dependent must reload. Before anything is published,
  every import edge of the post-transaction module set must carry the key of the image it
  would bind to; otherwise the reload is `Rejected` and names the module to rebuild. Reading
  the `.hcrabi` bundle instead was rejected: it can disagree with a copied image, and it cannot
  describe the generation that is already loaded.
- **The bundle is the trigger.** `reload()` stats only `<stem>.dll.hcrabi`, which the compiler
  writes after every link succeeds, and then compares each image's size and write time. A
  `stat` cost 10 µs on this host, so polling every image each frame would cost about 1 ms for
  100 modules. nimhcr compares each module's modification time.
- **Copies are immutable.** Every image is copied to `<dir>/.hcr/<pid>/<generation>/` before
  it is loaded, so the build directory is never locked. A copy in another directory binds to
  the core that is already loaded, because Windows resolves an import by base name (one
  `module.core.dll` in the process after loading a copy from `.hcr/2/`). Images name their PDB
  without a path (`PDBFileName: module.logic.pdb`), so the path patching that cr.h does
  (`cr_pdb_replace`) is not needed.
- **A bad image is retried, not trusted.** A load or copy error (`193` for a truncated image,
  `32` for a file the linker still holds) returns `Pending` and is retried only when the file
  changes, as cr.h's `CR_BAD_IMAGE` retries on the next update.
- **Publication is one transaction.** Under `msHcrStageBegin` a candidate's `DatInit000` stages
  its table instead of publishing it. The engine commits every staged table after the
  lifted-state handover and the before-handlers succeed. Each handle keeps `current`, `old` and
  `staged` tables.
- **Handlers are image exports.** `@beforeReload` and `@afterReload` mark a module-level
  `(): void` function; the checker gives it a deterministic C name, which makes it a
  dead-code root, and each image wraps its handlers in `HcrBeforeReload000` /
  `HcrAfterReload000`. nimhcr registers handlers from `Init000`, but a MetaScript reload never
  reruns first-load initialization, so a registered handler would keep pointing into the old
  image. Handlers run leaf to root: before-handlers on the current generation after the
  candidates are validated, after-handlers on the new generation once it is published.
- **Rollback restores tables, not state.** A throwing after-handler rolls every committed
  table of the transaction back and returns `Rejected`. cr.h also restores backed-up
  `.state`/`.bss` sections (`cr_plugin_sections_reload`). Lifted state holds DRC references,
  so restoring its bytes would corrupt reference counts, and lifted state is left as the new
  code wrote it.
- **A crash returns to the guard, never through the OS dispatcher.** `msHcrGuardRun` arms a guard
  on the calling thread. POSIX catches SIGSEGV, SIGBUS, SIGILL, SIGFPE and SIGABRT on an
  alternate stack and `siglongjmp`s back; Windows captures the guard's registers with
  `RtlCaptureContext`, and its vectored handler copies them into the faulting context and
  returns `EXCEPTION_CONTINUE_EXECUTION` (a stack overflow then re-arms the guard page with
  `_resetstkoflw`). A fatal runtime error (`msRaiseIndexError` and the rest) reaches the
  guard through `msFatalTrap` before it would exit. A guard is owned by one thread; a fault on
  another thread ends the process as before. The guard state is a process-wide pointer plus the
  owner's thread id: a vectored handler runs for every thread, and `core`'s TLS read from one
  returned garbage on 2026-10-03. Like cr.h, nothing the crashed code held is released.
- **Accepted generations stay loaded.** No accepted image is unloaded, as RCC++'s
  `RuntimeObjectSystem` never frees a module. Twenty extra generations of `logic` cost about
  70 KB of private memory each. Purging old generations needs proof that no frame or callback
  still reaches them.

Traps measured while building it:

- One explicit `__declspec(dllexport)` in core C turns lld's export-all off, even with
  `-Wl,--export-all-symbols` on the link line: the core's exports fell from 851 to 1, and every
  module image failed to link `msHcrPublish`. Core C therefore uses no `MS_HCR_EXPORT`.
- Core is linked from what the program reaches. An edit that starts using a standard-library
  routine the old core lacks relinks core, and `reload()` answers `RestartRequired`. An image
  loaded against the old core fails with loader error `127`.
- A loop that runs inside the entry module calls its own module directly, so it stays on the
  generation it started in; only calls through a module table see new code. nimhcr avoids
  this by keeping its main module unreloadable.

On 2026-09-23, Windows 11 x64 with zig 0.16.0, tree `add20d0a491aec1f1b573d5f8addf47012603bf1`,
`MSC=out/msc-s4c.exe out/msc-s4c.exe run src/test/hcr/run.ms
--target=raiser` printed `ok hcrModuleAbi`, `ok hcrIndirect`, `ok hcrEngine` and
`ok hcrWindowsReload`. The `hcrEngine` app places prebuilt generations into the watched
directory from inside the running images and calls `reload()`:

```
HCR-ENGINE start: value 10 tick 1 version 1
HCR-ENGINE body edit: reloaded logic
HCR-ENGINE after body edit: value 73 tick 11 version 1
HCR-ENGINE truncated image: pending logic (cannot load run/module.logic.dll (error 193))
HCR-ENGINE same truncated image: pending logic (run/module.logic.dll is not a loadable image yet)
HCR-ENGINE complete image: reloaded logic
HCR-ENGINE lifecycle v2: after reload
HCR-ENGINE after-reload handler throws: rejected lifecycle (the after-reload handler of module 'lifecycle' threw; rolled back lifecycle)
HCR-ENGINE after rollback: value 10 tick 13 version 1
HCR-ENGINE added export, app not rebuilt: rejected (module 'app' was built against another export ABI of 'logic'; rebuild it)
HCR-ENGINE state layout changed: restart required logic (the lifted state layout of module 'logic' changed)
HCR-ENGINE core changed: restart required (the core image changed (runtime, standard library or toolchain))
```

The same runner stops at `HCR: run/module.dll is not an HCR module image` on a compiler
without `HcrModuleId000`, and prints `after rollback: ... version 2` when the engine skips
`msHcrRollback`. Not verified: a module that first appears during a reload (written, no
fixture), POSIX and macOS loaders, and reload latency (S6).

### TypeInfo across reloads (S5)

A class's TypeInfo lives in the core registry (`msHcrTypeInfo`, keyed by owning module and
class), so every generation of every image shares one address. Objects keep that address in
their header, and `instanceof` compares against it. An accepted reload rewrites the entry's
contents from the new image's `DatInit000`: old objects then run the new methods and the new
destroy hook, exactly once. nimhcr does the same (`genTypeInfoAuxBase` registers the TypeInfo
through `hcrRegisterGlobal`, which returns the existing global, and the type-init code
overwrites it).

Two gaps were measured before the fix. The fixture had four generations of a `shapes` module,
and a `Square` built in generation 1 was kept alive:

| case | before (`73bf8ce8`) | after |
|---|---|---|
| candidate with another destroy hook, rejected by its after-handler | tables back on v1, object destroyed by `destroy v2` | `destroy v1` |
| field added to the base class `Shape` | `reloaded shapes version 4`; the g1 object destroyed by v4 code reading `label` past its allocation | `restart required shapes (the layout of type 'Shape' in module 'shapes' changed)` |
| body edit | `instanceof true`, `area 1025` (new code), one destroy | unchanged |

- **Rollback restores TypeInfo.** `msHcrStageBegin` saves every registry entry, and the
  engine calls `msHcrRestoreTypeInfos` for each rolled-back module. This is cr.h's section
  backup (`cr_plugin_sections_backup` / `cr_plugin_sections_reload`) applied to TypeInfo alone,
  and it is sound there because a TypeInfo holds no reference counts. Lifted state still is
  not restored. Staging TypeInfo contents in a draft copy was rejected: S4 rolls back only
  after commit, so the new tables are already live while after-handlers run, and a draft would
  not give a stronger guarantee than that. It would also need every `base` pointer relocated
  at commit.
- **A layout change is a restart.** Each image exports `HcrTypeKeys000`, which gives the
  name and `hcrLayoutKey` of every top-level class, interface and struct. The key lists the
  fields in order with their `monoTypeKey`, and a class's fields include the inherited ones,
  so a base-class edit changes every subclass's key. Before any handover, a candidate whose
  key differs from the loaded image's for the same type answers `RestartRequired` and names
  the type. The rule is the lifted state's structural hash (`_MS_STRUCT_HASH`) extended to
  heap types, and cr.h's `CR_SAFE` section-size check applied to classes. nimhcr leaves this
  open (`nimhcr.nim`: "changing memory layout of types - detecting this..?"). RCC++ migrates
  instead: `ObjectFactorySystem::ProtectedObjectSwapper` serializes every tracked object into
  a newly constructed one. That needs every object reachable by ID, while MetaScript
  references are raw pointers to fixed-size allocations. Accepting a layout change when no
  object of the type is alive would need a live counter on the DRC allocation path; with
  Neon's widget tree alive across frames, it would rarely apply.

On 2026-09-24, Windows 11 x64, tree `8e86371d` with candidate `out/msc-s5b.exe` built from the
compiler sources of `7d8b5c42`,
`MSC=out/msc-s5b.exe out/msc-s5b.exe run --target=raiser src/test/hcr/run.ms` printed `ok` for
all four cases, with these lines from `hcrEngine`:

```
HCR-ENGINE lifecycle rebuilt: reloaded lifecycle
HCR-ENGINE probe from the first generation: instanceof true true scaled 70
HCR-ENGINE after-reload handler throws: rejected lifecycle (the after-reload handler of module 'lifecycle' threw; rolled back lifecycle)
HCR-ENGINE probe after rollback: instanceof true true scaled 70
HCR-ENGINE lifecycle v1: destroy probe 7
HCR-ENGINE class layout changed: restart required lifecycle (the layout of type 'Probe' in module 'lifecycle' changed)
```

Each pin was proven red by removing the mechanism it guards:

| mechanism removed | output |
|---|---|
| restore on rollback (runtime of `73bf8ce8`) | `lifecycle v2: destroy probe 7` |
| the layout check | `class layout changed: reloaded lifecycle,logic` |
| registry reuse during a reload | `instanceof true false` (an object built by the new code, checked by the unrebuilt app) |

Not verified:
- TypeInfo that stays per image: generic instances (weak) and lambda environments (static).
  Objects of those types reach their image's destroy hook, which does no harm while every
  generation stays loaded, but a purge must account for them.
- A struct passed by value through an export: its layout key covers the declaring module,
  but no fixture exercises one.
- Destroy counts under the DRC ledger or ASan (this host has no `libasan`).

### Watch builds (S6)

`msc build <entry> --hcr --watch` builds once, then rebuilds after every save of a `.ms`,
`.cms` or `.h` file under the project root (`std/fs/watch`), until it is killed.
`--watch-replay=<file>` drives the same loop from a file of `<source> <target>` lines instead
of the file system, one copy and one build per line; `hcrWatchWarm` runs it. With `--emit=c`,
build *n* writes its C to `out/<mode>/watch<n>/`. Each build prints
`watch: build <n> <built|rebuilt|up-to-date|failed> in <ms> ms (checked a/b, lowered c)`, and
each trigger `watch: changed <paths>`. `--watch` without `--hcr` is refused; only the HCR path has a
warm-against-cold check (`hcrWatchWarm`).

The session (`src/compiler/buildSession.ms` `BuildSession`, `src/checker/orchestrator.ms`
`CheckSession`) keeps, between builds, the graph-bound TransAm db and prelude context, each
module's check with the generic function and type instances that check created, and each
module's native lowering (the TransAm `Lower` query, run on a clone of the checked tree so the
kept tree stays usable for later instantiations). Every build reruns the loader (a bound db
records no `.h` dependency, [`TRANSAM.md`](TRANSAM.md) §5), DCE, C emission, cc of changed C,
the link of changed images and the ABI bundle. A compile error ends the build, not the watch;
the next save continues from the kept session.

A module is checked again when its text, or any module it imports transitively, changed
([`TRANSAM.md`](TRANSAM.md) §3), and lowered again when it was checked again. A warm build has to
emit the C a cold build emits, and four inputs of a module's lowering come from other modules.
Each is compared with the previous build; a change makes the build start from scratch, with the
reason printed (`watch: rebuilding from scratch: …`):

| Input from other modules | Why it couples modules | Compared by |
|---|---|---|
| HCR export tables and the shapes of project types | every image carries every image's slot and TypeInfo macros (`hcrIndirect.ms` `lowerHcrIndirection`) | `hcrTablesFingerprint`, `projectTypesFingerprint` |
| generic function instances routed to the module | an instance is emitted in its owner's unit, usually a std module: one `Map<string, Item>` in a project module put 84 lines naming `Item` into `std/core/struct.c` | `instancesFingerprint` per owner |
| generic type instances | `monoEmitTypeInstNodes` emits every one into the first module lowered | the first module's fingerprint |
| hook symbols, hook and TypeInfo owners, type-bound operations | per-build global tables that lowering fills and emission reads (`codegen/c/types.ms` `_hookSyms` and `_opSyms`, `destructorLifting.ms` `_globalHookOwners` and `_globalTypeInfoOwners`) | recorded per lowering, replayed when it is reused, compared when it reruns |

So body edits stay warm; an added or changed export, a new generic use over a project type or a
changed type shape rebuilds from scratch.

Measured on tree `8981c4823812`, Windows x64 with the machine at 65 % load of 32 threads, the
`hcrWatchWarm` fixture (5 project and 46 std modules), `--watch-replay`, two rounds each:

| Step | `--emit=c` | `--output` (through cc and link) |
|---|---|---|
| first build | 1.06–1.36 s | 3.0–9.3 s |
| body edit (4 or 2 of 51 modules checked and lowered) | 99–107 ms | 0.94–2.12 s |
| type error | 27–29 ms | 26–28 ms |
| rebuild from scratch | 0.79–0.86 s | 2.2–6.2 s |

The same edits as one `msc build --hcr --emit=c` process each took 1.6–4.9 s (2026-09-25, same
host). A warm `--output` build is dominated by cc and link of the changed module; `reload()` in
the running app adds 0.45–0.56 s (measured 2026-09-24).

Rejected: relowering one green std module inside a warm build. Its output depends on the
instances routed to it from other modules and on hook ownership decided in load order across std
modules, so it is not equivalent to a cold build. Nim's per-module backend avoids the coupling by
emitting every definition a module demands into that module's unit and keeping one per C name at
merge (`cgen.nim` `findPendingModule`); that placement is a new mechanism, not taken here.

Edit to visible with a running program, `msc run app.ms --hcr` on `examples/hcrApp/` (55
modules), five saves of distinct `logic.ms` bodies written with `cat new > logic.ms`, timed from
before the write to the line the app prints after `reload()` answers `Reloaded`; tree
`565df01d46c8`, 2026-09-27:

| Host | Edit to visible | Build | Conditions |
|---|---|---|---|
| WSL Ubuntu x64, 24 cores, gcc, `--release` compiler | 289–300 ms | 232–243 ms | load 1.3–1.7 |
| Windows 11 x64, zig, `--danger` compiler | 824–902 ms | 687–728 ms | 20–51 % CPU from other sessions |

A split taken on Linux on 2026-09-26 (load about 3.5, tree not recorded): the watcher sees a save
in 3–4 ms, the settle waits 60 ms, the build takes 246–290 ms (front end and C emission about
70 ms, the rest `cc -c` and the link of `logic`), and `reload()` 1.9–3.0 ms. The Windows
`reload()` figure above (0.45–0.56 s, 2026-09-24) was not measured again; the 2026-09-27 runs
leave 100–180 ms between the end of the build and the visible line.

2026-10-02, WSL Ubuntu x64 (24 cores, load 0.13), a compiler of `6dfd6e04` cross-built with
`--os=linux --cc=zig --danger --lto=off`, `examples/hcrApp`, five saves by atomic rename: edit
to visible 344–401 ms, watch build 290–333 ms. A warm build of the same app under
`--watch-replay --time` (240–270 ms), with temporary probes around the image link: graph load
and check 62 ms, phase A 10 ms, phase B 12 ms, `cc -c` 15 ms (parallel), the core image's
link-cache check 23–24 ms, the `logic` image link 23–25 ms (gcc driver), the entry image's
link-cache check 6 ms, the project cache write 12 ms. No single step holds the budget: <100 ms
needs the settle (60 ms), the warm check, the link path and emission each cut. Tried and kept
out, A/B on the same host: computing the link-cache input key once per build instead of per
image (phase D unchanged, 70–90 ms both ways) and `-fuse-ld=lld` for image links (`logic` link
23–25 ms both ways: a small image's link is the driver's startup).

2026-10-03, same host, compilers of `9a36b5e6` and `3ab8bcec`, alternating runs. Every build
re-parsed the std prelude closure to rediscover its imports (`graphLoad preludeMods` 47–62 ms,
`seed=0`): the `.deps` file that seeds it was written only beside a `.pk` of the build's own
backend, and a graph build checks its prelude in the graph and writes none. The loader now writes
it: `preludeMods` 12.6–14.6 ms with `seed=1`, warm graph load and check 63–78 → 28.6–30.5 ms,
warm build 246–271 → 209–236 ms (load 0.00); edit to visible 391–479 → 343–425 ms over 10 saves
each (load 0.69–1.17). The `preludePack load=` figure every warm build prints is the first
build's: the counters accumulate per process and the pack loads once. What remains of the 30 ms:
reading and header-inlining 58 sources (about 13 ms), the entry tree (6 ms) and the check (8 ms).
In a long-lived process the reference reprocesses only modules marked dirty
(`compiler/pipelines.nim` `isDirty`); the watch session still rebuilds the graph from disk.

A writer that empties the file before writing it (`cat new > logic.ms` from Git Bash, whose fork
takes more than the 60 ms settle) can let a build read the empty file. That build fails with
`Cannot resolve module './logic'`, because the loader treats an empty module as a missing one (an
open loader bug), and the write's own event rebuilds and reloads: 5/5 saves on Windows, measured
with trace prints on 2026-09-27. Batches that arrive during the settle are dropped safely: their
writes precede the build's read. `hcrWatchWarm` replays an empty `logic.ms` between two steps to
pin that a failed module load leaves the kept session warm; it goes red when a failed load drops
the kept TransAm db.

A warm build keeps the checker's per-build registries, which are not reset between builds. A
rechecked module gets new symbols, so a registry keyed by symbol identity serves its new entries,
while one keyed by name served the previous check's entry. This is the split the reference keeps
between `attachedOps` (keyed by type identity) and `loadedOps` (keyed by a structural key and
replaced on re-registration, `setAttachedOp` in `compiler/modulegraphs.nim`). The instance hooks of
a generic class were the last registry keyed by name: the instances already scanned are now kept
per class symbol, and the entry for an instance name records the class symbol that produced it and
is dropped when a new generation of that class scans it. Warm C diffed against a cold `--emit=c` of
the same sources, one edit in a module-local class:

| Edit | `b899f456` | main `91dbf527` (tree `04c852acc7fc`) | tree `6f81673a0003` |
|---|---|---|---|
| constructor default `4` → `40` | warm passes `4` | equal | equal |
| `area()` override removed from `Circle` | still dispatched | equal | equal |
| any edit in a module with a generic extension `onDestroy<T>` | hook instance missing | missing | equal |

The missing hook instance also showed on a rebuild from scratch, because
`resetInstantiationState` did not clear the hook tables; it does now. `hcrWatchWarm` replays these
edits through `box.ms` (`boxHookBody` … `boxNoHook`, including a removed hook and two edits in a
row); on the compiler of `91dbf527` it fails at the first step that rebuilds from scratch
(`logicMap.ms`), and with the `box` steps moved first, at `boxHookBody.ms`.

Not verified: a live watch on macOS (no backend), a project with import cycles, and edits to
`build.ms` during a watch (it is not re-read).

### Running an app

`msc run app.ms --hcr` (`cmdRunHcr`, `src/compiler/compile.ms`) builds the host from
`std/hcr/host.cms` into `out/hcr/host`, builds the images into `out/hcr/<stem>.<ext>` through the
watch session above, runs the host on them as a separate process, and rebuilds after every save
until the host exits; the host's exit code is `msc run`'s. The host copies the core image into
`.hcr/<pid>/core/`, loads it and calls `msHcrLaunch` and `msHcrEngineStart`. The engine runs the
modules' inits and then the rest of the generated main, so pending async work finishes and an
unhandled rejection exits 1, as it does without `--hcr`.

The watch loop learns that the host ended from a `Locked<HostExit>` that the spawned task writes.
Awaiting the spawn's Promise with `.then` from the loop was rejected: a spawn Promise is affine
and bound to the scope that made it, and the checker refuses it inside a function.

Each run copies its images under `.hcr/<pid>/`. At start the engine removes the directory of
every pid that no longer runs (`sweepEndedRuns`, `std/hcr/engine.cms`; `msHcrProcessAlive` opens
the process and waits on it on Windows, and calls `kill(pid, 0)` on POSIX; a process it may not
open counts as alive), so a run's copies stay until the next start. nimhcr unloads a module and
overwrites one `<name>.copy.<ext>` next to it (`lib/nimhcr.nim` `loadDll`) and never deletes it;
here accepted generations stay loaded, so each needs its own file, and the engine cannot delete
its own directory at exit, because it runs from the core image in it and Windows refuses to
delete a loaded DLL. On 2026-09-27, Windows x64 and Linux x64, `hcrRun` placed three directories
before the start: `999999998` was removed, the pid of a live system process (`4` on Windows, `1`
on Linux) and `notARun` stayed. The installed compiler of `c54a8671` left `999999998` in place.

A program that never imports `std/hcr` has no engine in its core image, so nothing would ever
reload it. `msc run --hcr` stops that build with `error: app.ms never imports std/hcr, so nothing
calls reload() and an edit would never reach the running program; import { reload } from
"std/hcr" and call reload() once per pass of the main loop`, and keeps watching: the save that
adds the import starts the host (`hcrHostMissesEngine`, measured on Windows 2026-09-28; the lane
cannot drive a waiting `msc run`, so the inline test in `compile.ms` holds the check and `hcrRun`
holds the path of the engine). Before, the host started and stopped at `HCR-HOST the core image
does not export msHcrEngineStart`.

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

Windows x64 and Linux x64 run the whole loop: per-module images, vtable dispatch, the module
registry, watch builds and `msc run --hcr` (see "Current status"). macOS has the loader code and
no file-watch backend, and has never run; iOS deployment is a later slice.

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

`examples/hcrApp/` has `app.ms` calling `logic.ms`; `src/test/hcr/run.ms` holds each item
except where noted:

- only `logic` rebuilds for a body-only change;
- unrecompiled `app` observes new behavior through the current vtable;
- persistent state survives;
- incomplete artifacts retry without disturbing current;
- load/init failure preserves or restores current behavior, a crash included (`hcrStepCrash`);
- a layout change reports restart-required;
- a live DRC object destroys exactly once through the accepted TypeInfo generation;
- old code purges only after safe-point proof (not built: every accepted generation stays
  loaded);
- a build without `--hcr` carries no HCR machinery (`hcrIndirect`).

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
