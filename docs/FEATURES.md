# Feature Design Notes

---

## Built-in Types, Methods & Standard Library

### Design: Single Source of Truth in `.ms` Files

All builtins declared in `std/*.ms` files (auto-imported standard library). Normal MetaScript code — `export`, `class`, `extern … from "c_name"`, `@builtin`, static/instance extensions. The compiler handles auto-importing.

**3-tier system:**

| Tier | Decorator | Use Case | Example |
|------|-----------|----------|---------|
| `@builtin("Name")` | Compiler-intercepted (inline codegen) | `len`, `sizeof` | `@builtin("LengthStr") export function len(s: string): number;` |
| `extern function … from "c_name"` | Binds a C function under a MetaScript name | Math, string/array methods | `export extern function floor(this typeof Math, x: float64): float64 from "floor";` |
| `extern function` | Raw C FFI | malloc, printf | `extern function malloc(size: number): Ptr<void>;` |

**Checker sees normal signatures** — `@builtin` is an opaque decorator. Only `builtinLower` transform (C-backend, post-analyzer) reads it to rewrite calls.

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
// std/core/math/index.cms

export class Math {
    static PI: float64 = 3.141592653589793;
    static E: float64 = 2.718281828459045;
}

export extern function abs(this typeof Math, x: float64): float64 from "fabs";
export extern function floor(this typeof Math, x: float64): float64 from "floor";

// Usage: Math.floor(3.7) → floor(3.7)
// Usage: Math.abs(-5) → fabs(-5)
// Usage: Math.PI → 3.141592653589793
```

### Pipeline Flow

```
std/*.ms auto-imported → checker gets real type signatures
  → transforms lower extensions (str.trim() → trim(str), no type prefix)
  → analyzer injects DRC
  → builtinLower rewrites to C names (trim(str) → ms_string_trim(str))
  → codegen emits plain calls (no dispatch tables)
```

Tree-shaking: demand-driven codegen from `main()`. Unused builtins = zero C output.

### What Needs Building

| Component | Priority | Notes |
|-----------|----------|-------|
| `std/core.ms`, `std/math.ms`, `std/console.ms`, etc. | 5a | Normal `.ms` files with `@builtin`/`extern … from` |
| Auto-import in checker | 5a | Parse + type-check system modules before user code |
| `@builtin`/`@exportName`/`from "c_name"` handling in collectPass | 5a | Set Symbol.builtinKind / exportName / nativeName |
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
| `@exportName("c_name")` | module-level function with a body | Defines the C symbol `c_name`: unmangled, external linkage, kept by dead-code elimination. Bare `@exportName` keeps the MetaScript name. The import side is `extern function … from "c_name"`. | DONE |
| `@builtin("Name")` | function, method | Compiler-intercepted op. Sets `Symbol.builtinKind` for special codegen. | DONE |
| `@derive(Trait, ...)` | class, interface | Auto-generate methods (Eq, Hash, Clone, Debug, Serialize). | REF ONLY |
| `@comptime` | block | Compile-time evaluation via Hermes VM. | REF ONLY |
| `when (c) { … }` | block | Backend-conditional code — first true branch is spliced, others are dropped at parse and never type-checked. | DONE |
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
- `@exportName`/`@builtin` set Symbol metadata in collectPass (**DONE**)

### Implementation Plan

**Phase 5a** (needed for C codegen):
- `@exportName("c_name")` → collectPass sets `Symbol.exportName` (**DONE**)
- `@builtin("Name")` → collectPass sets `Symbol.builtinKind` (**DONE**)
- `@include("file.h")` → collected on Program node for build system
- `when (c) { … }` → parser splices the taken branch, drops the rest (`@target` retired)

**Phase 5b+** (later):
- `@derive` → Hermes VM macro expansion (or hardcoded for Eq/Hash)
- `@emit` → codegen injects raw string into output
- `@inline` → codegen inlines function body
- `@comptime` → Hermes VM evaluation
