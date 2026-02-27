# Feature Design Notes

---

## Built-in Types, Methods & Standard Library

### Design: Single Source of Truth in `.ms` Files

All builtins declared in `std/core.ms` (auto-imported like Nim's `system.nim`). One declaration = type signature + C mapping. No triple registration like the reference compiler.

**3-tier system:**

| Tier | Decorator | Use Case | Example |
|------|-----------|----------|---------|
| `@builtin("Name")` | Compiler-intercepted (inline codegen) | `len`, `print`, `sizeof` | `@builtin("LengthStr") export function len(s: string): number;` |
| `@runtime("c_name")` | Maps to C runtime function | Math, string/array methods | `@runtime("floor") export function floor(x: number): number;` |
| `extern function` | Raw C FFI | malloc, printf | `extern function malloc(size: number): Ptr<void>;` |

**Checker sees normal signatures** — `@builtin`/`@runtime` are opaque decorators. Only `builtinLower` transform (C-backend, post-analyzer) reads them to rewrite calls.

### Builtin Dispatch Strategy

| Builtin | Mechanism | Why |
|---------|-----------|-----|
| `Math.floor()` | Module namespace (`import * as Math from "std/math"`) | Math is a natural module |
| `console.log()` | Auto-import + `@builtin` | Global, needs printf codegen |
| `Promise.resolve()` | Static extension (`this typeof Promise`) | Promise is a type, not a module |
| `Result.ok()` | Static extension (`this typeof Result`) | Result is a type, not a module |
| `str.trim()` | Instance extension (`this s: string`) | String method |
| `arr.push()` | Instance extension (`this arr: T[]`) | Array method |

### Static Extensions (`this typeof Type`)

For types that aren't modules (Promise, Result). Reference compiler already has `is_static_receiver`.

```ms
@runtime("ms_promise_resolve")
export function resolve<T>(this typeof Promise, value: T): Promise<T>;
// Usage: Promise.resolve(42) → extensionMethodLower → resolve(42) → builtinLower → ms_promise_resolve(42)
```

### Pipeline Flow

```
std/core.ms auto-imported → checker gets real type signatures
  → transforms lower extensions (str.trim() → trim(str))
  → analyzer injects DRC
  → builtinLower rewrites to C names (trim(str) → ms_string_trim(str))
  → codegen emits plain calls (no dispatch tables)
```

Tree-shaking: demand-driven codegen from `main()`. Unused builtins = zero C output.

### What Needs Building

| Component | Priority | Notes |
|-----------|----------|-------|
| `std/core.ms`, `std/math.ms`, `std/string.ms`, `std/array.ms` | 5a | Declarations with `@builtin`/`@runtime` |
| Auto-import in checker | 5a | Load std/core.ms before user code |
| `@builtin`/`@runtime` handling in collectPass | 5a | Set Symbol.builtinKind / runtimeName |
| `transform/c/builtinLower.ms` | 5b | Rewrite builtin calls to C-compatible AST |
| extern type info fix | 5a | ExternDecl must store param types + return type |

---

## Decorators & Directives (`@name`)

Both use `@` syntax with free-form args: `@name`, `@name("str", 42)`, `@name({...options})`.
- **Decorator** = `@name(...) decl` (attaches to next declaration).
- **Directive** = `@name(...);` (ends with `;`, standalone). Only the semicolon disambiguates.

### Decorators (attach to declarations)

| Decorator | Applies To | Purpose | Status |
|-----------|-----------|---------|--------|
| `@runtime("c_name")` | function | Bind to C runtime function. Codegen emits `c_name` unmangled. | DESIGN |
| `@builtin("Name")` | function | Compiler-intercepted op. Sets `Symbol.builtinKind` for special codegen. | DESIGN |
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
- **NOT DONE**: Decorator semantics — checker/transforms don't read decorator names or arguments yet

### Implementation Plan

**Phase 5a** (needed for C codegen):
- `@runtime("c_name")` → collectPass sets `Symbol.runtimeName`
- `@builtin("Name")` → collectPass sets `Symbol.builtinKind`
- `@include("file.h")` → collected on Program node for build system
- `@target("c")` → transform strips non-matching target blocks

**Phase 5b+** (later):
- `@derive` → Hermes VM macro expansion (or hardcoded for Eq/Hash)
- `@emit` → codegen injects raw string into output
- `@inline` → codegen inlines function body
- `@comptime` → Hermes VM evaluation
