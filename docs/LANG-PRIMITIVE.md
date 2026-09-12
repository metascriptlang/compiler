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
| `BitSet<E>` | Compound | **DONE** (2026-09-07, width bands 2026-09-12) | Type kind of its own whose repr follows the member count: `uint8` ≤ 8, `uint16` ≤ 16, `uint32` ≤ 32, `uint64` ≤ 64, `uint8[⌈n/8⌉]` ≤ 65536; bit = member ordinal | TS has no ordinal set; the reference has `set[T]`. Design record below |

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

---

## `BitSet<E>` — typed ordinal set (design record, 2026-09-07)

**Status: implemented 2026-09-07.** This section records *why* the design is what it
is, so a later reader of `LANG.md` does not have to re-derive it. Every number below was
measured on 2026-09-07 unless marked otherwise.

### What shipped

```ms
enum Flag { Mutable, Used, Consumed, Cursor }   // ordinal values, the TS default

const base: BitSet<Flag> = Flag.Used | Flag.Cursor;   // inferred BitSet<Flag>
const g = base.incl(Flag.Mutable).excl(Flag.Used);
if (g.has(Flag.Cursor)) { ... }
```

Pieces, each verified by running:

| Piece | Where |
| :--- | :--- |
| Generic distinct declarations (`type X<E> = distinct ...`) | `parser/statements/declaration.ms` — reuses the alias generic path |
| C ABI erasure for a generic distinct instance | `codegen/c/types.ms` `getTypeDesc` — same rule the non-generic distinct already had |
| `E.A \| E.B` infers `BitSet<E>` | `checker/fit.ms` `inferBitSetOp`, called from `inferBinaryOp` |
| `BitSet<E>` is a type kind of its own (`TypeKind.Set`, element in `typeReturn`), resolved beside `Span`/`Arc`/`Locked` | `checker/types.ms` `createBitSet` / `setRepr`, `resolvePass.ms` `resolveAnnotation` — the name-keyed registry it replaced (2026-09-11) is gone |
| Mixed-enum operands rejected | `checker/fit.ms` — `reportBitSetMismatch` when one side is a `BitSet`, `reportOrdinalEnumMix` when both are bare ordinal-enum members |
| Ordinal → bit lowering | `transform/lowering/bitSetLower.ms` |
| `has`, `incl`, `excl`, `isEmpty` | `std/core/struct.ms` and `struct.jms` (prelude): `@builtin`-tagged `extern` declarations with no body, lowered by tag; `BitSet<E>` itself is resolved by the checker, there is no alias in the prelude (both since 2026-09-12) |
| End-to-end test | `src/test/corpus/programs/757-bitSetOrdinalSet.ms` |

**Only ordinal enums participate.** An enum with hand-assigned values (`A = 1, B = 2,
C = 4`) is already a flag encoding, so `A | B` there keeps its numeric meaning —
applying BitSet would encode the bits twice. `isOrdinalEnum` gates the inference. This
was not a nicety at ship time: two sites in `checker/flow.ms` built an `int32` mask from a
then hand-numbered `FlowFlags` and would otherwise have broken. (That enum has since been
ordinalized as `FlowFlag` and `FlowNode.flags` is a `BitSet<FlowFlag>`, 2026-09-11.)

Measured behaviour:

```
BitSet<Flag> -> BitSet<Kind>   rejected: "got BitSet<Flag>, expected BitSet<Kind>"
BitSet<Flag> -> uint32         rejected (distinct is nominal)
Flag.Used | Kind.Call          rejected (since dbb74612, re-measured 2026-09-11):
                               "bitwise operator '|' on 'Flag' and 'Kind' mixes
                               different enum sets"
Flag.Used | Flag.Cursor        == 10   (bits 1 and 3, not the ordinals 1|3 == 3)
compiler suite                 3652 / 3652
```

A distinct alias lowers to the bare underlying C type (`uint32_t`), so the set costs
one machine word and the operators are the machine's own. `.has()`, `.incl()` and `.excl()`
are lowered by `bitSetLower` before codegen, not called — re-measured 2026-09-11 under
`--danger` on `enum Flag { Mutable, Used, Consumed, Cursor }`, zero `BitSet_*` calls remain:

```c
s = ((1U << Flag_Used) | (1U << Flag_Cursor));                 // Flag.Used | Flag.Cursor
g = ((s | (1U << Flag_Mutable)) & (~(1U << Flag_Used)));       // .incl(Mutable).excl(Used)
((g & (1U << Flag_Cursor)) != 0U)                              // .has(Cursor)
```

### The problem: enum identity dies at the first `|`

Measured via the return path (the `const`-initializer path is fail-open and reports
nothing — validated with a known-red control first):

| Expression | Inferred type |
| :--- | :--- |
| `K.A` | `K` |
| `K.A \| K.B` | `int32` |
| assign `int32` into a `K` slot | **accepted** |
| assign `K` into an `int32` slot | **rejected** |

TypeScript behaves the same way, only wider: bitwise operators always produce `number`,
and TS additionally accepts `number` into a numeric-enum slot. So in both languages a
combined flag value has already lost its enum identity by the time anything reads it.

That is the whole bug class. Before the flag families became sets this compiled silently,
across two unrelated enums; measured 2026-09-12 on the migrated checker it is rejected
(`bitwise operator '&' on 'BitSet<A>' and 'B' mixes different enum sets`):

```ms
node.flags & TypeFlag.HasAsgn      // node.flags is NodeFlag-shaped
```

Scale in this repo: **224** raw bit operations on `flags` fields, **154** `hasFlag`/`setFlag`
calls, **391** `.kind == X ||` chains that a set membership test would collapse. The
reference reaches for the same construct **1131** times (`x in {...}`) and declares **7**
set aliases over its core enums.

`Symbol.symFlags` is also **out of room**: it is an `int32` whose highest flag is `2^29`,
leaving exactly one bit. Hand-assigned powers of two are what exhausted it.

### Why not the C# `[Flags]` model

C# lets an enum be closed under `|` — `F.A | F.B` has type `F`, no second type needed.
That is strictly smaller than what is described here, and it was rejected for one reason:
**it requires the enum's values to be powers of two.** `NodeKind.Call` is 5 and
`NodeKind.New` is 6, so `5 | 6 == 7` is meaningless. The C# model therefore covers the
three flag enums and none of the 391 ordinary-enum sites.

### Decision

A distinct type `BitSet<E>` where **the bit position is the enum member's ordinal**, not
its value. This is the reference's model (`set[T]`) and Java's (`EnumSet`), and one
mechanism covers both populations:

```ms
export enum SymbolFlag { Mutable, Used, Consumed, Cursor }   // 0,1,2,3 — the TS default
symFlags: BitSet<SymbolFlag>;

sym.symFlags = sym.symFlags | SymbolFlag.Cursor;   // identical text to today, now typed
if (sym.symFlags.has(SymbolFlag.Cursor)) { ... }

const callKinds = NodeKind.Call | NodeKind.New;    // BitSet<NodeKind> — C# cannot express this
if (callKinds.has(node.kind)) { ... }
```

Inference rule, no contextual typing required:

> If both operands of `|` are members of the **same** enum, the result is `BitSet<E>`.
> Otherwise the existing numeric rule is unchanged.

Consequence: enum members go back to plain ordinals, so no one hand-writes `= 536870912`
again, and the `symFlags` exhaustion disappears without widening anything. Enum values
change, so any format that serializes an enum numerically (prelude pack, caches) needs a
version bump.

### Naming

`BitSet` — the standard name (`java.util.BitSet`, C++ `std::bitset`). `Set<T>` was already
taken by the ordered hash container in `std/core/struct.ms:713`, which is a mutable
reference type with `.has()` / `.add()` / `.delete()`.

Because `BitSet` is a **value** type, it deliberately gets **no mutating methods**. The
whole surface is `.has()` to ask, `|` to add, `& ~` to remove. A reader who sees no
`.add()` will not expect in-place mutation.

`.has()` and not `.contains()`: every other language in the survey below uses `contains`,
but JS/TS — and this repo's own `Set<T>` — use `has`.

### What it costs in TypeScript terms

Not purely additive. Accounting, honestly:

| | Effect |
| :--- | :--- |
| New syntax | **none** — `A \| B` is what is already written |
| `.has()`, `BitSet<E>` | pure addition, TS has no such names |
| Ordinal enum values | moves **toward** TS — `enum K { A, B, C }` is 0,1,2 in TS; the hand-assigned powers of two were the deviation |
| `E.A \| E.B` infers `BitSet<E>` | **diverges** from TS's `number` — in the stricter direction; TS accepts a combined value into a single-member slot, which is unsound and known to be |
| `(flags & Flag.X) != 0` | **breaks.** `&` yields a `BitSet`, so the comparison loses meaning and must become `.has()`. This is the classic TS flag idiom and there are 224 sites |

The last row is the real price and it is not avoidable: permitting `!= 0` means falling
back to `int`, which discards the type safety that motivates the feature.

### Width, and why it is also the JS fast path

The width bands are `≤8 → 1 byte`, `≤16 → 2`, `≤32 → 4`, `≤64 → 8`, larger → byte array;
the band picks a C integer type and falls to an array above 8 bytes.
`checker/types.ms` `bitSetRepr` holds the bands, and `setRepr` reads it, so the representation is
decided by the element enum's member count at every point that asks. Measured 2026-09-12
(`src/test/c/bitSetWidth.ms` pins the struct field types; corpus `761-bitSetNarrow.ms` runs
the 1- and 2-byte bands on both backends):

| members | repr | C field | membership test emitted |
| :--- | :--- | :--- | :--- |
| ≤ 8 | `uint8` | `uint8_t a;` | `(s & (1 << m)) != 0` |
| ≤ 16 | `uint16` | `uint16_t b;` | `(s & (1 << m)) != 0` |
| ≤ 32 | `uint32` | `uint32_t c;` | `(s & (1U << m)) != 0` |
| ≤ 64 | `uint64` | `uint64_t d;` | `(s & (1ULL << m)) != 0` |
| ≤ 65536 | `SizedArray<uint8, ⌈n/8⌉>` | `uint8_t data[13];` (100 members) | `(s[m >> 3] & (1 << (m & 7))) != 0` |
| above | rejected with a loud error | — | — |

The cap is 2^16 members. Within it a 5-member enum costs 1 byte, and
the array band is a byte array, not a word array. Until 2026-09-12 the floor was a 32-bit word
and the array band used 32-bit words; that narrowing was removed.

The 33–64 band stays a single 64-bit word rather than a two-word array, and that was measured,
not assumed: on the JS backend a two-word array ran **~20% slower** than the BigInt path
(0.253 s vs 0.209 s over 2M operations), because `int64` there goes through BigInt
(`lowerBigIntJS`, wired at `src/transform/index.ms:180`) while an array pays element-wise work
on every operation. Below 33 members nothing changes: `int32` stays a plain Number at zero cost,
and the compiler's own sets — `NodeKind` 30, `TypeKind` 21, `SymbolKind` 14, `NodeFlag` 17,
`TypeFlag` 14, `SymbolFlag` 30 — all land at or below it (`Node.flags`, `Type.typeFlags` and
`FlowNode.flags` are 2-byte fields since 2026-09-12; `Symbol.symFlags` stays 4). The array band is exercised end-to-end by
`src/test/corpus/programs/760-bitSetArray.ms` (100 members) and the 64-bit band by
`759-bitSetWide.ms` (40 members), both C↔JS parity-green.

### Not implemented: the reference's set syntax (decided 2026-09-12)

The reference gives `set[T]` a surface of its own: the literal `{A, B}`, the range `{A..D}`,
the empty literal `{}` typed from context, `x in s` / `x notin s`, the algebra `+` `-` `*` for
union, difference and intersection, `<=` for subset, and `card(s)`. None of that is
implemented here, and the decision is **not to**, for these reasons:

- **Its dominant use is already covered without new syntax.** In the reference the literal
  appears 1131 times, almost always as an in-place membership test (`if kind in {nkCall,
  nkCommand}`), not as a flag constructor. MetaScript expresses the same two ways today:
  `match` with `|` alternatives for dispatch, and `(K.A | K.B).has(x)` for a lone condition.
- **The syntax exists there because `set` is a primitive with a literal, the way arrays have
  `[]`.** No mainstream language the users come from has it: TypeScript and C# write
  `x === A || x === B` or `switch`; Rust writes `matches!(x, A | B)`; only Dart and Swift carry
  a dedicated literal. Adding it means inventing grammar (`{ K.A, K.B }` is free — object
  shorthand at `src/parser/expressions/object.ms:85` only takes bare identifiers — but it
  still has to be taught) for a form the audience does not expect.
- **The range form is a hazard.** `{A..D}` couples a set's meaning to enum **declaration
  order**; inserting a member in the middle silently changes every range that spans it.
- **Convenience that is rarely reached for is not worth a new construct to learn.** The
  set algebra reduces to the bitwise operators the set already has (`|`, `&`, `& ~`), and
  subset / cardinality have no caller in this repo.

Status: **nice to have, revisit only after everything else about `BitSet` is solid**, and only
with evidence from real code that `.has()` and `match` are not enough.

### Cross-language survey

Not measured in this repo — recorded so the reasoning above can be checked.

| Language | Declaration | Combine | Membership | Who assigns bits |
| :--- | :--- | :--- | :--- | :--- |
| TS/JS | `enum F { A = 1, B = 2 }` | `F.A \| F.B` | `(f & F.A) != 0` | author |
| C# | `[Flags] enum F { A = 1 }` | `F.A \| F.B` | `f.HasFlag(F.A)` | author |
| Python | `class F(Flag): A = auto()` | `F.A \| F.B` | `F.A in f` | `auto()` |
| Rust | `bitflags! { ... }` | `F::A \| F::B` | `f.contains(F::A)` | author |
| Swift | `struct F: OptionSet` | `[.a, .b]` | `f.contains(.a)` | author |
| Java | plain `enum` | `EnumSet.of(A, B)` | `s.contains(A)` | library |
| Zig | plain `enum` | `std.EnumSet(E)` | `s.contains(.a)` | library |

Two things converge: `|` is the universal combinator, and the languages that let the
*library or compiler* assign bits (Java, Zig, the reference) are exactly the ones whose
sets work over ordinary enums rather than only over hand-numbered flag enums.

### Not verified

- ~~Whether a generic distinct alias is supported~~ — **answered**: `type X<E> = distinct uint32`
  works; it is what `BitSet<E>` ships as.
- ~~Whether an extension method on a distinct type inlines to bare bit operations in the C
  backend, or leaves a call~~ — **measured 2026-09-10**. Before the range-check fix the
  `has()` body under `--danger` was
  `((msCheckRangeU32((*self), 0, 4294967295LL) >> msCheckRangeU32(member, …)) & msCheckRangeU32(1U, …)) != 0U`
  — three `uint32 → double → int64` round-trips per membership test, plus an `if (msErr) goto`
  after every call. After `rangeCheckInject` follows the reference (no check into an unsigned
  destination) it is `((((*self) >> ((uint32_t)member)) & 1U) != 0U)` — a leaf the C compiler
  inlines. The `|` path never had the problem: `bitSetLower` emits `(1U << a) | (1U << b)`
  directly.
- Whether `in` can be overloaded as an operator (today it is only the `for..in` keyword,
  `src/lexer/token.ms:45`).
- ~~How the prelude pack serializes enum values~~ — **answered**: a set serializes as its
  representation word, so `Node.flags` and `Symbol.symFlags` each stay one unsigned integer
  column, the same shape the old masks had. The format bump came from a separate column for
  the union-variant slot that used to be packed into a flag bit, not from the sets.
- A macro's source-form `flags` takes **one** `NodeFlag` member, not a set expression: the
  macro engine cannot construct a set value, so the bridge compares a single ordinal.
  Re-measured 2026-09-11 on the installed compiler, inside a macro body over a user enum
  `E { A, B, C }`: `const s: BitSet<E> = E.A | E.C; ${s as uint32 as int32}` evaluates to
  **2** (the ordinals OR-ed, not `1<<0 | 1<<2 == 5`) — the set lowering never runs in the
  macro evaluator, so the value is silently wrong; `s.has(E.C)` fails loud instead:
  `helper 'BitSet_has__E_…': Unresolved type 'E' - missing import?`, reported against the
  prelude file. The same over a std enum (`BitSet<NodeFlag>`) fails with
  `cannot evaluate 'NodeFlag' at comptime`. Plain enum members (`E.B` → 1) and std
  generic containers (`E[]`) evaluate correctly in the same position, so the gap is the
  set lowering and the monomorphized set helpers, not enums or generics in general.
