# MetaScript Primitive Data Types — Gap Analysis

Comprehensive status of non-array/string primitive and compound types in MetaScript vs. reference and TypeScript implementations.

---

## Status Overview

| Type | Kind | Status | Implementation | Gap vs. Reference/TS |
| :--- | :--- | :--- | :--- | :--- |
| ~~`number`~~ | ~~Primitive~~ | ~~**DONE**~~ | ~~64-bit float (double)~~ | ~~Reference has `int` / `float` distinction~~ |
| ~~`int32/64`~~ | ~~Primitive~~ | ~~**DONE**~~ | ~~Sized C integers~~ | ~~Full parity~~ |
| ~~`boolean`~~ | ~~Primitive~~ | ~~**DONE**~~ | ~~C `bool`~~ | ~~Full parity~~ |
| ~~`char`~~ | ~~Primitive~~ | ~~**DONE**~~ | ~~C `char` / `int8`~~ | ~~Full parity~~ |
| ~~`string`~~ | ~~Managed~~ | ~~**DONE**~~ | ~~COW / UTF-8~~ | ~~TS `.length` parity implemented~~ |
| ~~`Tuple`~~ | ~~Compound~~ | ~~**DONE**~~ | ~~Proper C structs~~ | ~~Reference has anonymous structs~~ |
| ~~`Map<K, V>`~~ | ~~Managed~~ | ~~**DONE**~~ | ~~Open-addressing SoA~~ | ~~High-perf C runtime implemented~~ |
| ~~`Set<T>`~~ | ~~Managed~~ | ~~**DONE**~~ | ~~Map wrapper (typedef)~~ | ~~Reference has `HashSet`~~ |
| ~~`Result<T, E>`~~ | ~~Compound~~ | ~~**DONE**~~ | ~~Object literal lowering~~ | ~~Standard reference parity~~ |
| ~~`cstring`~~ | ~~Primitive~~ | ~~**DONE**~~ | ~~Pointer alias~~ | ~~Reference/C interop parity~~ |

---

## The Map & Set Gap (Strategic Blocker)

Currently, `Map<K, V>` and `Set<T>` are recognized by the checker but have **zero implementation** in the standard library and **zero support** in the C codegen.

### 1. Map<K, V> (HashMap)
*   **The Issue**: The compiler itself uses Maps for scope tracking, but it runs on **Bun/JS** which provides them natively. A self-hosted MetaScript compiler cannot build its own scope table because it lacks a `Map` implementation that compiles to C.
*   **Strategy**: 
    1.  Implement `std/core/map.ms` using a flat `msRefArray` of entries.
    2.  Implement a hashing protocol (similar to standard reference hash procs).
    3.  Lower `new Map()` to a runtime constructor in C.

### 2. Set<T>
*   **The Issue**: Essential for deduplication and graph traversal (like module loading).
*   **Strategy**: Implement as a `Map<T, void>`.

---

## The Tuple Gap (Ergonomics)

*   **The Issue**: `[number, string]` is parsed as a Tuple but codegen treats it as `void*`.
*   **Standard Reference**: Reference tuples are typically anonymous structs.
*   **Strategy**: 
    1.  Update `src/codegen/c/types.ms` to generate a named `struct` for every unique Tuple signature.
    2.  Implement `t.0`, `t.1` index access in `nativeLower.ms`.

---

---

## Implementation Roadmap: The Collections Pillar

This roadmap tracks the transition of compound types from **STUB** to **PRODUCTION**.

### Phase 1: The HashMap Foundation (Strategic P0) — ~~DONE~~
**Goal**: Get `Map<string, T>` and `Map<number, T>` working to unblock the compiler's internal scope tables and symbol lookups.
*   [x] **M1.1: C Runtime Core**: Implement open-addressing hash table in `runtime/core/map.c`.
*   [x] **M1.2: Stdlib Interface**: Define `Map<K, V>` in `std/core/map.ms`.
*   [x] **M1.3: Codegen Mapping**: Map `TypeKind.Map` to `msMap*` in `src/codegen/c/types.ms`.
*   [x] **M1.4: Method Lowering**: Rewrite `m.get()`, `m.set()`, `m.has()` in `src/transform/native/builtinLower.ms`.
*   **Expectation**: `const m = new Map<string, number>(); m.set("a", 1);` compiles and runs in C.

### Phase 2: Set & Iteration (P1) — ~~DONE~~
**Goal**: Unblock graph traversal (module loader) and provide idiomatic `for-of` support.
*   [x] **M2.1: Set implementation**: Implement `Set<T>` as a wrapper around `Map<T, void>`.
*   [x] **M2.2: Iterator Protocol**: Support `for (const [k, v] of map)` in `nativeLower.ms`.
*   [x] **M2.3: Key/Value Views**: Implement `map.keys()` and `map.values()` zero-copy views.
*   **Expectation**: The compiler's module dependency graph can be traversed using native `Set` objects.

### Phase 3: Tuple & Anonymous Structs (P1) — ~~DONE~~
**Goal**: Move from `void*` hack to proper C struct representations for Tuples.
*   [x] **M3.1: Unique Struct Generation**: Update `src/codegen/c/types.ms` to emit a C `struct` for every unique Tuple signature (e.g., `msTuple_string_number`).
*   [x] **M3.2: Index remapping**: Rewrite `t.0`, `t.1` to direct C struct field access in `nativeLower.ms`.
*   **Expectation**: Tuples become type-safe, stack-allocated records in C.

### Phase 4: Full TS Utility Parity (P2) — ~~DONE~~
**Goal**: Complete the "Dumb Codegen" mapping for all remaining TS types.
*   [x] **M4.1: Record<K, V>**: Ensure full desugaring to `Map<K, V>`.
*   [x] **M4.2: WeakMap/WeakSet**: Decide on implementation (stubbed for now).
*   [x] **M4.3: Standard Methods**: Implement `Map.clear()`, `Map.size` (getter), etc.

### Phase 5: The FFI Bridge (cstring) (Strategic P1) — ~~DONE~~
**Goal**: Enable seamless, zero-copy interop with C libraries by providing a type that is implicitly compatible with `string`.
*   [x] **M5.1: TypeKind.CString**: Add `TypeKind.CString` to the type system.
*   [x] **M5.2: Implicit Coercion**: Allow `string -> cstring` implicit conversion in the checker.
*   [x] **M5.3: Codegen Mapping**: Map `cstring` to `const char*` in the C backend.
*   [x] **M5.4: Pointer Extraction**: Transform `string -> cstring` by extracting the raw buffer pointer (`s.p->data`).
*   **Expectation**: `extern function puts(s: cstring): void; const msg = "hi"; puts(msg);` works with zero overhead.

---

## Pillar Implementation Status

| Feature | Status | Priority | Files Involved |
| :--- | :--- | :--- | :--- |
| ~~**Map Foundation**~~ | ~~**DONE**~~ | ~~P0~~ | ~~`runtime/core/map.c`, `std/core/map.ms`~~ |
| ~~**Set Wrapper**~~ | ~~**DONE**~~ | ~~P1~~ | ~~`std/core/set.ms`~~ |
| ~~**Tuple Structs**~~ | ~~**DONE**~~ | ~~P1~~ | ~~`src/codegen/c/types.ms`~~ |
| ~~**Map Iteration**~~ | ~~**DONE**~~ | ~~P1~~ | ~~`src/transform/native/nativeLower.ms`~~ |
| ~~**FFI Bridge**~~ | ~~**DONE**~~ | ~~P1~~ | ~~`src/checker/compat.ms`, `src/codegen/c/`~~ |
