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

### Phase 1: Stabilization & Isolation
*   **Status: COMPLETE**
*   **Result:** Reached "Zero Type Errors" in the core Raiser source code and FFI bindings.
*   **Key Fixes:**
    *   Resolved `int32` vs `number` mismatches in `aro.ms` via explicit casts.
    *   Implemented a safe `parseIntStr` in `utils/string.ms` to replace JS-global `parseInt`.
    *   Fixed missing imports in `vm.ms` and added recursive walker null-guards.
    *   Isolated the VM via `debug_raiser.ms` for faster development cycles.

### Phase 2: Semantic Parity (The Lowering Pipe)
*   **Goal:** 100% fidelity with MetaScript runtime behavior.
*   **Action:** Update `Raiser Codegen` to consume nodes after the `Transform` phase.
*   **Benefit:** Raiser automatically supports `match` expressions and `Result` types because they are lowered to `if/else` and `struct` access before the VM sees them.

### Phase 3: Metaprogramming Runtime (Comptime Hooks)
*   **Goal:** Functional `@comptime` blocks in `msc`.
*   **Action:** Re-attach `evaluateComptimeBlocks` in `src/compiler/comptime.ms`.
*   **Mechanism:** Capture `lastResult` from the VM and "fold" it into the AST as a literal (Number, String, or ObjectLiteral).

### Phase 4: Performance & Memory (Arena 2.0)
*   **Goal:** Sustainable execution for complex build scripts.
*   **Action:** Implement `clearHeap()` to reset VM state between independent `@comptime` blocks.
*   **Optimization:** Investigate "Monomorphic Call Sites" in the bytecode to speed up object property access.

## 4. Current Blockers (B14-Raiser)

- [x] **Type Health:** Resolved `int32` vs `number` mismatches in `src/module/aro.ms`.
- [x] **Import Desync:** `createRaiserFunction` and `createRaiserModule` added to `vm.ms`.
- [x] **Walker Crash:** `null is not an object` in `arrayMethodInline.ms` fixed with null-guard.
- [x] **parseInt Conflict:** Replaced JS global `parseInt` with `parseIntStr` in `resolvePass.ms`.
- [ ] **Aro Prototype Gaps:** Missing C function prototypes for `msAro*` in the C output.

## 5. Implementation Status

*   **Instruction Dispatch:** COMPLETE (C-backend bridge active).
*   **Value Representation:** COMPLETE (Handle-based heaps active).
*   **Codegen:** FUNCTIONAL (Basic expressions and statements).
*   **Integration:** DETACHED (Currently bypassed via B13 to unblock C-backend bootstrap).
