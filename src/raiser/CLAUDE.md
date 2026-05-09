# Raiser VM — Self-Hosted Bytecode Backend

Statically-typed bytecode VM for MetaScript. **Three product roles**, in priority order:

1. **Comptime engine** — executes `@comptime` blocks and macros during compilation (working today)
2. **IDE eval-loop backend** — long-running runtime for inline-eval / hot-redefine / watch-style IDE experience (planned)
3. **Embeddable scripting / REPL** — small-footprint runtime for sandboxed eval (small)

Explicit non-goals: JIT compiler, general-purpose VM competing with browser engines, AAA game runtime, large stdlib.

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

## Performance Roadmap

### Phase 0 — Working baseline (DONE)

52 opcodes; generic boxed `RaiserValue` register file; computed-goto C dispatch via `vm_dispatch.c`; 1959 tests across rgen + eval. Sufficient for comptime macro execution and small REPL programs. Rough perf: ~50× of C — dominated by per-op heap allocation and pointer indirection.

### Phase 1 — Untagged typed registers (SPIKED — see `spike/`)

**Problem (audited)**:

| # | Issue | Where |
|---|---|---|
| 1 | Register file is `RaiserValue[]` (33-byte heap struct + pointer per slot) | `value.ms`, `vm.ms` |
| 2 | `intVal: number` is f64 internally — integer math goes through FPU | `value.ms` |
| 3 | Every arithmetic op heap-allocates a fresh value (`raiserInt(...)`) | `vm.ms` AddI64 etc. |
| 4 | `Move` allocates + `copyValueInto` instead of pointer copy | `vm.ms` |
| 5 | Each `RaiserInstruction` compiles to ~32 bytes of C struct | `vm_dispatch.c` |
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

Tighten `vm_dispatch.c` to direct-threaded code (next-instruction loaded inside each handler, no central `while` loop). Expected speedup: 1.3×.

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

## Out of scope (intentional)

| Feature | Why skipped |
|---|---|
| JIT (x64/aarch64 codegen) | 18–30 month investment; static types close most of the perf gap without it |
| Precise generational GC | Comptime VM lifetime is short; IDE state lives across edits via different model |
| Threading runtime, sockets, regex, file I/O | Use C/JS backends — Raiser is not a general runtime |
| Async/await event loop | Synchronous eval is sufficient for comptime + IDE eval-form |
| 60fps frame-budget gameplay | Wrong target — that needs JIT |
| Bytecode binary (`.rsr` files) | Defer until opcode numbering stabilizes after Phase 1–3 |

---

## Pipeline Position

```
Source.ms → [1 Parse] → [2 Check] → [3 Transform] → src/codegen/raiser/ → RaiserModule → src/raiser/ (this dir, the VM)
                                                          ↑                                    ↑
                                                       AST→bytecode                       executes bytecode
```

Skips Phase 4 (DRC analyzer) and Phase 5 (C/JS codegen). The VM has its own memory model — heap-recycle between comptime evaluations, no per-value RC. AST→bytecode lives in `src/codegen/raiser/` and imports types from this directory; this directory knows nothing about AST nodes.

---

## Files

```
src/raiser/
  CLAUDE.md          -- this file
  bytecode.ms        -- RaiserOpcode (52 ops), RaiserInstruction, ABC/ABx/Ax encoding
  value.ms           -- RaiserValue (boxed today, target untagged), array/object heaps
  module.ms          -- RaiserFunction, RaiserModule, accessors
  vm.ms              -- if/else dispatch loop, boxed register file (Phase 0)
  vm_dispatch.c      -- computed-goto C dispatch (mirrors vm.ms layout exactly)
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

### Opcode table (52 today)

| Family | Count | Notes |
|---|---|---|
| Memory | 3 | LoadConst (ABx), Move, LoadNil |
| i64 arithmetic | 6 | Add/Sub/Mul/Div/Mod/Neg |
| i64 compare-branch | 6 | Beq/Bne/Blt/Ble/Bgt/Bge — "if cond, skip C instructions" |
| f64 arithmetic | 5 | Add/Sub/Mul/Div/Neg |
| f64 compare-branch | 6 | symmetric to i64 |
| Bitwise | 6 | And/Or/Xor/Not/Shl/Shr — int32 internally |
| Control | 5 | Jump (Ax), Call, Ret, Halt, Print |
| Array | 5 | NewArray, LoadIndex, StoreIndex, ArrayLen, ArrayPush |
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

### Computed-goto fast path (`vm_dispatch.c`)

`vm_dispatch.c` mirrors `vm.ms`/`value.ms`/`module.ms` struct layout exactly (see `_RD_*` typedefs in the file). Any field change in those `.ms` files breaks the C dispatch — keep them in sync. Opcode numeric values are mirrored at the top of the C file.

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
rm -rf out && bun run test-ms src/raiser/value.ms

# Full VM
rm -rf out && bun run test-ms src/raiser/vm.ms

# Codegen + VM end-to-end (in src/codegen/raiser/)
rm -rf out && bun run test-ms src/codegen/raiser/eval.ms

# Phase 1 spike bench
rm -rf out && bun run run-ms run src/raiser/spike/bench.ms
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
