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
- `msString` struct layout (`{ len: int, p: ptr NimStrPayload }`)
- `msArray` struct layout (`{ len: int, p: ptr Payload }`)
- Memory allocation (`alloc`, `dealloc`, `realloc`)
- COW (copy-on-write) for string literals via `strlitFlag`

Location: `runtime/orc.h` (or equivalent C headers).

---

## Why String/Array Runtime Is MetaScript

This is the key architectural insight, validated by Nim's design.

### The Problem

MetaScript has **mutable strings** (TypeScript superset — `s[i] = ch`, `s.add(x)` work on `let` bindings). JavaScript's native `String` is immutable. If the JS backend used native JS strings, mutation would be impossible.

### Nim's Solution

Nim writes its string/seq runtime in Nim (`strs_v2.nim`, `seqs_v2.nim`). This compiles to:
- **C**: `NimStringV2` struct with pointer to payload buffer
- **JS**: `Array<number>` (char code array) — mutable, supports `s[i] = ch`

Nim explicitly does NOT use native JS strings for `string`. `"Hello"` becomes `[72,101,108,108,111]` in JS output. Native JS strings are only used for `cstring` (FFI type).

### Our Solution (Same Pattern)

String/array runtime written in MetaScript (.ms), compiled by `msc` to both backends:

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

**What the .ms runtime uses `extern` for (C backend only):**
- `memcpy`, `memmove`, `memset` — raw memory operations
- `strstr`, `strchr` — C string search primitives
- `realloc` — memory growth
- `qsort` — system sort

These `extern` declarations are conditionally included (C backend only). The JS backend doesn't need them — it uses native JS operations.

---

## Operation Dispatch: Codegen vs Stdlib

~10% of string/array operations are handled in codegen (compiler magic). ~90% are normal stdlib functions in `std/core.ms`. This matches Nim's architecture exactly.

### Codegen-handled (magic) — `expressions.ms`

These use AST-level type inspection (`nodeType`) to emit specialized code per backend. Equivalent to Nim's `{.magic.}` procs in `ccgexprs.nim`.

**String primitives:**

| Operation | MetaScript | C Emission | Nim Magic |
|-----------|-----------|-----------|-----------|
| Length | `s.length` | `s.len` | `mLengthStr` |
| Equality | `s == t` / `s === t` | `ms_string_equals(s, t)` | `mEqStr` |
| Inequality | `s != t` / `s !== t` | `(!ms_string_equals(s, t))` | (mEqStr negated) |
| Less than | `s < t` | `(ms_string_compare(s, t) < 0)` | `mLtStr` |
| Less/equal | `s <= t` | `(ms_string_compare(s, t) <= 0)` | `mLeStr` |
| Greater than | `s > t` | `(ms_string_compare(s, t) > 0)` | (mLtStr flipped) |
| Greater/equal | `s >= t` | `(ms_string_compare(s, t) >= 0)` | (mLeStr flipped) |
| Concat | `s + t` | `ms_string_concat(s, t)` | `mConStrStr` |
| Index read | `s[i]` | `ms_string_char_at(s, i)` | subscript magic |
| Index write | `s[i] = ch` | `ms_string_set_char(&s, i, ch)` | subscript + `nimPrepareStrMutationV2` |

**Array primitives:**

| Operation | MetaScript | C Emission | Nim Magic |
|-----------|-----------|-----------|-----------|
| Length | `arr.length` | `arr.len` | `mLengthSeq` |
| Index read | `arr[i]` | `arr.p->data[i]` | `mArrGet` |

**Not yet implemented (planned for codegen):**

| Operation | MetaScript | Planned C Emission | Nim Magic | Gap |
|-----------|-----------|-------------------|-----------|-----|
| Concat chain | `s + t + u` | single `rawNewString` + N appends | `mConStrStr` (chain walk) | #8 |
| Empty string fast path | `s == ""` | `(s.len == 0)` | `mEqStr` (literal check) | — |
| Bounds check | `arr[i]` | `if (i >= len) ms_raise_index(i, len)` | subscript magic | #6 |
| Array index write | `arr[i] = v` | `arr.p->data[i] = v` | `mArrPut` | — |

### Why these are in codegen (not `std/core.ms`)

MetaScript has operator/subscript overloading (reference compiler supports both). In theory, all operations could be `@runtime` declarations. However, codegen handling is required for AST-level optimizations that can't be expressed as function calls:

1. **Concat chain fusion**: `s + t + u + v` — codegen walks the AST, collects all segments, emits ONE allocation + N appends. A normal function `concat(a, b)` would allocate N-1 intermediate strings.

2. **Compile-time literal folding**: Codegen sees `"hello"` in the AST and knows its length is 5 at compile time. Pre-allocates exact size. A normal function receives a runtime value.

3. **Empty string fast path**: `s == ""` → `(s.len == 0)` — no function call. Codegen inspects the literal AST node.

4. **Aliasing safety**: `s = "x" + s + "y"` — codegen allocates new buffer first, reads old `s`, then assigns. Nested function calls risk use-after-free.

5. **Direct field access**: `s.len` as a struct field read is zero-cost. Even `static inline` functions have call-site overhead the optimizer may not eliminate in debug builds.

### Stdlib-handled — `std/core.ms` via `@runtime` pipeline

These are normal extension methods: `collectPass` → `extensionMethodLower` → `builtinLower` → plain function call. Equivalent to Nim's `strutils.nim` / `sequtils.nim` normal procs. **No codegen awareness needed.**

**String methods (34 total):**

| Category | Methods | Nim Equivalent |
|----------|---------|----------------|
| Search | `indexOf`, `lastIndexOf`, `includes`, `startsWith`, `endsWith` | `find`, `rfind`, `contains`, `startsWith`, `endsWith` (strutils) |
| Extract | `charAt`, `charCodeAt`, `slice`, `substring`, `at` | `[]`, `ord`, `substr` (system) |
| Split/Join | `split` | `split` (strutils) |
| Transform | `toLowerCase`, `toUpperCase`, `trim`, `trimStart`, `trimEnd` | `toLowerAscii`, `toUpperAscii`, `strip` (strutils) |
| Replace | `replace`, `replaceAll` | `replace` (strutils) |
| Build | `concat`, `repeat`, `padStart`, `padEnd` | `&`, `repeat`, `align`, `alignLeft` (strutils) |
| Mutate | `add`, `addChar`, `strInsert`, `strRemove`, `setLen` | `add`, `add(char)`, `insert`, `delete`, `setLen` (system) |
| Query | `capacity`, `cmpIgnoreCase`, `strReverse`, `strCount`, `isBlank` | `capacity` (system), `cmpIgnoreCase`, manual, `count` (strutils) |
| Edit | `removePrefix`, `removeSuffix` | `removePrefix`, `removeSuffix` (strutils) |

**String free functions (6):** `parseInt`, `parseFloat`, `intToString`, `toHex`, `newString`, `newStringOfCap`

**Array methods (23 total):**

| Category | Methods | Nim Equivalent |
|----------|---------|----------------|
| Add/Remove | `push`, `pop`, `shift`, `unshift` | `add` (system), `pop`, manual, manual |
| Search | `arrIndexOf`, `arrIncludes` | `find`, `contains` (system) |
| Extract | `arrSlice`, `arrAt` | manual slice, `[]` with bounds |
| Transform | `arrReverse`, `sort`, `fill` | `reversed` (sequtils), `sort` (algorithm), manual |
| Build | `arrConcat`, `splice`, `join` | `concat` (sequtils), manual, `join` (strutils) |
| Mutate | `arrInsert`, `removeAt`, `del`, `arrSetLen`, `shrink`, `grow`, `clear` | `insert`, `delete`, `del`, `setLen`, `shrink`, `grow` (system) |
| Query | `arrCapacity`, `arrCount` | `capacity` (system), `count` (sequtils) |

**Array free functions (2):** `newArray`, `newArrayOfCap`

---

## Current Status

| Component | Status |
|-----------|--------|
| Codegen primitives (12 operations) | **DONE** — `src/codegen/c/expressions.ms` |
| `std/core.ms` declarations (65 methods+functions) | **DONE** — all `@runtime` annotated |
| C runtime implementations | **DONE** — in reference compiler `src/runtime/ms_string.h`, `ms_array.h` |
| Compiler pipeline (collect → UFCS → builtinLower) | **DONE** |
| ORC foundation (pure C) | **DONE** — reference compiler `src/runtime/orc.h` |
| Runtime rewrite to .ms | NOT STARTED — currently pure C headers |
| JS backend string runtime | NOT STARTED — currently uses native JS strings (no mutation support) |
| Concat chain fusion | NOT DONE (Gap #8) |
| Bounds checking | NOT DONE (Gap #6) |
| Empty string fast path | NOT DONE |
| COW for string literals | NOT DONE |
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
- **JS**: `Array<number>` (char codes) — mutable. `"Hello"` → `[72,101,108,108,111]`. Same as Nim's approach.
- **Raiser**: VM-managed string object with mutation support.

**Encoding**: UTF-8 in C, char codes in JS. Identical behavior for ASCII (0-127). Non-ASCII diverges — accept pragmatically. Future `Rune` iterator for explicit Unicode work.
