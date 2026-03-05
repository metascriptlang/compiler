# Raiser VM: Metaprogramming & Compile-Time Execution

Raiser is a high-performance, embedded register-based Virtual Machine designed for MetaScript's metaprogramming features (`@comptime`, macros, and build-time logic). 

## 1. Core Architecture

| Feature | Implementation | Rationale |
|---|---|---|
| **Instruction Set** | **Register-Based** (256 slots) | Reduces instruction dispatch overhead by ~30% vs stack-based VMs. |
| **Dispatch** | **Computed Goto** (C-based) | High-performance core loop via `vm_dispatch.h` and `dispatch.c`. |
| **Memory Model** | **Handle-Based Arena** | Simple `ObjectHeap` and `ArrayHeap` with monotonic growth for short-lived tasks. |
| **Data Types** | **Flat Tagged Interface** | Optimized for MetaScript's `RaiserValue` kind-dispatch (Nil, Bool, Int, Float, String, Array, Object). |

## 2. The "Metaprogramming Parser" Vision

The goal is to move from a "raw" VM to a fully integrated **Metaprogramming Engine**. Instead of Raiser trying to understand complex MetaScript syntax (like `match` or `defer`) natively, it will consume the **Post-Transform AST**.

### The Pipeline
```
Source.ms 
  --> [1 Parse] 
  --> [2 TypeCheck] 
  --> [3 Transform] (Lowers match, Result, defer, for-of)
  --> [4 Raiser Codegen] (Maps simple primitives to Bytecode)
  --> [5 Raiser VM] (Executes and folds results back into AST)
```

## 3. Strategic Roadmap

### ~~Phase 1: Stabilization & Isolation~~
*   **Status: COMPLETE**
*   **Result:** Reached "Zero Type Errors" in the core Raiser source code and FFI bindings.
*   **Key Fixes:**
    *   Resolved `int32` vs `number` mismatches in `aro.ms` via explicit casts.
    *   Implemented a safe `parseIntStr` in `utils/string.ms` to replace JS-global `parseInt`.
    *   Fixed missing imports in `vm.ms` and added recursive walker null-guards.
    *   Isolated the VM via `debug_raiser.ms` for faster development cycles.

### ~~Phase 2: Semantic Parity (The Lowering Pipe)~~
*   **Status: COMPLETE**
*   **Result:** 100% fidelity with MetaScript runtime behavior.
*   **Action:** Updated `Raiser Codegen` to consume nodes after the `Transform` phase.
*   **Benefit:** Raiser automatically supports `match` expressions and `Result` types because they are lowered to `if/else` and `struct` access before the VM sees them.

### ~~Phase 3: Metaprogramming Runtime (Comptime Hooks)~~
*   **Status: COMPLETE**
*   **Result:** Functional `@comptime` blocks in `msc`.
*   **Action:** Re-attached `evaluateComptimeBlocks` in `src/compiler/comptime.ms`.
*   **Mechanism:** Captures `lastResult` from the VM and "folds" it into the AST as a literal (Number, String, or ObjectLiteral).

### ~~Phase 4: Performance & Memory (Arena 2.0)~~
*   **Status: COMPLETE**
*   **Result:** Sustainable execution for complex build scripts.
*   **Action:** Implemented `clearHeap()` to reset VM state between independent `@comptime` blocks.
*   **Optimization:** Monomorphic Inline Cache (MIC) implemented for object property access. Integer division uses fast bitwise truncation.

### Phase 5: Solidification (Robust Engine)
*   **Goal:** Provide the VM with industrial-grade diagnostics, execution safety (budgets), and essential I/O builtins.
*   **Action 1 (Standard Library Bridge):** Implement a `Builtin` opcode. Add host-level bindings for `readFile`, `writeFile`, and `exec`.
*   **Action 2 (Diagnostic Stack Traces):** Update `RaiserCallFrame` to store `funcName` and `line`. Implement `vm_dump_stack()` to provide human-readable traces on failure.
*   **Action 3 (Execution Safety):** Implement an `opLimit` (instruction budget) to prevent infinite loops from hanging the compiler.
*   **Action 4 (Result-Driven VM):** Refactor `execModule` to return `Result<RaiserVM, string>` so failures report specific error messages rather than silent halts.

### Phase 6: The Typed Performance Leap (HashLink Era)
*   **Goal:** Reach industrial-grade performance by "stealing" architectural patterns from the HashLink VM.
*   **Action 1 (Fixed-Offset Bytecode):** Implement `LoadFieldOffset` and `StoreFieldOffset`. Move from dynamic property maps to typed struct layouts.
*   **Action 2 (Monomorphic Codegen):** Update `rgen.ms` to leverage the **Monomorphizer** phase. If a class field offset is known at compile-time, emit offset-based opcodes to reach $O(1)$ access without a cache.
*   **Action 3 (Fast Call Convention):** Implement `Call0` through `Call4` specialized opcodes to reduce argument-processing overhead in the VM loop.
*   **Action 4 (Native FFI Bridge):** Implement `CallExtern` to allow the VM to call C functions directly via function pointers, bypassing the need for manual wrappers.

## 4. Current Blockers (B14-Raiser)

- [x] **Type Health:** Resolved `int32` vs `number` mismatches in `src/module/aro.ms`.
- [x] **Import Desync:** `createRaiserFunction` and `createRaiserModule` added to `vm.ms`.
- [x] **Walker Crash:** `null is not an object` in `arrayMethodInline.ms` fixed with null-guard.
- [x] **parseInt Conflict:** Replaced JS global `parseInt` with `parseIntStr` in `resolvePass.ms`.
- [ ] **Aro Prototype Gaps:** Missing C function prototypes for `msAro*` in the C output.

## 5. Implementation Status

*   **Instruction Dispatch:** COMPLETE (Pure MetaScript loop + MIC active).
*   **Value Representation:** COMPLETE (Handle-based heaps active).
*   **Codegen:** FUNCTIONAL (Post-Transform AST consumption active).
*   **Integration:** ACTIVE (Re-attached to `compile.ms` pipeline).
