# Bare Metal / Freestanding Mode

Zig-inspired memory model for MetaScript targeting constrained environments (Solana/SBPF, WASM, embedded, kernel modules). Two orthogonal flags control memory management and platform target independently.

## Two Orthogonal Axes

### `--gc=` (Memory Management)

| Flag | Allocator | RC | Free | Use Case |
|------|-----------|-----|------|----------|
| `--gc=orc` | malloc | ARC + cycle collector | Yes (scope exit) | **Default**, desktop apps |
| `--gc=drc` | malloc | ARC (incref/decref only) | Yes (scope exit) | No cycle collection |
| `--gc=none` | malloc | None | Never | Debug, leak testing |
| `--gc=manual` | malloc | None | defer / manual free | Performance, game engines, libraries |

### `--os=` (Platform Target)

| Flag | Entry Point | libc | Globals | Mode | Use Case |
|------|-------------|------|---------|------|----------|
| `--os=auto` | `main(argc, argv, env)` | Yes | Yes | Full | Default, desktop |
| `--os=bare` | `main(void)` → `MsMain()` | No | Yes | Freestanding | Embedded, kernel |
| `--os=solana` | `entrypoint(uint8_t*)` | No | No | Contract | Solana/SBPF |
| `--os=wasm` | WASM export | No | No | Contract | NEAR, Cosmos, ICP |
| `--os=emcc` | emcc default | Yes (emcc's) | Yes | Full | Browser WASM via Emscripten |
| `--os=linux` | `main(argc, argv, env)` | Yes | Yes | Full | Cross-compile |
| `--os=macos` | `main(argc, argv, env)` | Yes | Yes | Full | Cross-compile |
| `--os=windows` | `main(argc, argv, env)` | Yes | Yes | Full | Cross-compile |

### Valid Combinations

| | `--gc=orc` | `--gc=drc` | `--gc=none` | `--gc=manual` |
|---|---|---|---|---|
| `--os=auto` | **Default** | No cycle collection | Debug/leak test | Performance, game engines |
| `--os=bare` | Not supported | Not supported | Not useful | Freestanding target |
| `--os=solana` | Not supported | Not supported | Not useful | Blockchain contract |
| `--os=wasm` | Not supported | Not supported | Not useful | Blockchain contract |
| `--os=linux/macos/windows` | Cross-compile | Cross-compile | Cross debug | Cross manual |

Key insight: three axes — `--gc` (memory management), `--os` (platform), and **mode** (full / freestanding / contract). Contract mode is triggered by blockchain `--os` targets and means: no mutable globals, no init guards, no TypeInfo, flat DCE'd codegen.

### `--os=emcc` vs `--os=wasm`

Both select `Backend.Wasm` (`src/compiler/compile.ms:98`) but drive different toolchains:

| | `--os=wasm` | `--os=emcc` |
|---|---|---|
| Compiler / linker | zig cc, `-target wasm32-wasi` (`cc.ms:321-326`, `:369-374`) | `emcc` (`compile.ms:931-934`) |
| Output | `.wasm` | **`.js` + `.wasm` pair** — suffix forced at `compile.ms:949` |
| Link flags | `-Wl,--gc-sections -Wl,--strip-all` | `-sWASM=1 -sALLOW_MEMORY_GROWTH=1` (`cc.ms:363-367`) |

### Standalone / custom-host wasm on the emcc path — works today, no compiler change

Verified 2026-08-10. A module for a host that provides its own ABI (SpacetimeDB, wasm component hosts) builds with existing flags:

```bash
msc build mod.ms --os=emcc --app=lib --output=mod.wasm \
  --passL="-sSTANDALONE_WASM=1 --no-entry -sALLOW_MEMORY_GROWTH=0"
```

Why each part is needed, and why no compiler patch is:

- **`--output=x.wasm`** — the `.js` suffix at `compile.ms:949` only applies when `outputPath === ""` (`compile.ms:938`). An explicit `--output` bypasses it, so emcc never runs the jsifier. Without this the jsifier hard-errors `undefined symbol: <name>` on any import it can't resolve to JS glue, including legitimate `import_module` imports from a non-`env` module.
- **`--app=lib`** — sets `noMain` (`compile.ms:1285`), so no POSIX `main` is emitted and `MsMain()` stays exported for the host to drive. Safe on this target specifically: `cliCompileFlags` and `cliLinkFlags` return early for emcc (`cc.ms:318`, `:366`) *before* the `-fPIC` / `-shared` branches that lib mode would otherwise trigger.
- **`--passL="…"`** — appended after the built-ins (`cc.ms:363-367`), so `-sALLOW_MEMORY_GROWTH=0` overrides the hardcoded `=1`. Leaving it at `1` emits an `env.emscripten_notify_memory_growth` import no non-browser host provides.

#### Init chain — and why you should not call `MsMain()`

With `--no-entry` nothing calls `main`, so the init chain never runs on its own. Bind it to whatever entry the host does call — for SpacetimeDB, an export matching its `__preinit__*` scan.

**What `MsMain()` actually is** (`src/codegen/c/index.ms`): `MsPreMainInner()` → every **alive module's** `__DatInit000()`; `MsMainInner()` → every alive module's `__Init000()`; then `msOrcCollect()`. It is not "initialize me", it is "initialize the entire program".

`MsMainInner` contains **only** `__Init000()` calls — there is no `main_()` invocation to suppress. The implicit auto-call of an unreferenced `main` was removed 2026-08-16 (`15df69d`); `genProjectDispatcher` no longer takes `autoCallMain`/`mainRetType`. Verified by probe: a program that defines `main` and never calls it prints only its top-level output and exits 0, on both the C and JS lanes. The program body is now whatever the entry module's `__Init000()` runs, so an entry whose top level does nothing still gets init without a body — that part is free, as before.

The expensive part is the module list. `computeAliveSet` (`src/checker/reachability.ms`, called at `compile.ms:1167`) is symbol-level and seeded from the entry path — and it does **not** see code introduced by `@emit`. For a do-nothing entry the alive set is still the whole prelude: 32 modules including `std/meta/node`, `std/serialize/json/*`, `std/core/fetch/*`, `std/core/websocket/*`, `std/net`, `std/crypto`. Rooting `MsMain()` from an exported function retains all of it.

Calling only the entry module's two init functions instead avoids that. They are emitted non-`static` and forward-declared in `_dispatch.c`, so they are directly callable:

```ms
@emit("extern void <mangled>__DatInit000(void);");
@emit("extern void <mangled>__Init000(void);");
@emit("__attribute__((export_name(\"__preinit__50_msinit\"))) void __preinit__50_msinit(void) { <mangled>__DatInit000(); <mangled>__Init000(); }");
```

Read `<mangled>` out of the generated `_dispatch.c` (`out/<mode>/.cache/_dispatch.c`).

**Measured 2026-08-10**, identical module otherwise:

| Entry point rooted | Size |
|---|---:|
| nothing (no init call at all) | 11,874 B |
| entry module's `__DatInit000` + `__Init000` only | **11,894 B** |
| `MsMain()`, entry defines no `main` | 550,519 B |
| `MsMain()`, entry has empty `main` | 550,554 B |
| `MsMain()`, entry `main` calls `console.log` | 555,047 B |

**46× on one line of C.** Note the last two rows: `console.log` costs ~4.5 KB, i.e. essentially none of the 538 KB is the program — it is prelude init.

⚠ **Correctness caveat**: targeted init initializes *only* that module. Any prelude module whose globals you actually touch needs its own `__Init000()` call added. The 11.9 KB figure is the floor for a module that uses nothing; a real module pays for what it uses. This is the same module-level DCE gap Phase 3b describes for Solana — it does not block a wasm build, it just means the init root is all-or-nothing unless you hand-pick.

#### Two other costs

1. **WASI imports appear and must be shimmed.** Rooting the runtime pulls `wasi_snapshot_preview1.{proc_exit, fd_close, fd_write, fd_seek}`. Defining `__wasi_*` in a `@compile`-ed `.c` resolves them internally and the imports disappear — verified, back to exactly the host imports you declared. Same strategy as `spacetimedb-bindings-cpp/src/abi/wasi_shims.cpp` (~190 LOC, nearly all stubs returning success; `fd_write` forwards to the host log).
2. **`-sASYNCIFY` is auto-enabled and cannot be turned off.** `compile.ms:1366-1375` appends it whenever `promise/index.cms` survives DCE — which it does even for a module that never awaits. Costs size plus five `asyncify_*` exports. There is no override flag.

**`--gc=manual` is not usable here yet**: it fails to compile three prelude modules (`std/core/websocket/state.ms`, `std/net/index.cms`, `std/core/websocket/client.cms`). Underlying C error not yet captured. Until that is fixed, custom-host wasm runs on the default GC.

## Phase 1: `--gc=manual` (No RC, malloc available) — DONE

DRC injection is skipped. RC operations are no-ops. Allocation still uses malloc (libc available). Generated C code is identical to `--gc=orc` — only the linked runtime header differs.

**What was built:**

| File | Lines | Purpose |
|------|-------|---------|
| `runtime/manual.h` | ~300 | Two sub-modes: `MS_BARE` (static arena) vs desktop (malloc-backed, no RC). No-op RC, lifecycle stubs, locker/future stubs, `msPrintln` |
| `src/codegen/c/index.ms` | +8 | Conditional include: `runtime/manual.h` when `gcMode === Manual`, `runtime/core/system.h` otherwise |
| `src/analyzer/index.ms` | +1 | Skip DRC for `GcMode.Manual` (alongside existing `GcMode.None` skip) |
| `src/checker/context.ms` | +2 | `GcMode.Manual` enum value |
| `src/compiler/options.ms` | +4 | `--gc=manual` CLI flag parsing |

**How it works:**

```
MetaScript → Parse → Check → Transform → [Skip Analyzer] → Codegen → C source
                                                                ↓
                                              #include "runtime/manual.h"
                                                   (malloc alloc, no-op RC)
                                                                ↓
                                                             clang
                                                                ↓
                                                           binary (libc linked)
```

**Verified working:** hello.ms, testStructParams (24/24), test_enum, testArrayPush, testJson, httpConcurrent.

## Phase 2: `--os=bare` (Freestanding, no libc) — DONE

When `--os=bare` is combined with `--gc=manual`, the runtime uses a static arena instead of malloc. All runtime `.c` files route through the arena via preprocessor redirects. No libc dependency.

**Approach:** Same `.c` files for all modes, behavior switches via preprocessor. `manual.h` defines `#define malloc → msArenaAlloc` when `MS_BARE` is set. The build system passes `-DMS_BARE -include runtime/manual.h` to clang, forcing arena redirects before each `.c` file's own headers.

**What was built:**

| File | Change | Lines |
|------|--------|-------|
| `runtime/manual.h` | `MS_BARE` sub-mode: static arena buffer, `#define malloc/calloc/realloc/free → arena` | ~30 |
| `runtime/manual.h` | `MS_MANUAL_MODE` flag to skip `.c` function bodies (manual.h provides inline versions) | 1 |
| `src/compiler/compile.ms` | `initCBuildState`: add `-DMS_BARE -include runtime/manual.h` when `--os=bare` | 3 |
| `src/codegen/c/index.ms` | `genProjectDispatcher` takes `osTarget` param, generates per-OS entry points | ~30 |
| `runtime/core/system.c` | Wrapped in `#ifndef MS_BARE` (manual.h provides all functions inline) | 2 |
| `runtime/promise/dispatch.c` | Wrapped in `#ifndef MS_BARE` | 2 |
| `runtime/promise/combinator.c` | Wrapped in `#ifndef MS_BARE` | 2 |
| `runtime/promise/pool.c` | Wrapped in `#ifndef MS_BARE` | 2 |

**Dynamic entry points per `--os`:**

| `--os` | Entry Point | Init |
|--------|-------------|------|
| `auto` (default) | `main(int argc, char** argv, char** env)` | Full POSIX: stack init, env, signal handlers |
| `bare` | `main(void)` | Calls `MsMain()` → `MsPreMainInner()` + `MsMainInner()` |
| `solana` | None (user provides `entrypoint()`) | `MsMain()` exposed, user calls it |

**`MsMain()`** is the init function: calls `MsPreMainInner` (DatInit for all modules) then `MsMainInner` (Init for all modules + user's `main_()`).

**Arena configuration:** Default 256KB (`MS_ARENA_SIZE`). Override via `--passC="-DMS_ARENA_SIZE=N"`.

**Verified all three modes:**
- `build examples/hello.ms` → ORC (default), full main → "hello world"
- `build --gc=manual examples/hello.ms` → malloc, no RC, full main → "hello world"
- `build --gc=manual --os=bare examples/hello.ms` → arena, no malloc, minimal main → "hello world"

## Phase 3: Blockchain / Contract Mode

Blockchain VMs (Solana/SBPF, WASM chains, Move) share constraints that go beyond `--os=bare`:

| Constraint | bare | blockchain |
|---|---|---|
| libc | No | No |
| Mutable globals | OK | Not allowed (sbpf-linker, some WASM linkers) |
| Module init system | OK | Unnecessary (single entry, runs once) |
| TypeInfo | OK | Unnecessary (no DRC) |
| Float operations | OK | Not on BPF |
| Entry point | `main(void)` | Target-specific (`entrypoint`, WASM export, etc.) |

The root cause: `--os=bare` generates the same multi-module code as desktop, just with a different allocator. Blockchain targets need **flat, minimal code** — no dead modules, no unnecessary globals.

### Phase 3a: Infrastructure — DONE

Toolchain integration, entry points, freestanding headers, CLI automation.

**What was built:**

| File | Change |
|------|--------|
| `runtime/manual.h` | `MS_SOLANA` sub-mode: `msPrintln` → `sol_log_()` syscall |
| `runtime/freestanding/` | Stub headers (stdio.h, string.h, math.h, ctype.h, stdarg.h, stdlib.h) for BPF |
| `src/codegen/c/index.ms` | `#define MS_SOLANA`/`MS_BARE` in generated C; `entrypoint()` in dispatcher; skip libc headers |
| `src/codegen/c/literals.ms` | `static const` string literals (`.rodata`, COW-safe) — correctness fix for all targets |
| `src/checker/context.ms` | `osTarget` field on CheckerContext |
| `src/compiler/compile.ms` | Solana toolchain setup (auto-detect BPF clang + sbpf-linker), force `--gc=manual` + release mode, graceful @compile failures, LLVM bitcode pipeline, BPF validation via `llc` |
| `src/compiler/cc.ms` | `resolveBpfClang()`, `resolveSbpfLinker()`, `validateBpfBitcode()`, `linkSolana()` (llvm-link → sbpf-linker), `cliCompileFlags` BPF early-return with `-emit-llvm` |
| `src/compiler/options.ms` | `--os` target validation |
| `src/index.ms` | Exclude bare/solana from zig cc auto-detection |
| `std/process` | Critical fix: `exec()` now returns actual exit codes |
| `examples/helloSolana.ms` | Hello world example |

**Build pipeline:** `msc build --os=solana examples/helloSolana.ms` — single command.

**What works:**
- MetaScript → C → LLVM bitcode → llvm-link → sbpf-linker → `.so`
- BPF clang auto-detected (homebrew LLVM on macOS, system clang on Linux)
- sbpf-linker auto-detected (PATH or `~/.cargo/bin/`)
- BPF-incompatible modules gracefully skipped
- `console.log` → `sol_log_()` syscall (transparent to user code)

**What's blocking deploy:** The prelude pulls in 13 modules for a hello world. Dead modules (json, buffer, promise, struct) contain mutable globals (TypeInfo, init guards) and BPF-incompatible code (floats, aggregate returns). sbpf-linker rejects `.data` section relocations from these globals. Only 2 of 13 modules are actually needed.

### Phase 3b: Module-Level DCE for Blockchain — TODO

The compiler already computes a DCE alive set (Phase B in `cmdBuildC`). But it only marks dead *symbols* — all *modules* are still compiled. For blockchain, dead modules must be skipped entirely.

**What needs to change:**

1. **Skip dead modules in Phase C** — if no symbol from a module is in the alive set, don't compile it. This eliminates json, buffer, promise, struct for a hello world. Benefits all targets (faster builds).

2. **Skip TypeInfo for `--gc=manual`** — TypeInfo structs are mutable globals used only by DRC. In manual mode they're dead weight. Skipping them eliminates the main source of `.data` relocations.

3. **Skip init guards for blockchain** — `DatInit`/`Init` guard booleans are mutable globals preventing re-entry. Blockchain programs run once — guards are unnecessary. Remove them when `--os` is a blockchain target (solana, wasm).

4. **Minimal dispatcher** — for blockchain, the dispatcher should inline: no `MsMain()`, no `MsPreMainInner`/`MsMainInner`, just direct calls to the live modules' init + user's `main_()`.

After these changes, `helloSolana.ms` generates:
```c
#include <stdint.h>
#define MS_SOLANA
#define MS_BARE
#include "runtime/manual.h"

static const struct { int64_t cap; char data[13]; } STR_1 = { MS_STRLIT_FLAG | 12, "hello solana" };

int32_t main_(void) {
    msPrintln(MS_STRING_LIT(&STR_1, 12));
    return 0;
}

uint64_t entrypoint(const uint8_t* input) {
    (void)input;
    main_();
    return 0;
}
```

Zero mutable globals. sbpf-linker accepts it. Deploys to Solana.

**This design is generic** — the same DCE improvements work for any blockchain target:

| Target | Entry point | Syscall mapping | Extra |
|--------|-------------|-----------------|-------|
| `--os=solana` | `uint64_t entrypoint(uint8_t*)` | `sol_log_` via `msPrintln` | sbpf-linker |
| `--os=wasm` | `export _start(): i32` | `env.log` via `msPrintln` | wasm-ld |
| `--os=near` | `export main(): void` | `env.log` | wasm-ld |

### Phase 3c: Solana SDK Types — TODO

After 3b makes deploy work:
- `std/solana/` module: `Pubkey`, `AccountInfo`, `ProgramResult` types
- Typed `main()` signature: `main(programId: Pubkey, accounts: AccountInfo[], data: uint8[]): ProgramResult`
- Deserialization: parse raw `uint8*` input into typed args
- Account data read/write helpers

### Known BPF Constraints

These are hardware/VM limitations, not bugs in our toolchain:
- No floating point — use `int32`/`int64`/`uint64` instead of `number`
- No aggregate returns — structs can't be returned by value
- No function pointers — closures/callbacks won't work on older BPF versions
- 512-byte stack limit — large locals must use heap (arena)
- 32KB heap (Solana) — arena size must respect this

## Phase 4: Compile-Time Enforcement (optional)

Warnings or errors when `--gc=manual` code uses patterns that waste arena space or won't work on constrained targets. Not a blocker — programs work without these checks.

| Pattern | Warning | Suggestion |
|---------|---------|------------|
| Heavy string concat in loop | "repeated concat allocates from arena without free" | Pre-size buffer |
| `async`/`await` | "async not available under --gc=manual" | Use synchronous code |
| Very large arena usage | "estimated arena usage exceeds MS_ARENA_SIZE" | Increase size or restructure |

**Where:** `src/checker/checkPass.ms` — optional diagnostics when `gcMode === GcMode.Manual`.

## Phase 5: Explicit Allocator (~2 weeks)

Allocator passed via constructor, stored as field — TypeScript-natural, not Zig-style pass-everywhere.

```ms
const arena = new ArenaAllocator(buffer);
defer arena.reset();

// Allocator passed once at construction, used internally
const pool = new ConnectionPool(arena, 10);
pool.connect("localhost");  // no allocator param needed
pool.connect("remote");     // pool.arena handles allocation

// Different allocators for different lifetimes
const globalArena = new ArenaAllocator(largeBuffer);
const tempArena = new ArenaAllocator(smallBuffer);

const config = new AppConfig(globalArena);       // lives for program lifetime
const request = new RequestParser(tempArena);     // freed after each request
defer tempArena.reset();
```

**How it differs from Zig:**

| | Zig | MetaScript Phase 5 |
|---|---|---|
| Allocator passing | Every method: `list.append(gpa, item)` | Constructor only: `new List(arena)` |
| Default allocator | None — must always pass | Global arena (Phase 1, implicit) |
| Syntax | `arena.create(T)` | `new T(arena)` |

Phase 5 adds the option for explicit control. The implicit global arena from Phase 1 remains as the default for code that doesn't need fine-grained allocation.

In C codegen terms:
- No explicit Allocator → `msAlloc()` (global arena, Phase 1)
- Explicit Allocator field → `msAllocWith(self->arena, ...)` (user-provided)

## What Already Works (no changes needed)

| Feature | Why it works under --gc=manual |
|---------|------------------------------|
| `Result<T,E> + try` | Value type, no allocation, same as Zig error unions |
| `struct` (value types) | Stack-allocated, copied by value, no RC |
| `enum` | Integer constants, zero overhead |
| `match` expressions | Lowered to switch/if-else in Transform, pure control flow |
| `defer` | Already emitted as scope-exit cleanup in codegen |
| `move` | Bitwise copy + zero source, no RC |
| `Span<T>` | Already pointer+length, same concept as Zig slices |
| `extern` FFI | Direct C function calls, works on any target |
| `when (c) { … }` | Conditional compilation (`@target` retired 2026-08-09) |
| `@comptime` | Compile-time evaluation, zero runtime cost |
| Sized integers (`int32`, `uint64`, etc.) | Direct C types, no overhead |
| `unreachable` | Emits `__builtin_unreachable()` or abort |
| `interface` (heap ref type) | Arena-allocated, same pointer layout as ARC/ORC |
| `string` operations | Same `msString` type, arena-backed allocation |
| `Array<T>` operations | Same array types, arena-backed allocation |
| `console.log` | `msPrintln` provided by manual.h (weak symbol, overridable) |

## Target Matrix

| Target | `--gc` | `--os` | Mode | Phase Required |
|--------|--------|--------|------|----------------|
| Desktop (current) | `orc` | `auto` | Full runtime | Already works |
| Desktop (no cycles) | `drc` | `auto` | Full runtime | Already works |
| Desktop (manual) | `manual` | `auto` | Full runtime | Phase 1 (done) |
| Game engines | `manual` | `auto` | Full runtime | Phase 1 (done) |
| Cross-compile Linux | `orc`/`drc`/`manual` | `linux` | Full runtime | Already works |
| Cross-compile Windows | `orc`/`drc`/`manual` | `windows` | Full runtime | Already works |
| Embedded (ARM Cortex) | `manual` | `bare` | Freestanding | Phase 2 (done) |
| Kernel modules | `manual` | `bare` | Freestanding | Phase 2 (done) |
| Solana/SBPF | `manual` | `solana` | Contract | Phase 3a (infra done), 3b (DCE TODO) |
| WASM chains (NEAR, Cosmos) | `manual` | `wasm` | Contract | Phase 3b + WASM entry |
| Move (Sui/Aptos) | — | — | New backend | Future |

**Three runtime modes:**
- **Full runtime**: ARC/ORC available, libc, module init system, mutable globals OK
- **Freestanding**: No libc, static arena, module init with guards, mutable globals OK
- **Contract**: No libc, no mutable globals, no init guards, no TypeInfo, flat DCE'd codegen

## ARC/ORC ↔ Manual Interop (Mixed-Mode Libraries)

A library compiled with `--gc=manual` is importable from ARC/ORC code. Types are layout-compatible (same `msString`, `msRefHeader` struct layout). The compiler auto-generates bridge code at import boundaries.

**Direction 1: ARC/ORC → Manual (passing in)** — FREE. `msString` already has `ptr+len` inside.

**Direction 2: Manual → ARC/ORC (returning)** — COPY. Compiler wraps arena-allocated return values into RC'd types via `msStringNew()`.

**Implementation**: Future phase, ~150 additional lines.

## Runtime Directory Structure

All C runtime files live under `runtime/` (separated from `std/` which contains MetaScript modules):

```
runtime/
  drc.h / .c              ← ARC (--gc=drc) or ORC (--gc=orc, adds -DMSGC_ORC)
  manual.h                ← no RC; MS_BARE=arena, else=malloc (--gc=manual)
  types.h                 ← msRefHeader, msTypeInfo (shared by both)
  arena.h                 ← arena allocator implementation
  fs.h, process.h, os.h  ← single-file modules (flat, no subdirs)
  hcr.h / hcrHost.c      ← hot code reload
  core/                   ← core types every program needs
    system.h/.c, string.h/.c, array.h/.c, buffer.h/.c, test.h, abort.h
  promise/                ← async subsystem
    future.h, dispatch.h/.c, combinator.h/.c, pool.h/.c, thread.h, locker.h
  crypto/                 ← organized by category
    hash.h/.c, curves/, ciphers/, kdf/, tls/, rsa/
  io/                     ← I/O engines
    streams.h, engine.h, engineSelect.c, engineIOCP.c, engineUring.c
  net/                    ← networking
    socket.h, async.h, eventLoopUring.h
  actor/                  ← actor model
    actor.h, cycle.h, mailbox.h, selector.h
```

## References

- Standard reference `--gc:none`: same .c files, `#ifdef nogc` branches
- Standard reference `--os:any`: skips main(), stack init, thread init
- Zig allocator: `std/mem/Allocator.zig` — vtable pattern, explicit passing
- Zig arena: `std/heap/arena_allocator.zig` — bump pointer + linked buffer list
- Zig slices: `[]const u8` — non-owning view, zero-copy ops
- Solana SBPF: 32KB heap, 200K-1.4M compute units, `entrypoint()` ABI
- sbpf-linker: ELF → SBPF V0 bytecode transformation
