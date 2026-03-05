# ORC — Orchestration & Resilient Compilation

This document tracks high-level architectural strategies for the MetaScript compiler's core engine, focusing on scalability, resilience, and incrementalism.

---

## The Resilient Module & Incremental Pillar (Strategic P0)

**Goal**: Transition MetaScript from a batch processor to a production-grade incremental engine capable of compiling its own 174-file source tree without silent failures or redundant work.

### 1. Module System: Cycle Resilience
Currently, the module loader is the "glass jaw" of the compiler.

*   **The Problem**: Circular imports (e.g., `A -> B -> A`) are silently dropped by the loader to prevent infinite recursion. This leads to "Symbol not found" errors in the C generator or incomplete type information in the checker.
*   **Context**: In a systems language with 100+ files, circular dependencies are an architectural reality.
*   **Strategy**:
    *   Implement a **Cycle Detection Stack** in `src/module/loader.ms`.
    *   Move from "Skip on Cycle" to "Forward-Declare on Cycle."
    *   **Phase 1 (Collector)**: Collect all exported type signatures across the cycle before attempting to resolve function bodies.
    *   **Phase 2 (Codegen)**: The C backend must emit forward-declarations for all types in the cycle at the top of every `.c` file involved.

### 2. Incremental Build: Content-Based Recompilation
Iteration speed is currently O(N) where N is the total number of modules. It should be O(M) where M is the number of *changed* modules.

*   **The Problem**: Every `msc build` invokes the C compiler for every single module, even if the source hasn't changed.
*   **Context**: Iteration time for the self-hosted compiler is already exceeding 500ms; it will soon reach seconds.
*   **Strategy**:
    *   **Level 1 (C-Caching)**: Implement a "Content Match" check in `src/compiler/compile.ms`.
    *   **Algorithm**:
        1.  Generate the C code string for module `X`.
        2.  Read the existing `.c` file from `.msc_cache/X.c`.
        3.  If `new_string === old_string` AND `.o` exists, **skip the Clang invocation**.
    *   **Impact**: Iterative changes to a single file will result in near-instant sub-100ms builds.

### 3. Error Recovery: The "Usability" Bridge
The compiler must be helpful, not just correct.

*   **The Problem**: The first type error often halts the pipeline or causes a crash.
*   **Strategy**:
    *   Introduce the **`Error` Type Kind** (`TypeKind.Error`) into the checker.
    *   When an expression fails to check, assign it `TypeKind.Error` and continue checking the rest of the file.
    *   **Benefit**: Allows the developer to see a full report of all issues in the project at once.

---

## The Zero-Copy Slicing Pillar (High-Performance Optimization)

**Goal**: Eliminate heap allocations when performing array/string slicing, matching the performance of Nim's `openArray` slices and Zig's slices.

### ~~B1. Zero-Copy Slicing Syntax: `arr[start...end]`~~ (DONE)
Currently, slicing an array in MetaScript triggers a call to the C runtime's `msArraySlice`, which allocates new heap memory and copies data.

*   **The Strategy**: Transform the `ArrayAccess` with a range into a `Span` literal.
*   **Target**: `src/transform/lowering/spanLower.ms`.
*   **Logic**:
    *   **Input**: `const s: Span<number> = arr[1...3];`
    *   **Transformation**:
        *   **Pointer**: `arr.p->data + 1` (Offset calculation)
        *   **Length**: `3 - 1` (Count calculation)
    *   **Resulting C**: `msSpan_double s = { .data = arr.p->data + 1, .len = 2 };`
*   **Benefit**: Zero heap overhead. This is essential for high-performance parsers where the Lexer needs to "view" tokens without copying them from the source buffer.

### ~~B2. Stack-Promoted Literals~~ (DONE)
*   **The Strategy**: Promote `[1, 2, 3]` directly to the C stack when passed to a `Span<T>` parameter.
*   **Transformation**: Instead of creating a temporary heap-allocated `msArray`, the compiler emits a C99 compound literal or a temporary stack struct.
*   **Benefit**: Massive reduction in heap pressure for constant lookups and small utility calls.

---

## The Gaskets and Governors Pillar (Internal Safety)

**Goal**: Ensure the safety of systems-level optimizations (COW, Spans) without requiring manual developer intervention.

### ~~1. COW Enforcement (The Gasket)~~ (DONE)
Prevent accidental corruption of shared string literals or constant arrays.
*   **The Strategy**: Rigorously inject `msStringPrepareMutation(&s)` in `nativeLower.ms` before any mutating operation (`s[i] = ch`, `s.add()`).
*   **Mechanism**: Fast bitwise check on the `strlitFlag` in the payload capacity.

### 2. Escape Analysis (The Governor)
Prevent memory corruption from dangling pointers when using zero-copy views.
*   **The Strategy**: Implement a pass in `src/analyzer/index.ms` to ensure a `Span<T>` never "escapes" its owner's scope.
*   **Rules**:
    *   Block `Span` from being returned from a function (unless the owner is a parameter).
    *   Block `Span` from being stored in a global variable or a class field.

---

## ~~The Borrow Pillar (`Borrow<T>`)~~ (DONE)

**Goal**: Achieve 100% performance parity with Nim's `lent T` by avoiding memory copies for large structs.

*   **Syntax**: `const x: Borrow<LargeStruct> = arr[0];`
*   **Implementation**: 
    1.  Add `TypeKind.Borrow` to the type system.
    2.  Update `src/codegen/c/` to emit raw pointers for `Borrow` types.
    3.  Integrate with the analyzer to enforce strict lifetime safety.

---

## Pillar Implementation Status

| Feature | Status | Priority | Files Involved |
| :--- | :--- | :--- | :--- |
| **Cycle Detection** | PLANNED | P0 | `src/module/loader.ms`, `src/module/graph.ms` |
| **C-Caching** | PLANNED | P1 | `src/compiler/compile.ms`, `src/compiler/io.ms` |
| **Error Type Sink** | PLANNED | P1 | `src/checker/context.ms`, `src/checker/checkPass.ms` |
| **COW Enforcement** | **DONE** | P1 | `src/transform/native/nativeLower.ms` |
| **Escape Analysis** | PLANNED | P2 | `src/analyzer/index.ms` |
| **Borrow Pillar** | **DONE** | P2 | `src/checker/types.ms`, `src/codegen/c/` |
| ~~Zero-Copy Slicing~~ | **DONE** | P1 | `src/transform/lowering/spanLower.ms` |
| ~~Stack Literals~~ | **DONE** | P2 | `src/transform/lowering/spanLower.ms` |

---

## Future Orchestration Items
*(To be populated as more pillars are identified)*
