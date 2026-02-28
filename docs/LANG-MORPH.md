# Monomorphization Reference

Monomorphization duplicates generic functions and types with concrete type arguments for the C backend. This document covers all generic features, architecture, and usage.

## Overview

MetaScript generics are erased at compile time via monomorphization. Each unique combination of type arguments produces a dedicated concrete version. The C backend emits these as separate functions/structs with mangled names.

**Pipeline position:** `parse → check → **monomorphize** → transform → analyze → codegen`

## Supported Features

| Feature | Status | Example |
|---------|--------|---------|
| Generic functions (inferred) | Done | `identity(42)` → `identity__number` |
| Generic functions (explicit) | Done | `identity<number>(42)` → `identity__number` |
| Nested generic calls | Done | `foo<T>` calling `bar<T>` in body |
| Generic interfaces | Done | `interface Box<T> { value: T; }` |
| Generic classes | Done | `class Container<T> { item: T; }` |
| Constraints | Done | `<T extends Comparable>` |
| Body re-type-checking | Done | Type errors caught in instantiated bodies |
| Recursive generics | Done | Forward decl pattern handles self-referencing |

## Architecture: 3-Pass Monomorphization

### Pass 1: Collect Definitions

Scans the program AST for generic function declarations (detected by `gen:T,U` in `fnFlags`). Stores name → index mapping in a definition map.

```ms
// Parser encodes generic params in fnFlags:
function identity<T>(x: T): T { return x; }
// → fnFlags = "gen:T"
```

### Pass 2: Collect Call Sites

Walks all expressions looking for `CallExpr` nodes that call generic functions. For each call:

1. **Explicit type args?** Check parser side-channel (`TypeArgStore`) for `identity<number>(42)`
2. **Infer type args?** Match `GenericParam` formal types against concrete argument types
3. **Register** in `MonoRegistry` with concrete type list

Fixed-point loop handles nested generics:
```
loop:
  instantiate un-instantiated entries (clone AST + substitute types)
  walk each new cloned body for generic calls → register new entries
  if no new entries: break
  if iterations > 50: break (recursion limit)
```

### Pass 3: Rewrite

Replaces call sites in the original AST:
- `identity(42)` → callee identifier changed to `identity__number`
- Generic template declarations removed from program
- Instantiated concrete declarations inserted

## Name Mangling

```
<function_name>__<type_arg_key>

identity<number>      → identity__number
identity<string>      → identity__string
Pair<number, string>  → Pair__number,string
Box<Box<number>>      → Box__Box__number
```

Type arg keys use `monoTypeKey()`:
- Primitives: `number`, `string`, `boolean`, `void`
- Named types: `TypeName`
- Arrays: `Array__T`
- References: type name directly

## Generic Functions

### Implicit Inference

```ms
function identity<T>(x: T): T { return x; }

const a = identity(42);        // → identity__number(42)
const b = identity("hello");   // → identity__string("hello")
```

The monomorphizer matches `GenericParam("T")` in the function's formal param types against the concrete argument types to infer `T = number`.

### Explicit Type Arguments

```ms
const x = identity<number>(42);
```

The parser detects `<` after an identifier followed by balanced `<>` then `(` (lookahead via `isGenericCallAhead()`). Type args are stored in a per-call-site side-channel (`TypeArgStore` in `parser/context.ms`), keyed by source location `(line, column)`.

### Nested Generic Calls

```ms
function compose<T>(x: T): T {
    return transform<T>(x);  // inner generic call
}
const result = compose(42);
// → compose__number AND transform__number both instantiated
```

The fixed-point loop detects new call sites in instantiated bodies.

## Generic Interfaces

```ms
interface Box<T> {
    value: T;
}

function unbox(b: Box<number>): number {
    return b.value;
}
```

**Parser:** `captureGenericParams()` captures `"T"`, `addGenericDecl("Box", "T")` stores in side-channel. After parsing fields, `updateGenericDeclFields("Box", "value", "T")` records field info as pipe-joined strings.

**Checker:** When `resolveAnnotation("Box<number>")` encounters a generic interface:
1. Opens a temporary scope with `GenericParam("T")` defined
2. Calls `recordGenericTypeInstantiation("Box", "T", ["number"])`
3. Substitutes `T → number` in field types: `"T" → "number"`
4. Returns `TypeReference("Box__number")`

**Codegen:** `genGenericTypeInsts()` reads the instantiation store and emits:
```c
typedef struct ms_Box__number ms_Box__number;
struct ms_Box__number {
  double value;
};
```

## Generic Classes

Same pattern as interfaces. Properties are extracted from the class body:

```ms
class Container<T> {
    item: T;
    count: number;
}
```

Parser extracts property names/types from `PropertyDecl` nodes in `classBody` and stores via `updateGenericDeclFields("Container", "item|count", "T|number")`.

Methods are emitted as free functions with the class pointer as first parameter. For generic classes, method instantiation follows the same concrete-per-type-arg pattern.

## Constraints

```ms
function clamp<T extends number>(x: T, lo: T, hi: T): T {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}
```

**Parser:** `captureGenericParams()` captures `"T:number"` when `extends` keyword follows a type param.

**Checker:** `defineGenericParam(ctx, "T:number")` splits on `:`, creates `GenericParam("T")` with `typeExtra = numberType()`.

**Format:** `"T:ConstraintType"` — colon separates name from constraint within the comma-joined param string. Example: `"T:Comparable,U"` = T constrained to Comparable, U unconstrained.

## Recursive Generics

```ms
interface Tree<T> {
    value: T;
    left: Tree<T>;
    right: Tree<T>;
}
```

Handled naturally by the forward declaration pattern:
1. `typedef struct ms_Tree__number ms_Tree__number;` (forward decl)
2. Full struct definition with `ms_Tree__number*` pointer fields

The fixed-point loop's dedup prevents infinite re-instantiation.

## Side-Channel Architecture

All generic metadata uses **side-channel maps** to avoid modifying AST node data structures:

| Store | Location | Purpose |
|-------|----------|---------|
| `GenericDeclStore` | `parser/context.ms` | Generic param names + field info per declaration |
| `TypeArgStore` | `parser/context.ms` | Explicit type args at call sites (keyed by location) |
| `GenericTypeInstStore` | `parser/context.ms` | Recorded instantiations for codegen |

All stores use parallel `string[]` arrays (SoA pattern) for DRC safety. Field names/types are pipe-joined strings (`"field1\|field2"`).

### API Functions

```ms
// Generic declarations
addGenericDecl(name, genericParams)           // "Box", "T,U"
getGenericDecl(name): string                   // returns "T,U" or ""
updateGenericDeclFields(name, fields, types)   // pipe-joined strings

// Explicit type args (parser → monomorphize)
addExplicitTypeArg(line, col, typeArgStr)
getExplicitTypeArg(line, col): string

// Type instantiations (checker → codegen)
addGenericTypeInst(baseName, typeArgKey, mangledName, fieldNames, fieldTypes)
getGenericTypeInstCount(): number
getGenericTypeInstMangledName(idx): string
getGenericTypeInstFieldCount(idx): number
getGenericTypeInstFieldNameAt(idx, fieldIdx): string
getGenericTypeInstFieldTypeAt(idx, fieldIdx): string
```

## DRC Safety

The monomorphization module follows strict DRC constraints:

1. **No NodeData union changes** — all generic data in side-channel string[] maps
2. **Module graph depth** — clone + instantiate code inlined into `collect.ms` to avoid import depth issues
3. **Interface params in match arms** — if-else chains instead of match for mutable interface params
4. **Cross-module Node returns** — helpers return primitives only, not Node/Node[]
5. **Callback injection** — `callCheckStmt` callback for body re-checking avoids circular imports

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/monomorphize/collect.ms` | ~1330 | Definitions, call sites, cloning, instantiation, rewriting |
| `src/monomorphize/registry.ms` | ~200 | MonoRegistry, MonoEntry, dedup, name mangling |
| `src/parser/context.ms` | +~200 | Side-channel stores (GenericDecl, TypeArg, TypeInst) |
| `src/checker/resolvePass.ms` | +~60 | recordGenericTypeInstantiation, defineGenericParam |
| `src/codegen/c/declarations.ms` | +~30 | genGenericTypeInsts (concrete struct emission) |

## Interaction with Other Phases

- **Phase 2 (Checker):** Records generic interface/class instantiations during type resolution
- **Phase 2.5 (Monomorphize):** Runs after checking, before transforms. Rewrites AST in-place.
- **Phase 3 (Transform):** Operates on monomorphized AST — sees concrete functions only
- **Phase 4 (Analyzer/DRC):** Injects lifecycle hooks per concrete type instantiation
- **Phase 5 (Codegen):** Emits concrete struct definitions from instantiation store
