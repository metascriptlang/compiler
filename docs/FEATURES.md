# Feature Design Notes

---

## Built-in Types, Methods & Standard Library

### Design: Single Source of Truth in `.ms` Files

All builtins declared in `std/*.ms` files (auto-imported like Nim's system.nim). Normal MetaScript code — `export`, `class`, `@runtime`, `@builtin`, static/instance extensions. The compiler handles auto-importing.

**3-tier system:**

| Tier | Decorator | Use Case | Example |
|------|-----------|----------|---------|
| `@builtin("Name")` | Compiler-intercepted (inline codegen) | `len`, `sizeof` | `@builtin("LengthStr") export function len(s: string): number;` |
| `@runtime("c_name")` | Maps to C runtime function | Math, string/array methods | `@runtime("ms_floor") export function floor(this typeof Math, x: number): number;` |
| `extern function` | Raw C FFI | malloc, printf | `extern function malloc(size: number): Ptr<void>;` |

**Checker sees normal signatures** — `@builtin`/`@runtime` are opaque decorators. Only `builtinLower` transform (C-backend, post-analyzer) reads them to rewrite calls.

### Builtin Dispatch Strategy

| Builtin | Mechanism | Why |
|---------|-----------|-----|
| `Math.floor()` | Global class + static extension (`this typeof Math`) | Math has constants (pi, e) |
| `Math.pi` | Property access on global Math class instance | Class field with default value |
| `console.log()` | Global class + static extension (`this typeof Console`) | Console is a namespace |
| `Promise.resolve()` | Global class + static extension (`this typeof Promise`) | Promise is a type |
| `Result.ok()` | Global class + static extension (`this typeof Result`) | Result is a type |
| `str.trim()` | Instance extension (`this s: string`) | String method |
| `arr.push()` | Instance extension (`this arr: T[]`) | Array method |

### Static Extensions (`this typeof Type`)

For global classes used as namespaces or type constructors:

```ms
// std/math.ms — both class methods and static extensions work

export class Math {
    pi: number = 3.141592653589793;
    e: number = 2.718281828459045;

    @runtime("ms_floor")
    floor(x: number): number { unreachable; }
}

// static extensions also work
@runtime("ms_abs")
export function abs(this typeof Math, x: number): number { unreachable; }

// Usage: Math.floor(3.7) → ms_floor(3.7)
// Usage: Math.abs(-5) → ms_abs(-5)
// Usage: Math.pi → 3.141592653589793
```

### Pipeline Flow

```
std/*.ms auto-imported → checker gets real type signatures
  → transforms lower extensions (str.trim() → trim(str))
  → analyzer injects DRC
  → builtinLower rewrites to C names (trim(str) → ms_string_trim(str))
  → codegen emits plain calls (no dispatch tables)
```

Tree-shaking: demand-driven codegen from `main()`. Unused builtins = zero C output.

### What Needs Building

| Component | Priority | Notes |
|-----------|----------|-------|
| `std/core.ms`, `std/math.ms`, `std/console.ms`, etc. | 5a | Normal `.ms` files with `@builtin`/`@runtime` |
| Auto-import in checker | 5a | Parse + type-check system modules before user code |
| `@builtin`/`@runtime` handling in collectPass | 5a | Set Symbol.builtinKind / runtimeName |
| `this typeof Type` static extensions | 5a | Parser + checker + extension registry |
| `transform/native/builtinLower.ms` | 5b | Rewrite builtin calls to C-compatible AST |

---

## Decorators & Directives (`@name`)

Both use `@` syntax with free-form args: `@name`, `@name("str", 42)`, `@name({...options})`.
- **Decorator** = `@name(...) decl` (attaches to next declaration).
- **Directive** = `@name(...);` (ends with `;`, standalone). Only the semicolon disambiguates.

### Decorators (attach to declarations)

| Decorator | Applies To | Purpose | Status |
|-----------|-----------|---------|--------|
| `@runtime("c_name")` | function, method | Bind to C runtime function. Codegen emits `c_name` unmangled. | DONE |
| `@builtin("Name")` | function, method | Compiler-intercepted op. Sets `Symbol.builtinKind` for special codegen. | DONE |
| `@derive(Trait, ...)` | class, interface | Auto-generate methods (Eq, Hash, Clone, Debug, Serialize). | REF ONLY |
| `@comptime` | block | Compile-time evaluation via Hermes VM. | REF ONLY |
| `@target("c")` | block | Backend-conditional code — only emit for specified target. | DESIGN |
| `@emit("...")` | statement | Inline raw C/JS code into output. | DESIGN |
| `@inline` | function | Hint to inline function body at call site. | DESIGN |

### Directives (standalone, module-level)

| Directive | Purpose | Status |
|-----------|---------|--------|
| `@include("file.h");` | Include C header + auto-compile matching `.c`. Stored on Program node. | REF ONLY |
| `@link("lib.a");` | Link pre-built archive. | REF ONLY |
| `@passC("-Ifoo");` | Raw C compiler flag. | REF ONLY |
| `@passL("-lssl");` | Raw linker flag. | REF ONLY |

### Self-Hosted Parser Status

- `@name(args)` parsed as `MacroInvocation` → `{ macroName, macroArgs }` (**DONE**)
- Multiple decorators stack: `@a @b class Foo {}` → `DecoratedDecl { decorators: [a, b], decoratedNode }` (**DONE**)
- Checker walks through `DecoratedDecl` to check the inner node (**DONE**)
- JS codegen skips decorators, emits inner declaration (**DONE**)
- `@runtime`/`@builtin` set Symbol metadata in collectPass (**DONE**)

### Implementation Plan

**Phase 5a** (needed for C codegen):
- `@runtime("c_name")` → collectPass sets `Symbol.runtimeName` (**DONE**)
- `@builtin("Name")` → collectPass sets `Symbol.builtinKind` (**DONE**)
- `@include("file.h")` → collected on Program node for build system
- `@target("c")` → transform strips non-matching target blocks

**Phase 5b+** (later):
- `@derive` → Hermes VM macro expansion (or hardcoded for Eq/Hash)
- `@emit` → codegen injects raw string into output
- `@inline` → codegen inlines function body
- `@comptime` → Hermes VM evaluation
