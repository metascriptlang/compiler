# Raiser VM — Self-Hosted Bytecode Backend

Statically-typed bytecode VM for MetaScript. Alternative backend to C and JS codegen. Leverages full compiler analysis (type info, transforms, DRC classification) to emit optimized typed opcodes with zero runtime type dispatch.

Architecture: **Wasm-inspired typed stacks** + **LuaJIT-inspired instruction encoding** + **switch dispatch** (ASM dispatch is a future layer).

---

## Pipeline Position

```
Source.ms --> [1 Parse] --> [2 Check] --> [3 Transform] --> [4 Analyze] --> [5 Raiser] --> Execute
                              |                               |               |
                         Type info                    Type classification   Compile + Run
                         (TypeKind,                   (RcKind, scope        (bytecode)
                          Scope)                       analysis)
```

The Raiser compiler consumes the **post-analyze AST** (same as C backend) and uses:
- **CheckerContext** type info — determines which typed opcodes to emit (add_i32 vs add_i64 vs add_f64)
- **Type classification** — RC types get runtime refcounting ops, primitives get direct register operations
- **Transform results** — match/defer/for-of already lowered to if-else/try-finally/while

---

## Lessons from Reference (Problems → Solutions)

| Problem | Reference (~19K lines) | Self-Hosted Fix |
|---------|----------------------|----------------|
| **Bloat** | AOT native compilation, NaN-boxing, promises, async, event loop, peephole — all day-1 | Layered bring-up: switch dispatch first, each layer adds one concern |
| **Monolithic ASM** | 2045-line `vm_arm64.s`, 728-line `vm_dispatch_x64.s` — all handlers in one file | One `.ms` file per opcode family (~100-200 lines), independently testable |
| **Slow iteration** | External Zig test files, full rebuild required, 7 execution tests for 127 opcodes | Inline `testGroup` per file, hand-constructed bytecode tests, `bun run test-ms` in <1s |

---

## Layered Architecture

```
Layer 0: Bytecode format     — RvOpcode, RvInstruction, RvValue, RvModule        (~400 lines)
Layer 1: Switch interpreter  — dispatch loop + i64 ops (arithmetic/memory/branch) (~500 lines)
Layer 2: Full numeric types  — add i32, f32, f64 handlers + type conversions      (~400 lines)
Layer 3: Bytecode compiler   — AST→bytecode using CheckerContext type info        (~800 lines)
Layer 4: Objects & arrays    — new_object, field access, array indexing           (~300 lines)
────────────────── Day-1 scope above, future scope below ──────────────────────────
Layer 5: Strings             — string concat, comparison, RC                      (~200 lines)
Layer 6: Closures            — env struct, indirect calls, capture analysis       (~400 lines)
Layer 7: ORC integration     — runtime refcounting, cycle detection               (~300 lines)
Layer 8: Peephole optimizer  — strength reduction, constant folding               (~300 lines)
Layer 9: ASM dispatch        — hand-written ARM64/x64 dispatch (separate dir)     (~TBD)
```

Each layer is fully testable before the next begins. Layer 0 tests encoding round-trips. Layer 1 tests execute hand-built bytecode. Layer 3 tests parse source → compile → execute.

---

## Files

```
src/raiser/
  CLAUDE.md                  -- this file
  index.ms                   -- Hub: compileToRaiser, executeRaiser, evalSource, E2E tests
  bytecode.ms                -- RvOpcode enum (~90 opcodes), RvInstruction, encoding helpers
  value.ms                   -- RvValue interface, RvValueKind enum, constructors
  module.ms                  -- RvFunction, RvModule, RvConstPool, RvFunctionList
  compiler/
    index.ms                 -- Hub: compileProgram
    context.ms               -- RvCompiler state, register allocator, scope stack, struct layouts
    expressions.ms           -- compileExpression: AST expression → typed bytecode
    statements.ms            -- compileStatement: variable decls, if/while/block/return
    declarations.ms          -- function/struct collection (two-phase), function compilation
  vm/
    index.ms                 -- Hub: executeModule
    context.ms               -- RvVM, RvCallFrame, typed register files, call stack
    dispatch.ms              -- Main while loop + if/else dispatch to op handlers
    ops/
      index.ms               -- Hub: re-exports all op families
      arithmeticI64.ms       -- add/sub/mul/div/mod/neg for i64
      arithmeticI32.ms       -- add/sub/mul/div/mod/neg for i32
      arithmeticF64.ms       -- add/sub/mul/div/neg for f64
      arithmeticF32.ms       -- add/sub/mul/div/neg for f32
      memory.ms              -- load_const, load_local, store_local (all types), move
      control.ms             -- jump, call, ret, halt, print
      compare.ms             -- fused compare-branch for all 4 types
      convert.ms             -- i32↔i64, i32↔f64, f32↔f64, etc. (12 ops)
      objects.ms             -- new_object, load_field, store_field (Layer 4)
      arrays.ms              -- new_array, load_index, store_index (Layer 4)
```

**19 files total.** Each ops file ~100-150 lines with inline tests. Run any file independently:
```bash
rm -rf out && bun run test-ms src/raiser/vm/ops/arithmeticI64.ms
```

---

## Bytecode Format

### Instruction Encoding — 32-bit, Lua-style

```
ABC  format:  [op:8][A:8][B:8][C:8]         — 3 operands
ABx  format:  [op:8][A:8][Bx:16]            — operand + 16-bit immediate
Ax   format:  [op:8][Ax:24]                 — 24-bit signed immediate (jumps)
```

`RvInstruction` is a flat interface with `op`, `a`, `b`, `c` fields. Encoding/decoding helpers: `rvABC()`, `rvABx()`, `rvAx()`, `getBx()`, `getSignedBx()`, `getSignedAx()`.

### Opcode Table

**Arithmetic (22 opcodes)**

| Op | i32 | i64 | f32 | f64 | Format | Semantics |
|----|-----|-----|-----|-----|--------|-----------|
| Add | AddI32 | AddI64 | AddF32 | AddF64 | ABC | T[A] = T[B] + T[C] |
| Sub | SubI32 | SubI64 | SubF32 | SubF64 | ABC | T[A] = T[B] - T[C] |
| Mul | MulI32 | MulI64 | MulF32 | MulF64 | ABC | T[A] = T[B] * T[C] |
| Div | DivI32 | DivI64 | DivF32 | DivF64 | ABC | T[A] = T[B] / T[C] |
| Mod | ModI32 | ModI64 | — | — | ABC | T[A] = T[B] % T[C] |
| Neg | NegI32 | NegI64 | NegF32 | NegF64 | ABC | T[A] = -T[B] |

**Typed Memory (12 opcodes)**

| Op | Format | Semantics |
|----|--------|-----------|
| LoadConst{I32,I64,F32,F64} | ABx | T[A] = constants[Bx] |
| LoadLocal{I32,I64,F32,F64} | ABx | T[A] = locals[Bx] |
| StoreLocal{I32,I64,F32,F64} | ABx | locals[Bx] = T[A] |

**Typed Compare-Branch (24 opcodes)**

| Op | i32 | i64 | f32 | f64 | Format | Semantics |
|----|-----|-----|-----|-----|--------|-----------|
| Beq | BeqI32 | BeqI64 | BeqF32 | BeqF64 | ABC | if T[A] == T[B] skip C |
| Bne | BneI32 | BneI64 | BneF32 | BneF64 | ABC | if T[A] != T[B] skip C |
| Blt | BltI32 | BltI64 | BltF32 | BltF64 | ABC | if T[A] < T[B] skip C |
| Ble | BleI32 | BleI64 | BleF32 | BleF64 | ABC | if T[A] <= T[B] skip C |
| Bgt | BgtI32 | BgtI64 | BgtF32 | BgtF64 | ABC | if T[A] > T[B] skip C |
| Bge | BgeI32 | BgeI64 | BgeF32 | BgeF64 | ABC | if T[A] >= T[B] skip C |

**Type Conversions (12 opcodes)**

```
I32ToI64  I32ToF32  I32ToF64
I64ToI32  I64ToF32  I64ToF64
F32ToI32  F32ToI64  F32ToF64
F64ToI32  F64ToI64  F64ToF32
```
Format: ABC — T_dest[A] = convert(T_src[B])

**Control Flow (5 opcodes)**

| Op | Format | Semantics |
|----|--------|-----------|
| Jump | Ax | pc += sAx (24-bit signed offset) |
| Call | ABC | R[A] = call func[B] with C args from R[A+1] |
| Ret | ABC | return T[A] (typed by function return type) |
| Halt | ABC | stop execution, exit value = R[A] |
| Print | ABC | debug print R[A] |

**Generic Memory (5 opcodes)**

| Op | Format | Semantics |
|----|--------|-----------|
| Move | ABC | R[A] = R[B] |
| LoadNil | ABC | R[A] = nil |
| NewObject | ABC | R[A] = new object with B fields |
| NewArray | ABC | R[A] = new array from R[A+1..A+B] |
| LoadConst | ABx | R[A] = constants[Bx] (generic Value) |

**Object/Array Access (4 opcodes)**

| Op | Format | Semantics |
|----|--------|-----------|
| LoadField | ABC | R[A] = R[B].fields[C] |
| StoreField | ABC | R[A].fields[B] = R[C] |
| LoadIndex | ABC | R[A] = R[B][R[C]] |
| StoreIndex | ABC | R[A][R[B]] = R[C] |

**RC Operations (3 opcodes, Layer 7)**

| Op | Semantics |
|----|-----------|
| Incref | R[A].refcount++ |
| Decref | R[A].refcount-- (deferred) |
| FlushRc | Process deferred decrements |

**Total: ~87 opcodes** (vs reference's 127). Growth path: super-instructions, string ops, closure ops added in later layers.

---

## Type Interfaces

All Raiser VM types use `Rv` prefix to avoid C namespace collision.

### Core Data Types (`bytecode.ms`, `value.ms`, `module.ms`)

```ms
// bytecode.ms
export enum RvOpcode { AddI32, AddI64, AddF32, AddF64, ... }  // ~87 members

export interface RvInstruction {
    op: number;        // RvOpcode value
    a: number;         // 8-bit operand A
    b: number;         // 8-bit operand B
    c: number;         // 8-bit operand C
}

// value.ms
export enum RvValueKind { Int32, Int64, Float32, Float64, Bool, Nil, String, Object, Array }

export interface RvValue {
    kind: RvValueKind;
    intVal: number;      // i32/i64
    floatVal: number;    // f32/f64
    boolVal: boolean;    // Bool
    strVal: string;      // String (future)
}

// module.ms
export interface RvConstPool { values: RvValue[]; }
export interface RvCodeBuf { items: RvInstruction[]; }

export interface RvFunction {
    name: string;
    code: RvCodeBuf;
    constants: RvConstPool;
    arity: number;
    localsCount: number;
    maxRegs: number;
    returnType: RvValueKind;    // typed return
}

export interface RvFunctionList { items: RvFunction[]; }
export interface RvModule { name: string; functions: RvFunctionList; entry: number; }
```

### VM State (`vm/context.ms`)

```ms
export interface RvRegI32 { slots: number[]; }    // i32 register file
export interface RvRegI64 { slots: number[]; }    // i64 register file
export interface RvRegF32 { slots: number[]; }    // f32 register file
export interface RvRegF64 { slots: number[]; }    // f64 register file
export interface RvRegVal { slots: RvValue[]; }   // generic Value register file

export interface RvCallFrame {
    funcIdx: number;
    ip: number;
    baseI32: number;     // base offset into i32 register file
    baseI64: number;     // base offset into i64 register file
    baseF32: number;     // base offset into f32 register file
    baseF64: number;     // base offset into f64 register file
    baseVal: number;     // base offset into Value register file
    retReg: number;      // caller's return register
    retKind: RvValueKind;  // which register file gets the return value
}

export interface RvCallStack { frames: RvCallFrame[]; }

export interface RvVM {
    module: RvModule;
    regI32: RvRegI32;
    regI64: RvRegI64;
    regF32: RvRegF32;
    regF64: RvRegF64;
    regVal: RvRegVal;
    callStack: RvCallStack;
    halted: boolean;
    exitValue: RvValue;
}
```

### Compiler State (`compiler/context.ms`)

```ms
export interface RvLocal {
    name: string;
    reg: number;
    depth: number;
    kind: RvValueKind;    // type determines which register file
}

export interface RvLocalList { items: RvLocal[]; }
export interface RvStructLayout { name: string; fieldNames: string[]; fieldKinds: RvValueKind[]; }
export interface RvStructLayouts { items: RvStructLayout[]; }
export interface RvFuncEntry { name: string; index: number; }
export interface RvFuncMap { items: RvFuncEntry[]; }

export interface RvCompiler {
    code: RvCodeBuf;
    constants: RvConstPool;
    locals: RvLocalList;
    scopeDepth: number;
    localsCount: number;
    nextTemp: number;
    maxReg: number;
    functions: RvFuncMap;
    structLayouts: RvStructLayouts;
    currentFuncName: string;
    checkerCtx: CheckerContext;   // from Phase 2+4 — drives typed opcode selection
}
```

---

## VM Dispatch Architecture

### if/else chain (NOT match)

The dispatch loop uses `if/else` because `break`/`continue` in match arms targets the generated switch, not the enclosing `while` loop.

```ms
// vm/dispatch.ms
export function executeModule(vm: RvVM): RvValue {
    while (!vm.halted) {
        const frame = currentFrame(vm);
        const func = getFunc(vm, frame.funcIdx);
        const inst = func.code.items[frame.ip];
        frame.ip = frame.ip + 1;
        const op = inst.op;

        // Arithmetic i64
        if (op === RvOpcode.AddI64) { execAddI64(vm, frame, inst); }
        else if (op === RvOpcode.SubI64) { execSubI64(vm, frame, inst); }
        // ... all opcodes via if/else ...
        else if (op === RvOpcode.Halt) { vm.halted = true; vm.exitValue = getRegVal(vm, frame, inst.a); }
        else { vm.halted = true; }
    }
    return vm.exitValue;
}
```

### Typed Register Access

Each ops handler accesses the correct register file based on the opcode's type:

```ms
// In arithmeticI64.ms
export function execAddI64(vm: RvVM, frame: RvCallFrame, inst: RvInstruction): void {
    const base = frame.baseI64;
    const lhs = vm.regI64.slots[base + inst.b];
    const rhs = vm.regI64.slots[base + inst.c];
    vm.regI64.slots[base + inst.a] = lhs + rhs;
}

// In arithmeticF64.ms
export function execAddF64(vm: RvVM, frame: RvCallFrame, inst: RvInstruction): void {
    const base = frame.baseF64;
    const lhs = vm.regF64.slots[base + inst.b];
    const rhs = vm.regF64.slots[base + inst.c];
    vm.regF64.slots[base + inst.a] = lhs + rhs;
}
```

No runtime type dispatch — the opcode itself determines which register file is accessed.

---

## Compiler Architecture

### Typed Opcode Selection

The compiler uses `CheckerContext` type info to select the right opcode variant:

```ms
// compiler/expressions.ms
function compileBinaryExpr(comp: RvCompiler, node: Node): CompileResult {
    const d = node.data as BinaryExprData;
    const lReg = try compileExpression(comp, d.left);
    const rReg = try compileExpression(comp, d.right);
    const dest = allocTemp(comp);
    const kind = resolveNumericKind(comp, node);  // uses checker type info

    if (d.operator === "+") {
        if (kind === RvValueKind.Int32) { emitABC(comp, RvOpcode.AddI32, dest, lReg, rReg); }
        else if (kind === RvValueKind.Int64) { emitABC(comp, RvOpcode.AddI64, dest, lReg, rReg); }
        else if (kind === RvValueKind.Float32) { emitABC(comp, RvOpcode.AddF32, dest, lReg, rReg); }
        else { emitABC(comp, RvOpcode.AddF64, dest, lReg, rReg); }
    }
    // ... other operators ...
    return Result.ok(dest);
}
```

### Register Allocation — Lua Model

- Locals: `R[0..localsCount-1]` — permanent for function lifetime
- Temps: `R[localsCount..maxReg]` — scratch per statement, reset after each statement
- Parameters: `R[0..arity-1]` — declared as locals before compilation
- Each typed register file has independent allocation

### Two-Phase Compilation

1. **Collect phase**: Walk top-level statements, extract interface/enum definitions into `structLayouts` (field name → offset mapping)
2. **Compile phase**: Compile all statements to bytecode using collected layouts

### Conditional Branch Pattern — Inverse Skip + Jump

```ms
// Compiling: if (a > b) { ... } else { ... }
emitABC(comp, RvOpcode.BgtI64, aReg, bReg, 1);   // if a > b, skip 1
emitJumpPlaceholder(comp);                          // else: jump to false branch
// ... true branch ...
patchJump(comp, jumpIdx);                           // patch jump target
// ... false branch ...
```

---

## Testing Strategy

### Per-File: Hand-Constructed Bytecode

Every ops file has inline tests that construct bytecode, run it, and verify register state:

```ms
// vm/ops/arithmeticI64.ms
testGroup("RvOps i64 Arithmetic", () => {
    test("add", () => {
        const mod = makeTestModule([
            rvABx(RvOpcode.LoadConstI64, 0, 0),   // R0 = 10
            rvABx(RvOpcode.LoadConstI64, 1, 1),   // R1 = 20
            rvABC(RvOpcode.AddI64, 2, 0, 1),      // R2 = R0 + R1
            rvABC(RvOpcode.Halt, 2, 0, 0),
        ], [rvInt64(10), rvInt64(20)]);
        const vm = createRvVM(mod);
        const result = executeModule(vm);
        check(result.intVal === 30);
    });
    // test sub, mul, div, mod, neg, division-by-zero ...
});
```

### E2E: Source → Compile → Execute

In `index.ms`:

```ms
testGroup("Raiser E2E", () => {
    test("arithmetic", () => {
        const r = evalSource("return 2 + 3 * 4;");
        check(r.intVal === 14);
    });
    test("function call", () => {
        const r = evalSource("function add(a: number, b: number): number { return a + b; } return add(10, 20);");
        check(r.intVal === 30);
    });
    test("if-else", () => {
        const r = evalSource("const x = 5; if (x > 3) { return 1; } else { return 0; }");
        check(r.intVal === 1);
    });
});
```

### Test Helpers (`module.ms` or shared in `vm/context.ms`)

```ms
// Create a single-function module from instructions + constants
export function makeTestModule(code: RvInstruction[], constants: RvValue[]): RvModule { ... }
```

### Test Hierarchy

```
rm -rf out && bun run test-ms src/raiser/vm/ops/arithmeticI64.ms   # one family
rm -rf out && bun run test-ms src/raiser/vm/index.ms                # all VM ops
rm -rf out && bun run test-ms src/raiser/compiler/index.ms          # compiler only
rm -rf out && bun run test-ms src/raiser/index.ms                   # full Raiser suite
rm -rf out && bun run test-ms src/index.ms                          # everything
```

---

## DRC Workarounds

| Rule | Application in Raiser |
|------|----------------------|
| Arrays by pointer | Wrappers removed — bare `T[]` types (`RaiserInstruction[]`, `RaiserValue[]`, etc.) |
| No try in match arms | Dispatch uses if/else chain, never match |
| const before function arg | Store `RvValue` in const before pushing to arrays |
| No C-style for in match | Use while loops everywhere |
| Interface name prefix | All types use `Rv` prefix: RvVM, RvValue, RvOpcode, etc. |
| No indexOf/includes | Use slice, length, findChar from utils/string.ms |
| `null as unknown as T` | For nullable fields in RvCallFrame, RvCompiler |

---

## Integration Point

```ms
// src/index.ms — add alongside compileToJS
import { compileToRaiser, executeRaiser } from "./raiser/index";

export function evalSource(input: string): RvValue {
    const parseResult = parseSource(input);
    if (!parseResult.ok) return rvNil();
    const program = parseResult.value;
    const checkerCtx = checkProgram(program);
    const transformed = transformProgram(program, checkerCtx);
    const analyzed = analyzeProgram(transformed, checkerCtx);
    const mod = compileToRaiser(analyzed, checkerCtx);
    return executeRaiser(mod);
}
```

---

## NOT Day-1 (Future Layers)

| Feature | Why Deferred | Layer |
|---------|-------------|-------|
| String operations | Need RC integration | 5 |
| Closures | Need env struct + indirect call | 6 |
| ORC / RC | Need cycle detection, deferred decref | 7 |
| Peephole optimizer | Need correctness first | 8 |
| ASM dispatch | Need switch dispatch proven first | 9 |
| NaN-boxing | Optimization — profile before deciding | 9+ |
| AOT native compilation | Way later, if ever | 10+ |
| Async/await | Need event loop, promise runtime | 10+ |
| Super-instructions | Need profiling data to choose which | 8+ |
| .msb binary format | Need stable opcode numbering first | 5+ |

---

## Reference Cross-Reference

| Self-Hosted | Reference File | What to Adapt |
|------------|---------------|---------------|
| `bytecode.ms` | `bytecode.zig` (2550 lines) | Opcode enum, Instruction encoding — NOT Value/Object/SSOString |
| `value.ms` | `bytecode.zig` Value union | Flat interface, not tagged union. Day-1: numeric kinds only |
| `module.ms` | `bytecode.zig` Function/Module | Same structure, DRC-safe wrappers |
| `compiler/*.ms` | `compiler.zig` (4891 lines) | Register alloc model, two-phase — NOT async/constant-prop |
| `vm/dispatch.ms` | `vm_x64.zig` (304 lines) | Switch dispatch pattern — NOT ASM |
| `vm/ops/*.ms` | `vm_arm64.s` (2045 lines) | Opcode semantics — NOT assembly |
