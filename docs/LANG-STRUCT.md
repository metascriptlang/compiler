# MetaScript Struct & Type System Design

## Two-Layer Type System

MetaScript's type system has two layers:

```
TypeScript  ⊂  MetaScript Layer 1  ⊂  MetaScript Layer 2
(reference)    (reference, TS-compat)   (value types, C-native)
```

### Layer 1: TypeScript-Compatible (Reference Types)

All familiar TypeScript constructs work as reference types, with identical semantics across JS and C backends.

```ms
interface IUser { name: string; age: number; }
class Admin implements IUser { ... }
type Extended = IUser & { role: string };

const u: IUser = { name: "Son", age: 38 };   // reference
const a = new Admin();                         // reference
```

- `interface` — data shape + optional method signatures, reference semantics
- `class` — data + methods, reference semantics, can `implements` interfaces
- `type` — type aliases, intersections (`&`), unions (`|`), reference semantics

No behavioral difference across backends for Layer 1 code.

### Layer 2: MetaScript Superset (Value Types)

New constructs designed from ground up for value-based types, optimized for C backend.

```ms
struct Point { x: float64; y: float64; }      // value type, stack-allocated
distinct type UserId = number;                  // nominal value type
```

Value-type features: `struct`, `ref`, `out`, `move`, `defer`.

- **JS backend**: Layer 2 compiles down to regular JS objects (no observable difference)
- **C backend**: Layer 2 emits stack allocation + value copy (no heap, no refcount)

## Keyword Semantics

| Construct | Fields | Methods | Value/Ref | Instantiation |
|-----------|--------|---------|-----------|---------------|
| `interface` | Yes | Yes | Reference | `{ ... }` literal or via class |
| `class` | Yes | Yes | Reference | `new Class()` |
| `type` | Alias | Alias | Depends on target | Depends on target |
| `struct` | Yes | **No** (compiler error) | Value | `{ ... }` literal |

## Interface: Dual Role

Interface serves as both data shape and behavioral contract, always with reference semantics.

### Data Shape (fields only)

```ms
interface IUser {
    name: string;
    age: number;
}

const u: IUser = { name: "Son", age: 38 };
```

### Behavioral Contract (with methods)

```ms
interface IPrintable {
    function toString(): string;
    function debugPrint(): void;
}

class Token implements IPrintable {
    kind: TokenKind;
    value: string;

    function toString(): string {
        return this.value;
    }
    function debugPrint(): void {
        print(this.toString());
    }
}
```

### Both (fields + methods)

```ms
interface ISerializable {
    id: string;
    function serialize(): string;
}
```

## Class: Reference Type with Behavior

```ms
class Admin implements IUser, IPrintable {
    name: string;
    age: number;
    role: string;

    function toString(): string { return this.name; }
    function debugPrint(): void { print(this.toString()); }
    function promote(): void { ... }
}

const a = new Admin();  // heap-allocated, reference semantics
```

- `extends` — single class inheritance
- `implements` — multiple interface satisfaction
- C backend: heap-allocated, refcounted, vtable for interface methods

## Struct: Value Type (Data Only)

Structs are pure data containers. No methods, no vtable, always value semantics.

### Direct Declaration

```ms
struct Point { x: float64; y: float64; }
struct Color { r: uint8; g: uint8; b: uint8; a: uint8; }

const p: Point = { x: 1.0, y: 2.0 };  // stack-allocated, value copy
```

### Extending Data-Only Interfaces

Structs can compose with interfaces via intersection, but **only if the interface has no methods**.

```ms
interface IUser { name: string; age: number; }
interface IPrintable { function toString(): string; }

// OK — IUser is data-only
struct SuperUser = IUser & { more: string; };

// COMPILER ERROR — IPrintable has methods, struct cannot have methods
struct BadUser = IPrintable & { name: string; };
// Error: struct cannot extend interface with methods (IPrintable.toString)
```

### Checker Rule

When resolving `struct = X & Y & ...`, walk each constituent type:
- If any member is a method signature, emit compiler error
- Only field declarations are allowed in struct composition

### Struct Parameter Passing (Auto-Optimized)

Struct params are **TS-compatible by default** — mutation propagates to caller, just like TypeScript objects. The compiler uses `mutatedParams` analysis to auto-select the optimal C ABI per parameter.

| Size | Mutated? | `readonly`? | Strategy | C output |
|------|----------|-------------|----------|----------|
| Small (≤24B) | No | No | Value (registers, cheap copy) | `void f(Vec2 v)` |
| Small (≤24B) | Yes | No | `T*` (mutation propagates) | `void f(Vec2* v)` |
| Small (≤24B) | — | Yes | Value (forced copy) | `void f(Vec2 v)` |
| Big (>24B) | No | No | `const T*` (zero copy) | `void f(const BigData* v)` |
| Big (>24B) | Yes | No | `T*` (mutation propagates) | `void f(BigData* v)` |
| Big (>24B) | — | Yes | `T*` + copy-on-entry | `void f(const BigData* _v) { BigData v = *_v; }` |

**Key design decision**: Unlike the standard reference (immutable params by default), MetaScript allows param mutation like TypeScript. The compiler detects mutation via `mutatedParams` bitfield analysis (checker phase) and picks the optimal path automatically. No developer effort required.

```ms
struct Vec2 { x: float64; y: float64; }
struct BigData { name: string; items: number[100]; }

// Small + no mutation → value (registers)
function length(v: Vec2): float64 {
    return Math.sqrt(v.x * v.x + v.y * v.y);
}

// Small + mutated → T* (mutation propagates to caller)
function reset(v: Vec2): void {
    v.x = 0;  // caller's v.x becomes 0
    v.y = 0;
}

// Big + no mutation → const T* (zero copy, immutable pointer)
function summarize(data: BigData): string {
    return data.name;
}

// Big + mutated → T* (zero copy, mutation propagates)
function rename(data: BigData): void {
    data.name = "updated";  // caller sees change
}

// readonly — explicit copy, caller's value is never affected
function tryParse(readonly data: BigData): boolean {
    data.name = "test";  // mutates local copy only
    return validate(data);
}
```

### Parameter Modifiers

| Modifier | Syntax | Semantics | Use when |
|---|---|---|---|
| *(default)* | `f(v: Struct)` | Auto-optimized: copy or `T*` based on size + mutation | Normal usage — compiler picks best |
| `readonly` | `f(readonly v: Struct)` | Explicit copy (isolation from caller) | Want a local snapshot |
| `ref` | `f(ref v: Struct)` | Explicit mutable borrow | Redundant for structs (default already propagates), useful for primitives |
| `move` | `f(move v: Struct)` | Ownership transfer (caller's value zeroed) | Transferring ownership |
| `out` | `f(out v: Struct)` | Output parameter (callee fills) | Returning via parameter |

## Backend Behavior

### Reference Types (interface, class)

| Backend | Allocation | Passing | Mutation |
|---------|-----------|---------|----------|
| JS | Heap (JS engine) | Reference (always) | Caller sees changes |
| C | Heap + refcount | Pointer | Caller sees changes |

Both backends behave identically — no surprises.

### Value Types (struct)

| Backend | Allocation | Passing | Mutation |
|---------|-----------|---------|----------|
| JS | Heap (JS engine) | Reference (JS semantics) | Caller sees changes |
| C | Stack | Auto: value or `T*` (see table above) | Depends on mutation + size |

- **JS backend**: Structs are regular JS objects — mutation propagates naturally (TS-compatible)
- **C backend**: `mutatedParams` analysis selects optimal ABI per-param. Small unmutated → registers. Everything else → pointer. `readonly` → explicit copy.

## Implementation Roadmap

### Key Insight: Bun Runtime as Proof

The compiler runs correctly on Bun (JS runtime) where everything is reference-based.
This proves all existing code is correct under reference semantics. Making interface
reference-based in the C backend aligns C with the proven-working JS behavior.

### ~~Phase 1: Add `struct` Keyword~~

~~Purely additive — opt-in value types for performance-critical hot paths.~~

**DONE.** `struct` keyword added across 20 files (lexer, AST, parser, checker, codegen, transforms, compiler subsystems). Supports `struct`, `export struct`, `extern struct`, generic structs. Struct uses `TypeFlag.IsStruct` internally so all existing value-type codegen paths work unchanged.

### ~~Phase 2: Interface to Reference Type in C Backend~~

~~Align C backend with working Bun semantics by wrapping interface types in `Ref<Struct>`.~~

**DONE.** Interface types now use `Ref<Struct>` internally (like class). Changes in collectPass (wrap in `createRef`), resolvePass (unwrap Ref before setting fields), destructorLifting (interface gets typeInfo + Ref-aware DRC hooks). All existing codegen paths for `Ref<>` types handle heap allocation, `->` access, pointer params, and RC automatically.

```
Current state:
  struct    →  TypeKind.Struct         (value, stack, copied)
  interface →  Ref<TypeKind.Struct>    (reference, heap, refcounted)
  class     →  Ref<TypeKind.Struct>    (reference, heap, refcounted)
```

### Phase 2.5: Struct Parameter Semantics + Enhancements (partially done)

**`ref` parameter modifier — DONE:**

`ref` keyword added for mutable borrow parameters. Parser, checker, codegen all handle it. `ref` params wrap in `TypeKind.Var` (same as `out`, both `T*` in C).

**Param mutation analysis — DONE:**

`checker/paramMutationAnalysis.ms` runs after ownership inference. Scans every function body for param mutations (assignment, member mutation, index mutation, compound assignment, update expr, HiddenAddr). Stores result as `Symbol.mutatedParams: int32` bitfield (bit i = param i is mutated). Codegen reads this to select optimal ABI.

Mutation patterns detected:
- Direct: `param = expr`, `param += expr`
- Member: `param.field = expr`
- Index: `param[i] = expr`
- Update: `param++`, `param--`
- Passed as mutable ref: `HiddenAddr(param)`

**Auto-optimized param passing — DONE (infrastructure):**

Design: TS-compatible mutable params by default. Compiler auto-selects ABI via `mutatedParams`:
- Small + not mutated → value (registers, reference parity)
- Small + mutated → `T*` (mutation propagates, TS-compatible)
- Big + not mutated → `const T*` (zero copy)
- Big + mutated → `T*` (zero copy, mutation propagates)

Divergence from the standard reference: reference params are immutable by default, so `ccgIntroducedPtr` never needs mutation analysis. We allow mutation (TS-compatible), so `mutatedParams` gates the optimization.

**`readonly` parameter modifier — NOT YET:**

`readonly` keyword for explicit copy isolation. When a developer wants value semantics (local copy, caller unaffected):

```ms
function tryParse(readonly state: ParserState): boolean {
    state.pos = state.pos + 1;  // mutates local copy only
    return validate(state);
}

// COMPILE ERROR — readonly param cannot be mutated
function bad(readonly v: Vec2): void {
    v.x = 1;  // error: cannot mutate readonly parameter 'v'
}
```

Implementation needed:
- Parser: Recognize `readonly` in param list (mirrors `out`/`ref` handling)
- Checker: After `analyzeParamMutations`, cross-check `mutatedParams` bits against readonly-marked params. If `mutatedParams` bit is set for a readonly param → emit error: "cannot mutate readonly parameter 'name'"
- LSP: Error surfaces automatically via checker diagnostics
- Codegen: Small → emit as `T v` (value). Big → emit as `const T* _v` + `T v = *_v` copy-on-entry.

**GcMode auto-detect — DONE:**

`GcMode` enum (Auto/Orc/None) on CheckerContext. `analyzeProgram` in analyzer/index.ms uses match expression:
- `GcMode.None` → skip DRC entirely
- `GcMode.Orc` → always run DRC
- `GcMode.Auto` → scan symbols via `needsRC()`, skip DRC if no RC types found

Pure struct code gets zero DRC overhead automatically, no `--gc:none` flag needed.

**Other struct enhancements (not yet):**

- Intersection syntax: `struct SuperUser = IUser & { more: string; };`
- Method rejection: checker should error if struct body contains method signatures
- Reject `struct = X & Y` if X or Y has methods

### Phase 2.7: Discriminated Unions — DONE

`type X = match (kind: K) { ... }` fully works in C codegen:
- Tag access: `s.kind` → `s._tag` (mapped at MemberExpr codegen)
- Variant field access: `s.radius` → `s.v0.radius` (findVariantByFieldName)
- Construction: `{ kind: Shape.Circle, radius: 5 }` → `(ShapeData){ ._tag = 0, .v0 = { .radius = 5 } }`
- Enum type pre-resolved before union struct emission (avoids nested typedef)
- Checker rewrites `Shape.Circle` → `Shape_Circle` identifier; codegen reverses via underscore→dot conversion

Verified: `examples/testDiscriminatedUnion.ms` — 9/9 tests pass in compiled C binary.

**Not yet**: pre-computed field paths (standard `fillObjectFields` pattern). Currently resolves variant index on-the-fly per field access. Acceptable for current type system — no inheritance hierarchy to walk. When `class extends` C codegen is implemented (Phase 3), pre-computed paths should be reconsidered.

### Phase 2.8: Class `extends` — C Backend (NOT STARTED)

**Current state**: `class Child extends Base { ... }` is parsed and `typeExtra = createTypeRef(baseClassName)` is stored on the inner struct. But:
- `getProperty` does NOT walk the parent chain — `child.baseField` fails type checking
- C codegen does NOT emit parent struct embedding (standard `Sup` field pattern)
- Field access on inherited fields has no codegen path

**What needs to happen**:
1. **Checker**: `getProperty` must walk `typeExtra` parent chain to find inherited fields
2. **C codegen type emission**: Embed parent struct as first field (`struct Child { Base Sup; ... }`)
3. **C codegen field access**: `child.baseField` → `child.Sup.baseField` (walk parent path)
4. **Pre-computed field paths**: Compute full C access path (including `Sup.` prefix) during type generation, cache on Symbol. Currently our discriminated union variant field access resolves on-the-fly (O(variants × fields) per access), which is fine for flat unions but won't scale for deep inheritance chains.

**Dependency**: Phase 3 (`implements`) and Phase 4 (vtable) build on this.

### Phase 3: Method Signatures + `implements` Checking

**Parser:** Allow `function name(params): RetType;` (no body) in interface body.

**Checker:**
- Record method signatures in interface type
- `implements` verification: class must have all fields + methods with matching types
- Currently parsed & skipped — wire up actual checking

### Phase 4: Vtable / Polymorphism

**C codegen:**
- Generate vtable struct per interface with methods
- Class instances carry vtable pointer
- Interface method call dispatches through vtable

```c
// Generated C for interface with methods
struct IPrintable_vtable {
    msString* (*toString)(void* self);
};

// Class instances carry vtable
struct Admin {
    IPrintable_vtable* vtable;
    msString* name;
    int age;
};
```

### Phase Summary

| Phase | What | Status |
|-------|------|--------|
| ~~1~~ | ~~Add `struct` keyword~~ | ~~DONE~~ |
| ~~2~~ | ~~Interface -> reference in C~~ | ~~DONE~~ |
| 2.5 | Struct param semantics + enhancements | Partially done |
| | — `ref` modifier | DONE |
| | — `mutatedParams` analysis | DONE |
| | — Auto-optimized param ABI | DONE (infrastructure) |
| | — GcMode auto-detect | DONE |
| | — `readonly` modifier | Not started |
| | — Intersection syntax, method rejection | Not started |
| ~~2.7~~ | ~~Discriminated unions (type = match)~~ | ~~DONE~~ |
| 2.8 | Class `extends` — C backend (parent embed, field walk) | Not started |
| 3 | Method signatures + `implements` | Not started |
| 4 | Vtable / polymorphism | Not started |

## Summary

- **interface** stays exactly as TypeScript developers expect — reference semantics, no keyword bending
- **class** stays as TypeScript developers expect — reference, `implements` interfaces
- **struct** is MetaScript-only — opt-in value type for performance, data only, no methods, compiler-enforced
- No behavioral difference across backends for reference types (Layer 1)
- Value types (Layer 2) are the performance/control superset for C-targeting code
- The working Bun runtime proves reference-first is correct — `struct` is an optimization, not a migration necessity
