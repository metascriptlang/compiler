# MetaScript Runtime Architecture

Runtime design for the MetaScript compiler. Covers memory management (ORC), string/array operations, and the split between pure C foundation and MetaScript-authored runtime.

---

## Why This Matters

MetaScript targets 3 backends: C, JavaScript, and Raiser (bytecode). The runtime must provide consistent semantics — particularly **mutable strings** and **value-type arrays** — across all backends. This drives the most important architectural decision: what's written in C vs what's written in MetaScript.

---

## Architecture: Two Layers

```
┌─────────────────────────────────────────────────────┐
│  String/Array Runtime (MetaScript .ms)              │
│  includes, replace, trim, split, push, pop, sort... │
│  Compiles to C for C backend, JS for JS backend     │
├─────────────────────────────────────────────────────┤
│  ORC Foundation (Pure C headers)                    │
│  msRefHeader, ms_incref, ms_decref, alloc, dealloc  │
│  msString struct layout, msArray struct layout       │
│  C backend only — JS uses GC, Raiser has own model  │
└─────────────────────────────────────────────────────┘
```

| Layer | Language | Used By | Why |
|-------|----------|---------|-----|
| **ORC** (refcounting, allocation, struct layouts) | Pure C | C backend only | JS has GC, Raiser has own memory model. Low-level pointer/memory ops can't be expressed in .ms. |
| **String runtime** (includes, replace, trim, split, pad, etc.) | MetaScript (.ms) | C + JS + Raiser | Must compile to both C and JS. Mutable string semantics required on all backends. |
| **Array runtime** (push, pop, slice, sort, join, etc.) | MetaScript (.ms) | C + JS + Raiser | Same — value-type array semantics on all backends. |

---

## Why ORC Is Pure C

ORC (deterministic reference counting) is C-backend-specific infrastructure:

- **JS backend**: JavaScript's built-in GC handles all memory. No refcounting needed.
- **Raiser backend**: The Raiser VM has its own memory model. Skips Phase 4 (DRC) entirely.
- **Implementation**: Pointer arithmetic, `realloc`, `memcpy`, struct layout control, `__attribute__((aligned))` — things that can't be expressed in MetaScript.

ORC includes:
- `msRefHeader` (refcount header for heap objects)
- `ms_incref` / `ms_decref` / `ms_decref_reassign`
- `msString` struct layout
- `msArray` struct layout
- Memory allocation (`alloc`, `dealloc`, `realloc`)
- COW (copy-on-write) for string literals via `strlitFlag`

Location: `runtime/orc.h` (or equivalent C headers).

---

## Why String/Array Runtime Is MetaScript

This is a key architectural choice validated by proven systems-language designs.

### The Problem

MetaScript has **mutable strings** (TypeScript superset — `s[i] = ch`, `s.add(x)` work on `let` bindings). JavaScript's native `String` is immutable. If the JS backend used native JS strings, mutation would be impossible.

### Standard Solution

Modern systems-to-JS compilers write their string/sequence runtime in the source language itself. This compiles to:
- **C**: A struct with a pointer to a payload buffer
- **JS**: `Array<number>` (char code array) — mutable, supports `s[i] = ch`

This approach explicitly does NOT use native JS strings for `string`. `"Hello"` becomes `[72,101,108,108,111]` in JS output. Native JS strings are only used for FFI types (`cstring`).

### Our Solution (Same Pattern)

String/array runtime written in MetaScript (.ms), compiled to both backends:

| Backend | String Representation | Array Representation |
|---------|----------------------|---------------------|
| **C** | `msString { len, p }` — growable COW buffer | `msNumberArray { len, p }` — typed payload |
| **JS** | `Array<number>` (char codes) — mutable | `Array` — native JS array |
| **Raiser** | VM-managed string object | VM-managed array object |

**Benefits:**
1. **One source, all backends** — `ms_string_includes()` written once, works everywhere
2. **Mutable semantics everywhere** — `s[i] = ch` works in C and JS
3. **Single language** — contributors only need MetaScript, not MetaScript + C + JS
4. **Testable** — runtime functions can use `std/testing` like any other .ms code

---

## Operation Dispatch: Codegen vs Stdlib

~10% of string/array operations are handled in codegen (compiler magic). ~90% are normal stdlib functions in `std/core.ms`. This matches standard optimized compiler architectures.

### Codegen-handled (magic) — `expressions.ms`

These use AST-level type inspection (`nodeType`) to emit specialized code per backend. Equivalent to "magic" procedures in reference compilers.

**String primitives:**

| Operation | MetaScript | C Emission | Internal Magic |
|-----------|-----------|-----------|-----------|
| Length | `s.length` | `s.len` | `mLengthStr` |
| Equality | `s == t` / `s === t` | `ms_string_equals(s, t)` | `mEqStr` |
| Inequality | `s != t` / `s !== t` | `(!ms_string_equals(s, t))` | (mEqStr negated) |
| Less than | `s < t` | `(ms_string_compare(s, t) < 0)` | `mLtStr` |
| Less/equal | `s <= t` | `(ms_string_compare(s, t) <= 0)` | `mLeStr` |
| Concat | `s + t` | `ms_string_concat(s, t)` | `mConStrStr` |
| Index read | `s[i]` | `ms_string_char_at(s, i)` | subscript magic |
| Index write | `s[i] = ch` | `(ms_prepare_str_mutation(&s), ms_string_set_char(&s, i, ch))` | subscript + mutation guard |

**Array primitives:**

| Operation | MetaScript | C Emission | Internal Magic |
|-----------|-----------|-----------|-----------|
| Length | `arr.length` | `arr.len` | `mLengthSeq` |
| Index read | `arr[i]` | `arr.p->data[i]` | `mArrGet` |

**Codegen optimizations:**

| Operation | MetaScript | C Emission | Internal Magic |
|-----------|-----------|-----------|-----------|
| Concat chain | `s + t + u` | `ms_string_concat_many(3, s, t, u)` | `mConStrStr` (chain walk) |
| Empty string fast path | `s == ""` | `(s.len == 0)` | `mEqStr` (literal check) |
| Bounds check | `arr[i]` | `({ if(i>=len) ms_raise_index_error(...); arr.p->data[i]; })` | subscript magic |
| Array index write | `arr[i] = v` | `arr.p->data[i] = v` | `mArrPut` |

### Why these are in codegen (not `std/core.ms`)

MetaScript has operator/subscript overloading. In theory, all operations could be `@runtime` declarations. However, codegen handling is required for AST-level optimizations that can't be expressed as function calls:

1. **Concat chain fusion**: `s + t + u + v` — codegen walks the AST, collects all segments, emits ONE allocation + N appends. A normal function `concat(a, b)` would allocate N-1 intermediate strings.

2. **Compile-time literal folding**: Codegen sees `"hello"` in the AST and knows its length is 5 at compile time. Pre-allocates exact size. A normal function receives a runtime value.

3. **Empty string fast path**: `s == ""` → `(s.len == 0)` — no function call. Codegen inspects the literal AST node.

4. **Aliasing safety**: `s = "x" + s + "y"` — codegen allocates new buffer first, reads old `s`, then assigns. Nested function calls risk use-after-free.

5. **Direct field access**: `s.len` as a struct field read is zero-cost. Even `static inline` functions have call-site overhead the optimizer may not eliminate in debug builds.

### Stdlib-handled — `std/core.ms` via `@runtime` pipeline

These are normal extension methods: `collectPass` → `extensionMethodLower` → `builtinLower` → plain function call. Equivalent to standard library procedures in reference implementations. **No codegen awareness needed.**

**String methods (34 total):**

| Category | Methods | Equivalent |
|----------|---------|----------------|
| Search | `indexOf`, `lastIndexOf`, `includes`, `startsWith`, `endsWith` | `find`, `rfind`, `contains`, `startsWith`, `endsWith` |
| Extract | `charAt`, `charCodeAt`, `slice`, `substring`, `at` | `[]`, `ord`, `substr` |
| Split/Join | `split` | `split` |
| Transform | `toLowerCase`, `toUpperCase`, `trim`, `trimStart`, `trimEnd` | `toLowerAscii`, `toUpperAscii`, `strip` |
| Replace | `replace`, `replaceAll` | `replace` |
| Build | `concat`, `repeat`, `padStart`, `padEnd` | `&`, `repeat`, `align`, `alignLeft` |
| Mutate | `add`, `addChar`, `strInsert`, `strRemove`, `setLen` | `add`, `add(char)`, `insert`, `delete`, `setLen` |
| Query | `capacity`, `cmpIgnoreCase`, `strReverse`, `strCount`, `isBlank` | `capacity`, `cmpIgnoreCase`, manual, `count` |
| Edit | `removePrefix`, `removeSuffix` | `removePrefix`, `removeSuffix` |

**String free functions (6):** `parseInt`, `parseFloat`, `intToString`, `toHex`, `newString`, `newStringOfCap`

**Array methods (23 total):**

| Category | Methods | Equivalent |
|----------|---------|----------------|
| Add/Remove | `push`, `pop`, `shift`, `unshift` | `add`, `pop`, manual, manual |
| Search | `arrIndexOf`, `arrIncludes` | `find`, `contains` |
| Extract | `arrSlice`, `arrAt` | manual slice, `[]` with bounds |
| Transform | `arrReverse`, `sort`, `fill` | `reversed`, `sort`, manual |
| Build | `arrConcat`, `splice`, `join` | `concat`, manual, `join` |
| Mutate | `arrInsert`, `removeAt`, `del`, `arrSetLen`, `shrink`, `grow`, `clear` | `insert`, `delete`, `del`, `setLen`, `shrink`, `grow` |
| Query | `arrCapacity`, `arrCount` | `capacity`, `count` |

**Array free functions (2):** `newArray`, `newArrayOfCap`

---

## Current Status

| Component | Status |
|-----------|--------|
| Codegen primitives (16 operations) | **DONE** — `src/codegen/c/expressions.ms` |
| Concat chain fusion | **DONE** — `ms_string_concat_many()` |
| Bounds checking | **DONE** — GCC statement expression with `ms_raise_index_error` |
| Empty string fast path | **DONE** — `s.len == 0` |
| Array index write | **DONE** — `arr.p->data[i] = v` |
| `std/core.ms` declarations (65 methods+functions) | **DONE** — all `@runtime` annotated |
| C runtime implementations | **DONE** — `runtime/core/string.h`, `runtime/core/array.h` |
| Compiler pipeline (collect → UFCS → builtinLower) | **DONE** |
| ORC foundation (pure C) | **DONE** — `runtime/orc.h` |
| Runtime rewrite to .ms | NOT STARTED — currently pure C headers |
| JS backend string runtime | NOT STARTED — currently uses native JS strings (no mutation support) |
| Fixed-size arrays (`T[N]`) | NOT STARTED — type system + stack allocation |
| Span/view type (`Span<T>`) | NOT STARTED — non-owning view unifying `T[]` and `T[N]` |
| COW for string literals | **DONE** — `ms_prepare_str_mutation(&s)` before `ms_string_set_char` |
| HOF inline expansion (map, filter, reduce, find, every, some) | NOT DONE |

---

## File Layout (Target)

```
runtime/
  orc.h              -- Pure C: refcount, alloc, dealloc, struct layouts
  base.h             -- Pure C: msString/msArray struct defs, basic macros
  runtime.h           -- C: master include, links orc.h + base.h
  io.c               -- C: ms_println (platform-specific I/O)

std/
  core.ms            -- Method declarations (@runtime, extension methods)
  runtime/
    string.ms        -- String method implementations (compiles to C + JS)
    array.ms         -- Array method implementations (compiles to C + JS)
```

The `std/runtime/*.ms` files would use `extern` for C-only primitives (memcpy, realloc, strstr) and pure MetaScript for the logic. The compiler would compile these alongside user code for each backend.

---

## Mutable String Design (Cross-Backend)

MetaScript strings are mutable as a **TypeScript superset**. All TS string code works unchanged — mutation is purely additive.

```ms
// TypeScript-compatible (unchanged behavior)
const s = "hello";            // const → no mutation, no reassignment (same as TS)
let t = s.slice(1);           // returns new string (same as TS)
let u = s + " world";         // concat returns new string (same as TS)

// MetaScript extension (new capability)
let buf = "hello";
buf[0] = "H";                 // char assignment — TS rejects this, MS allows it
buf.add(" world");            // in-place append
// buf is now "Hello world"
```

**Key rules:**
- `const` strings: immutable — `const s = "x"; s[0] = "y"` is a compile error (same as TS)
- `let` strings: reassignable (same as TS) AND mutable (MS extension)
- `.slice()`, `.replace()`, `+` concat: return new strings (same as TS)
- `s[i] = ch`, `.add()`: new mutation ops, no existing TS code uses them

**Per-backend representation:**
- **C**: `msString { len, p }` — growable COW buffer. `s[i] = ch` mutates in-place (COW copy if shared).
- **JS**: `Array<number>` (char codes) — mutable. `"Hello"` → `[72,101,108,108,111]`. Same as the standard reference approach.
- **Raiser**: VM-managed string object with mutation support.

**Encoding**: UTF-8 in C, char codes in JS. Identical behavior for ASCII (0-127). Non-ASCII diverges — accept pragmatically. Future `Rune` iterator for explicit Unicode work.

---

## Three-Tier Array Type System

MetaScript is a systems programming language with TypeScript syntax. Similar to proven models like the `array[N,T]` / `seq[T]` / `openArray[T]` split, MetaScript needs three array tiers for performance-critical code — but expressed as TypeScript-compatible syntax.

### The Problem

Systems programming demands control over allocation, often requiring three distinct sequence types:

| Tier | Allocation | Size | Growable |
|----------|-----------|------|----------|
| Fixed-size | Stack | Fixed at compile time | No |
| Dynamic | Heap | Dynamic | Yes |
| View/Span | None (view) | Borrowed pointer + length | N/A |

Without all three, you either waste heap allocations on known-size data, or duplicate every function for arrays vs sequences. A unified view type solves this by allowing a single function to work with both fixed and dynamic arrays.

### MetaScript Mapping

| Concept | MetaScript | C Backend | JS Backend |
|---------|-----------|-----------|------------|
| Fixed-size | `T[N]` | `T arr[N]` (stack) | `Array(N)` (pre-sized) |
| Dynamic | `T[]` | `msArray { len, p }` (heap) | `Array` (native) |
| View/Span | `Span<T>` | `{ T* data, NI len }` (view) | `{ data, offset, len }` (view) |

### Syntax (TypeScript Superset)

```ms
// Dynamic array — existing TypeScript syntax, unchanged
const items: number[] = [1, 2, 3];    // heap-allocated, growable
items.push(4);                         // works

// Fixed-size array — new syntax, no TS conflict (TS doesn't have T[N])
const matrix: number[4] = [1, 0, 0, 1];  // stack-allocated, fixed size
// matrix.push(5);                        // compile error: fixed size

// Span — looks like a generic type, TS-compatible surface syntax
function sum(data: Span<number>): number {
    let total = 0;
    for (const x of data) total += x;
    return total;
}

// Implicit coercion at call site — both work
sum(items);                // number[]  → Span<number>
sum(matrix);               // number[4] → Span<number>
sum(items.span(1, 3));     // zero-copy slice view
```

### Why Each Tier Exists

**`T[N]` (fixed-size array)** — Stack allocation, zero heap overhead. Essential for:
- Embedded/real-time systems (no allocator)
- Small fixed buffers (4x4 matrix, RGB color, SIMD lanes)
- Struct fields with known size (avoids pointer indirection)

**`T[]` (dynamic array)** — Heap-allocated, growable. The default for general programming:
- All existing TypeScript array code works unchanged
- `push`, `pop`, `splice`, `map`, `filter` — full API
- Reference-counted (ORC) in C backend, GC in JS backend

**`Span<T>` (non-owning view)** — Pointer + length, zero allocation. Enables:
- Single function signature accepting both `T[N]` and `T[]`
- Zero-copy slicing: `arr.span(2, 5)` borrows, no allocation
- Same pattern as Rust's `&[T]`, Go's slice, C++20's `std::span`

### Implicit Coercion Rules

The compiler inserts conversions at call sites when a function expects `Span<T>`:

```
// T[N] → Span<T>:  { data: &arr[0], len: N }  (N is compile-time constant)
// T[]  → Span<T>:  { data: arr.p->data, len: arr.len }
// Span<T>.span(start, end) → Span<T>:  { data: data+start, len: end-start }
```

### Restrictions

- `Span<T>` **cannot be returned** from functions — dangling pointer risk (same as the reference model)
- `Span<T>` **cannot be stored** in interfaces/classes — lifetime not tracked
- `T[N]` size must be a **compile-time constant** (literal or const generic)
- `T[N]` **cannot be resized** — no `push`, `pop`, `splice`

---

## Pipeline Parity TODO

Items tracked in `docs/FEATURE-GAP.md` that must be completed for full pipeline parity. Return here when ready.

### ~~Implementable NOW — ALL DONE~~

| # | Gap | Phase | Status |
|---|-----|-------|--------|
| ~~1~~ | ~~Enum toString generation~~ | ~~Codegen~~ | ~~DONE~~ |
| ~~2~~ | ~~String case hash dispatch (>8 arms)~~ | ~~Transform~~ | ~~DONE~~ |
| ~~3~~ | ~~Effect system (`@pure`, `@raises`)~~ | ~~Checker~~ | ~~DONE~~ |
| ~~4~~ | ~~Enhanced null safety (guard clauses, `&&` narrowing)~~ | ~~Checker~~ | ~~DONE~~ |
| ~~5~~ | ~~CFG-based data flow analysis~~ | ~~Analyzer~~ | ~~DONE~~ |
| ~~6~~ | ~~Sink parameter inference~~ | ~~Analyzer~~ | ~~DONE~~ |
| ~~7~~ | ~~NRVO (named return value optimization)~~ | ~~Codegen~~ | ~~DONE~~ |
| ~~8~~ | ~~Goto-based exceptions~~ | ~~Codegen~~ | ~~DONE~~ |

### BLOCKED (needs prerequisite work)

| Gap | Blocker |
|-----|---------|
| Borrow/cursor inference | Needs CFG (#5) + Span\<T\> type |

### DEFERRED (needs new language features)

| Gap | Blocker |
|-----|---------|
| Concepts / type classes | Type system design |
| Multi-methods + VTables | Language feature |
| Template/macro system | VM integration |
| Converter procs | `converter` keyword semantics |
| Proc inlining | `@inline` implementation |
| Spawn / parallel | Threading model |
| Isolation check | Threading model |
| Custom numeric literals | Syntax extension |
| Unicode operators | Syntax extension |
| RTTI V2 | Runtime design |

See `docs/FEATURE-GAP.md` for full details, source references, and line estimates.
