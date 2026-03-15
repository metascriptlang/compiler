# MetaScript Raw Memory Primitives

This document specifies the low-level "Systems Programming" primitives required to write the MetaScript runtime (strings, arrays, memory management) in MetaScript itself. These primitives allow bypassing the high-level Automatic Reference Counting (ORC) to perform manual memory management.

## 1. `Pointer<T>` Type

`Pointer<T>` is a generic type representing a raw C pointer (`T*`). It is the "unsafe" counterpart to a standard MetaScript reference (interface/class).

### Key Characteristics:
- **No Refcounting:** The compiler's Automatic Reference Counting (ORC) and Data-Race Coverage (DRC) systems **completely ignore** variables of type `Pointer<T>`. No `incref` or `decref` calls are generated.
- **Manual Lifetime:** The programmer is responsible for the allocation and deallocation of the memory pointed to by a `Pointer<T>`.
- **C-Mapping:** Compiles directly to `T*` in the C backend.
- **Member Access:** Accessing a field through a `Pointer<T>` (e.g., `p.field`) compiles to the C arrow operator (`p->field`).

```typescript
interface Node {
    value: int;
    next: Pointer<Node>; // Raw pointer to the next node (manual lifetime)
}
```

## 2. `sizeof` Operator

`sizeof` is a unary operator that returns the size of a Type in bytes at compile time.

### Syntax:
`sizeof <Type>`

### Key Characteristics:
- **Input:** Must be a valid Type name (not a value).
- **Output:** Returns a `number` representing the byte count.
- **C-Mapping:** Compiles directly to the C `sizeof(T)` keyword.
- **Precedence:** High precedence, similar to `typeof`. Use parentheses for complex expressions like `(sizeof T) + 10`.

```typescript
const size = sizeof msStrPayload; // Returns 16 on a 64-bit system
```

## 3. `extern` Declarations

The `extern` keyword is used to declare standard C functions and variables that are implemented outside of MetaScript.

### Syntax:
`extern function <name>(<params>): <type>;`

### Example:
```typescript
@include("stdlib.h");

extern function malloc(size: number): Pointer<void>;
extern function free(p: Pointer<void>): void;
extern function realloc(p: Pointer<void>, size: number): Pointer<void>;
```

---

## Use Case: Self-Hosted String Runtime

Combining these primitives allows us to move the "dirty" C code from `runtime/core/string.c` into a clean MetaScript implementation.

```typescript
// std/runtime/string.ms

interface msStrPayload {
    cap: int;
    data: char; // Flexible array member (start of buffer)
}

/**
 * Allocates a new string payload with a given length.
 * This is a low-level operation that bypasses the high-level refcounting.
 */
export function ms_string_new(len: number): Pointer<msStrPayload> {
    // 1. Calculate the total size (header + data + null terminator)
    const size = (sizeof msStrPayload) + len + 1;
    
    // 2. Allocate the raw memory from the C heap
    const p = malloc(size) as Pointer<msStrPayload>;
    
    // 3. Initialize the payload (compiles to p->cap = len)
    p.cap = len;
    
    // 4. Pointer arithmetic (compiles to p->data[len] = 0)
    p.data[len] = 0; 
    
    return p;
}
```

## Implementation Plan

1. **Lexer:** Add `sizeof` to the list of keywords.
2. **Parser:** Handle `sizeof <Type>` as a valid Expression node.
3. **Checker:** 
   - Define `Pointer<T>` as a built-in generic.
   - Flag variables of type `Pointer<T>` as "Non-Refcounted".
   - Verify `sizeof` takes a Type and returns a `number`.
4. **Analyzer (Phase 4):** Skip `incref`/`decref` for `Pointer<T>` types.
5. **Codegen (Phase 5):** Emit `sizeof(T)`, `T*`, and `p->field` for `Pointer<T>` accesses.
