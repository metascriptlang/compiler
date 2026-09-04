# Raiser VM — Self-Hosted Bytecode Backend

Statically-typed bytecode VM for MetaScript. **Four product roles**, in priority order:

1. **Comptime engine** — executes `@comptime` blocks and macros during compilation (working today)
2. **IDE eval-loop backend** — long-running runtime for inline-eval / hot-redefine / watch-style IDE experience (planned)
3. **Embeddable scripting / REPL** — small-footprint runtime for sandboxed eval (small)
4. **Game-logic scripting runtime** — long-lived, OTA-updatable runtime for turn-based / event-driven game logic on the mobile client, where shipping native code is not an option (planned). The C backend stays the training/server path; Raiser is the client-side scripting layer. This is the Lua / AngelScript niche — gameplay *logic*, not the render loop.

Explicit non-goals: JIT compiler, general-purpose VM competing with browser engines, the **60fps render loop** of an engine (that needs JIT — role #4 is the *scripting* layer above it), large stdlib.

For shipping native binaries use the **C backend**. For browser/edge use the **JS backend**. Raiser only fills the iteration-loop / sandbox / comptime niche those two cannot cover.

---

## Why static types let us skip JIT

Dynamic-language JITs exist primarily to **infer types at runtime**: observe actual operand types, generate specialized code, deopt on type change. ~80% of a production JIT's complexity is type-speculation + deopt machinery. MetaScript types are resolved **at compile time** — `int32 + int32` is statically `AddI32`, no runtime guessing required.

Performance bands (typical, vs C native, integer-heavy):

| Runtime kind | Cost |
|---|---|
| Dynamic interpreter, no JIT | ~30–50× of C |
| Dynamic with JIT | ~2–3× of C |
| Static-typed interpreter, untagged registers | **~3–5× of C** ← Raiser target |
| Static-typed JIT | ~1.5–2× of C |

The static-type path closes most of the gap to JIT without the engineering cost. Raiser targets the third band.

---

## Memory Model

Two regimes, picked per role — not one allocator:

| Roles | Regime | Reclamation |
|---|---|---|
| Comptime (1), sandbox (3) | **Arena heap-recycle** | bulk reset at each eval boundary; no per-value RC — lifetime is bounded by the compilation/eval, the same reasoning any compile-time VM uses (see below) |
| IDE eval-loop (2), game-logic runtime (4) | **ORC** (ARC + cycle collector) | per-object refcount, deterministic incremental free; Bacon trial-deletion for the rare cycle |

### Why ORC for the long-lived roles (not tracing GC, not arena)

- **Arena fails for long-lived roles** — no bounded scope, references held across evals/ticks. A monotonic arena grows unboundedly; a per-tick reset corrupts persistent state.
- **Tracing GC breaks parity** — the C backend uses deterministic destruction (`--gc=drc` / `--gc=orc`). A tracing-GC Raiser would fire `defer`/destructors at *different times* → same source, divergent behaviour on C vs Raiser. ORC keeps the **same destruction semantics as C** — the point of "one source, every target".
- **ORC is the proven game-scripting model** — AngelScript, Squirrel, GDScript (and Python) all use RC + cycle collector. Deterministic + incremental → no stop-the-world frame spikes (the Lua/Unity GC-pause pain).
- **Entity-as-id (engine `D2`) keeps the owning graph mostly acyclic** → the cycle collector rarely fires; plain ARC carries most of the load.

### Feasibility (verified)

ORC is **simpler on Raiser than on C**, because VM objects are *self-describing*:

- C needs a static `msTypeInfo` per type (`runtime/types.h`) plus generated `_trace` / `_destroy` procs (`destructorLifting`). Raiser objects carry `fields: RaiserObjectField[]` at runtime → **one generic trace** (walk the field list, visit Array/Object handles) and **one generic destroy** (decref each ref field) cover every type. No per-type RTTI, no `destructorLifting`.
- The DRC *analysis* (`analyzeProgram`, `src/analyzer/index.ms`) is a target-agnostic `Node → Node` pass already — Raiser can run it to place incref/decref at the **same program points as C** (true parity), or use VM-intrinsic RC (AngelScript-style) for a simpler near-parity version.
- The cycle collector is Bacon trial-deletion (~360 LOC reference in `runtime/drc.c`) — reimplemented against the VM heap using the generic trace; rc + color bits live in the heap-entry header.

No fundamental blocker found.

### Work outline — LANDED (measured 2026-09-04)

1. `rc` + color on the heap entries — `value.ms:197-198`.
2. Free-list / slot recycle — `value.ms:203`, `heapAllocArray` reuses before appending.
3. VM `incref` / `decref` + generic destroy — `rcIncref`/`rcDecref` in `value.ms`.
4. ARC placement took the **VM-intrinsic** branch (not the Phase-4 analyzer): `vm.ms:126-158`, on ref store / overwrite, gated on `gcMode`.
5. Bacon trial-deletion cycle collector — `orc.ms`, driven from `vm.ms:145`.
6. `gcMode` toggle — `createVM(mod, gcMode = "arena")`, `"arena" | "orc"`.

**CLI reaches it.** `createContext()` (`context.ms:42`) defaults to
`gcMode: "arena"`, but `cmdRunRaiser` overrides to `"orc"` right after
(`compile.ms:2317`) — so `--target=raiser` runs refcounted with the cycle
collector. Anything embedding the VM directly and skipping that override
(eval helper paths) still gets arena.

---

## Performance Roadmap

### Phase 0 — Working baseline (DONE)

57 opcodes; generic boxed `RaiserValue` register file; computed-goto C dispatch via `vmDispatch.c`; 1959 tests across rgen + eval. Sufficient for comptime macro execution and small REPL programs.

Perf, measured 2026-09-04 (`fib(27)`, MIN of 5 rounds, load ~5.8, VM time isolated by subtracting a `fib(1)` run so parse+check+bytecode drops out):

| | time | vs VM |
|---|---|---|
| native `--danger` | 3.1 ms | **79×** |
| native default (`-O0`) | 4.3 ms | **61×** |
| Raiser VM portion | 245.7 ms | — |
| Raiser fixed cost (parse+check+bytecode) | 172.6 ms | — |

The older "~50× of C" estimate was optimistic but the right order of magnitude. Dominated by per-op heap allocation and pointer indirection — the Phase 1 targets.

### Phase 1 — Untagged typed registers (SPIKED — see `spike/`)

**Problem (audited)**:

| # | Issue | Where |
|---|---|---|
| 1 | Register file is `RaiserValue[]` (33-byte heap struct + pointer per slot) | `value.ms`, `vm.ms` |
| 2 | `intVal: number` is f64 internally — integer math goes through FPU | `value.ms` |
| 3 | Every arithmetic op heap-allocates a fresh value (`raiserInt(...)`) | `vm.ms` AddI64 etc. |
| 4 | `Move` allocates + `copyValueInto` instead of pointer copy | `vm.ms` |
| 5 | Each `RaiserInstruction` compiles to ~32 bytes of C struct | `vmDispatch.c` |
| 6 | `LoadField` does linear-scan + string compare on object fields | `value.ms:319` |
| 7 | I32/F32 typed opcodes documented but unimplemented; only I64/F64 exist | `vm.ms` dispatch |

**Sub-phases**:

- **1a** — untagged register file (`union { int64; double; ptr }[]` or per-type slots)
- **1b** — native `int64`, drop double-as-int
- **1c** — eliminate per-op alloc (write into existing slot)
- **1d** — pack instruction layout (current 32B → 4–8B target)

**Spike result (this session)**: 1a alone — register file becomes `number[]` (untagged), constants pre-extracted, alloc-free hot loop:

**Spike sub-phases measured** (`spike/` dir):
- **1a** — register file `number[]` (untagged), constants pre-extracted, alloc-free hot loop. File: `spike/vmFast.ms`.
- **1d** — instructions packed into single `number` per inst (8 bytes vs ~32-byte heap struct + pointer). Decode is shift+mask in dispatch. File: `spike/vmPacked.ms`.

```
=== sum(1..20000) ===
  vm.ms (boxed)        : 13.11ms
  vmFast (1a)          :  3.58ms   (3.66x)
  vmPacked (1a+1d)     :  2.41ms   (5.43x)
  packing alone        :  1.48x    (1a → 1a+1d)

=== sum(1..60000) ===
  vm.ms (boxed)        : 38.85ms
  vmFast (1a)          : 11.29ms   (3.52x)
  vmPacked (1a+1d)     :  7.19ms   (5.40x)
  packing alone        :  1.53x

=== fibIter(45) ===
  vm.ms (boxed)        :  0.73ms
  vmFast (1a)          :  0.22ms   (3.36x)
  vmPacked (1a+1d)     :  0.17ms   (4.11x)
  packing alone        :  1.22x
```

**Validates the thesis**: untagged registers + packed instructions delivers ~5× over the boxed baseline. Sub-phase 1b (native `int64` instead of f64-as-int via MS sized-int types) expected to add another 1.3–1.5×. Full Phase 1 target is **6–8× faster than current vm.ms on numeric loops**, putting Raiser within ~5–8× of native C — typed-bytecode-interpreter range, on track for the 3–5× of-C goal after Phase 2/3.

Spike files: `spike/vmFast.ms` (1a), `spike/vmPacked.ms` (1a+1d), `spike/bench.ms` (3-way harness).

### Phase 2 — Field offsets (PLANNED)

Replace `LoadField reg, base, "fieldName"` (linear scan + string compare) with `LoadFieldOffset reg, base, k` (single mov). Codegen layout pass assigns per-struct field offsets. Expected speedup: 10–50× on object-heavy code.

### Phase 3 — Type-specialized opcodes (PLANNED)

Implement I32/U32/U64/F32 variants currently only on paper. Compiler `kind` info already drives selection; need handlers + dispatch entries. Expected speedup: 1.3–2× on mixed-numeric code.

### Phase 4 — Threaded dispatch (PLANNED)

Tighten `vmDispatch.c` to direct-threaded code (next-instruction loaded inside each handler, no central `while` loop). Expected speedup: 1.3×.

### Phase 5 — Call-path work (PLANNED; folded from the retired docs/RAISER.md HashLink-era list)

- `Call0`–`Call4` specialized opcodes — arity-specialized call entries, less
  argument-marshalling overhead in the dispatch loop.
- `CallExtern` — call linked C natives directly via function pointers,
  replacing the per-name MS bridge wrappers for true externs. This is the
  build-time-generated `{name, fnPtr, sigTag}` table docs/PIPELINE.md
  originally sketched; see its §CallHost for the current mechanism.

---

## Light Table IDE Backend (PLANNED)

Second product reason for Raiser's existence. Architecture:

```
Editor ──socket──> Long-running Raiser process
   │                       │
   │  evalForm("x+1") ──→  Parse → Check (lenient) → Compile → Execute in-VM
   │                       │
   ←──── result + watches ─┘
```

Required additions (~2 months on top of Phase 1):

| Feature | Mechanism |
|---|---|
| `evalForm(text) → Value` | Reentrant parser/checker + persistent VM globals |
| Function hot-swap | Patch `module.functions[idx]` — callers via `funcIdx` pick up new bytecode automatically |
| Watch instrumentation | New `Watch reg, watchId` opcode pushes values to editor stream |
| Reflection API | Expose frame stack + globals + types via socket |
| Type-change strategy | Soft restart (Phase 1) on incompatible struct layout change |

Open questions deferred until Phase 1 ships:
- Lenient incremental check (eval `foo(x)` with undefined `x` → soft error, not block)
- Migration vs restart on struct field changes
- Source-map for inline value rendering

---

## std Access — three tiers, scope is per role

How a std operation gets executed in Raiser. Four mechanisms answer this
question; the model below is the source of truth, but enforcing it is still
manual (see Known gaps). Before 2026-09-04, 21 of the 38 externs declared in
`.rms` were dead — they resolved to nothing and the identifier arm silently
emitted `LoadConst nil` (that arm is now a hard comptime error with a span,
bug124). The model:

| Tier | What | Admission test |
|---|---|---|
| 0 | VM opcode | not expressible in MS — string identity/length/index, array index/len/push, arithmetic. Chosen for **representation**, never for speed |
| 1 | Host bridge (`CallHost`) | needs host **state or representation** — fs, process, env, string↔bytes. One hand-maintained table, every entry carries a written reason |
| 2 | Portable MS (`std/core/string/shared.ms`) | everything derivable — shared **structurally** with the C and JS backends |

Rule: an operation lands in the **lowest tier that can express it**; Tier 1
needs a written justification.

**Scope is per role, not global.** The bridge table lives in
`src/compiler/meta/hostTable.ms` — compiler-side, not VM-side — so it is
role-1 infrastructure by construction:

| Role | Tier 1 surface |
|---|---|
| 1 (comptime) | wide — fs (14/14), process, env. The host compiler is always present |
| 2 (IDE eval) | same host is present; surface follows role 1 |
| 3 (sandbox), 4 (game logic) | **minimal, supplied by the embedder** — there is no host compiler to borrow std from. This is the AngelScript/Squirrel shape already chosen for role 4 |

Consequence: any design that answers "Raiser needs operation X" with "add a
bridge" is a role-1-only answer. Roles 3/4 need Tier 2 to actually carry the
stdlib, because they have nothing to delegate to.

**Known gaps** (measured, not guessed):

- RESOLVED 2026-09-04: `index.rms` now re-exports the same 17 names from
  `./shared` as `index.cms:156`/`index.jms:263`, on two new kernel bridges
  `msAsBytes`/`msAsString` (`hostTable.ms` — the only bridges that create or
  read VM heap arrays) plus the byte trio as MS. Still dead by declaration:
  `substring`, `padStart`/`padEnd`, `parseFloat`/`parseInt`, `fromCodePoint` —
  kept for surface parity until each gets a bridge or an MS body.
- Trap when editing `shared.ms`: the Raiser macro checker pulls a macro's
  helper closure through the prelude EXPORT surface — a module-private helper
  called by an exported function reads as "Undefined variable" inside macro
  bodies even though the C backend compiles it fine. Export the helper and
  add it to the `index.rms` re-export line (see `asciiLower`).
- RESOLVED 2026-09-04: generic-array methods are portable MS in
  `std/core/array/index.rms` over the ArraySetLen opcode (the heap's shrink
  primitive) + push/index/length; `setLength` is intercepted by the codegen
  exactly like `push`, so the `'&'`-prefixed extern names never reach
  CallHost. `capacity` returns the live length (the heap exposes no
  allocation size).
- Nothing checks that `.rms` externs are covered by the registry or the opcode
  intercepts, so a new extern goes dead silently.
- Whole-program `--target=raiser`, measured 2026-09-04. The prelude is
  target-agnostic — all 16 modules of `globalImports()` (`src/checker/prelude.ms:13`)
  must type-check, and `std/core/json` pulls `serialize/json/accessors.ms`,
  whose `seen.join("; ")` had no raiser-tier `join`. One Tier-2 `join` in
  `index.rms` unblocked the entire target: `console.log`, functions, `for..of`,
  interfaces, `match`+enum, `Result`+`try`, classes, closure capture and
  generics all run. `std/fs`, `std/process`, `std/io`, `std/compress/zip`
  and the crypto hash family now carry raiser tiers over host bridges
  (round-trip probes: zip write→read→extract through int64 handle bridges,
  sha256("abc") exact); `exit` is intercepted at the call site into a
  `Halt` (Nim's VM has no quit op) and `cmdRunRaiser` propagates the VM exit
  value as msc's exit code. `cmdRunRaiser` also loads the host table BEFORE
  `generateRaiserProject` (the bridge-coverage check resolves at the call
  site) and prints queued bytecode-compile errors as warnings — comptime
  parity: std bodies the program never calls can contain unbridgeable
  externs, so they are reported, not fatal. `src/checker/checkPass.ms`
  compiles and runs clean this way. The import wall for the whole compiler
  is down (`src/index.ms` no longer reports "Cannot resolve import"); the
  remaining 20 errors are `Undefined variable 'fetch'/'spawn'/'waitFor'/
  'Buffer'` — **`std/core/promise` and `std/core/fetch` are .cms-only**, so
  their prelude globals never enter the raiser graph. That is the next wall,
  not a codegen bug.
- **Exported consts keep their AST across modules** (fixed 2026-09-04): the
  export-info builder only carried `declNode` for Function/Method/Enum, so an
  imported const's symbol pointed at the ImportDecl and the Raiser const
  inlining arm compiled it to nil ("cannot evaluate 'platform'"). The fix is
  at the export side (`src/checker/context.ms`) — `importSymFromRegistry`
  already had the restore hook. Bytecode warnings now name the exact reason
  an identifier failed to bind (symbol kind, decl kind, no initializer…).

## Execution budget — back-edges, not instructions

The VM refuses programs that exceed `loopLimit` (default 10M) **loop
iterations** — backward `Jump` instructions — not raw instructions. Recursion
is bounded separately (`MAX_CALL_DEPTH` = 1024) and straight-line code is
finite by construction, so back-edges are the only unbounded source worth
budgeting. Reference parity: `maxLoopIterationsVM` decrements only inside
`handleJmpBack`, with `maxCallDepthVM` beside it.

Why the unit matters: a per-instruction budget taxes MS-implemented std by the
loop BODY length — an identical comptime `startsWith` folded at N=450k via a
host bridge but died at N=35k as pure MS (15×, measured 2026-09-04), making
"foldable" depend on which tier supplied a function. Escape hatch:
`--max-vm-iterations=<n>` (options.ms → `setDefaultLoopLimit`), named in the
error message. `vmCallFunction` resets the counter per entry, so each macro
invocation gets a fresh budget.

## Out of scope (intentional)

| Feature | Why skipped |
|---|---|
| JIT (x64/aarch64 codegen) | 18–30 month investment; static types close most of the perf gap without it |
| Tracing GC | Diverges from the C backend's deterministic destruction (`defer`/destructors fire at different times) → breaks multi-target parity. Long-lived roles (2, 4) use **ORC** instead — see Memory Model |
| Threading runtime, sockets, regex | Use C/JS backends — Raiser is not a general runtime |
| File I/O **for roles 2/3/4** | Role 1 DOES get fs (a macro must read files at compile time) — see "std Access" below. Scope is per role, not global |
| Async/await event loop | Synchronous eval is sufficient for comptime + IDE eval-form |
| 60fps render loop | Wrong target — needs JIT. Role #4 is the game-*logic* scripting layer (Lua niche), not the render loop |
| Bytecode binary (`.rsr` files) | Defer until opcode numbering stabilizes after Phase 1–3 |

---

## Pipeline Position

```
Source.ms → [1 Parse] → [2 Check] → [3 Transform] → src/codegen/raiser/ → RaiserModule → src/raiser/ (this dir, the VM)
                                                          ↑                                    ↑
                                                       AST→bytecode                       executes bytecode
```

Skips Phase 5 (C/JS codegen). Phase 4 (DRC analyzer) is **bypassed today**; the long-lived runtime roles (2, 4) will opt in for ORC parity (see Memory Model). Memory is two-regime: arena heap-recycle for comptime, ORC for the runtime roles. AST→bytecode lives in `src/codegen/raiser/` and imports types from this directory; this directory knows nothing about AST nodes.

---

## Files

```
src/raiser/
  CLAUDE.md          -- this file
  bytecode.ms        -- RaiserOpcode (52 ops), RaiserInstruction, ABC/ABx/Ax encoding
  value.ms           -- RaiserValue (boxed today, target untagged), array/object heaps
  module.ms          -- RaiserFunction, RaiserModule, accessors
  vm.ms              -- if/else dispatch loop, boxed register file (Phase 0)
  disasm.ms          -- bytecode pretty-printer
  repl.ms            -- REPL skeleton — to be expanded into IDE backend (Phase 2/3)
  spike/
    vmFast.ms        -- Phase 1 prototype: untagged register VM (i64 hot path only)
    bench.ms         -- side-by-side bench: vm.ms vs vmFast
```

Codegen lives in `src/codegen/raiser/` (separate dir): `context.ms`, `expressions.ms`, `statements.ms`, `rgen.ms`, `eval.ms`. See its CLAUDE.md.

---

## Bytecode Format

### Instruction encoding (Lua-style, ABC/ABx/Ax)

- **ABC**: `[op:8][A:8][B:8][C:8]` — 3 operands
- **ABx**: `[op:8][A:8][Bx:16]` — operand + 16-bit immediate
- **Ax**: `[op:8][Ax:24]` — 24-bit signed immediate (jumps)

`RaiserInstruction` is a flat interface today. Phase 1d goal: pack to ≤8 bytes per instruction.

### Opcode table (53 today)

| Family | Count | Notes |
|---|---|---|
| Memory | 3 | LoadConst (ABx), Move, LoadNil |
| i64 arithmetic | 6 | Add/Sub/Mul/Div/Mod/Neg |
| i64 compare-branch | 6 | Beq/Bne/Blt/Ble/Bgt/Bge — "if cond, skip C instructions" |
| f64 arithmetic | 5 | Add/Sub/Mul/Div/Neg |
| f64 compare-branch | 6 | symmetric to i64 |
| Bitwise | 6 | And/Or/Xor/Not/Shl/Shr — int32 internally |
| Control | 5 | Jump (Ax), Call, Ret, Halt, Print |
| Array | 6 | NewArray, LoadIndex, StoreIndex, ArrayLen, ArrayPush, ArraySetLen (truncate or nil-extend — the heap's only shrink primitive) |
| Object | 3 | NewObject, LoadField (string-keyed today), StoreField |
| String | 6 | ConcatStr, EqStr, NeStr, StrLen, StrCharAt, StrSlice |
| Indirect | 1 | CallIndirect (func index from register) |

Phase 3 will add I32/U32/U64/F32 variants (~30 more opcodes).

---

## VM Dispatch Architecture

### if/else chain (NOT match)

Dispatch uses `if/else` because `break`/`continue` in match arms targets the generated switch, not the enclosing `while` loop.

```ms
while (!vm.halted) {
    const inst = func.code[vm.ip];
    vm.ip = vm.ip + 1;
    const op = inst.op;
    if (op === RaiserOpcode.AddI64) { /* ... */ }
    else if (op === RaiserOpcode.SubI64) { /* ... */ }
    /* ... */
}
```

### Computed-goto fast path (PLANNED — no C mirror exists today)

Dispatch is the `if/else` chain in vm.ms ONLY. The computed-goto C mirror
(`vmDispatch.c`) described by older versions of this file never landed in
this repo — when Phase 4 builds it, it must mirror vm.ms/value.ms/module.ms
struct layouts exactly and keep opcode numbering in sync at the top of the
C file. Until then, any field change in those `.ms` files has no C mirror
to update.

---

## Compiler State (codegen, in `src/codegen/raiser/`)

Two-phase compilation: collect functions/classes/enums first, then compile bodies. See `src/codegen/raiser/CLAUDE.md` for full architecture and NodeKind coverage.

---

## DRC Workarounds (live in this code)

| Rule | Application |
|------|------------|
| Arrays by pointer | Bare `T[]` types throughout |
| No try in match arms | Dispatch uses if/else chain |
| `const` before function arg | Store `RaiserValue` in const before pushing to arrays |
| No C-style `for` in match | Use `while` loops everywhere |
| Interface name prefix | `Raiser*` to avoid C namespace collision |
| No `indexOf`/`includes` | Use `slice`, `length`, `findChar` from `utils/string.ms` |
| `null as unknown as T` | For nullable fields in frames/compiler |

---

## Testing

```bash
# Per-file (fast)
msc test src/raiser/value.ms

# Full VM
msc test src/raiser/vm.ms

# Codegen + VM end-to-end (in src/codegen/raiser/)
msc test src/codegen/raiser/eval.ms

# Phase 1 spike bench
msc run src/raiser/spike/bench.ms
```

---

## Status Summary

| Component | State |
|---|---|
| Phase 0 baseline | DONE — 1959 tests, comptime engine working |
| Phase 1 spike | DONE — 4–5× speedup confirmed on numeric loops |
| Phase 1 commit (1a–1d) | NEXT — estimated 5 weeks for full untagged + packed pipeline |
| Phase 2 (field offsets) | PLANNED |
| Phase 3 (typed ops I32/F32) | PLANNED |
| Phase 4 (threaded dispatch) | PLANNED |
| Light Table IDE backend | PLANNED — depends on Phase 1 |
| ORC memory (roles 2, 4) | PLANNED — feasibility verified (generic trace via self-describing objects); no blocker |
| Game-logic scripting runtime (role 4) | PLANNED — needs ORC + per-session lifecycle |
