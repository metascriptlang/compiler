# Phase 5: C Code Generation

Emits C source from the post-analyzer AST. Standard optimized architecture (section-based, modular).

**Pipeline**: `parse → check → transform → analyze → builtinLower → codegen`

---

## 1. Architectural Mandate: Codegen Must Be Thin

The #1 goal of the C backend is to be **dumb**. If logic can live in a pre-codegen transform (`src/transform/`), it MUST live there. Codegen should focus exclusively on syntax mapping (AST → C tokens) and low-level emission details (section ordering, name mangling, C type mapping).

### The Rule

Whenever working on something that ends at C codegen, **first check if the equivalent logic lives in an earlier phase** (transform, semantic analysis, etc.) rather than codegen. **If it can be handled before codegen, it should be.**

### Why This Matters

1. **Testability**: Transforms produce ASTs which are easy to inspect and unit test. Codegen produces strings which are brittle to test.
2. **Reuse**: Transforms like `matchLower` or `lambdaLifting` benefit all backends (JS, Raiser, etc.). Codegen logic is locked to C.
3. **Complexity Control**: `cgen.ms` is already complex. Offloading to transforms keeps it manageable.

### Checklist Before Adding Codegen Logic

1. Does a standard transform already handle this or could it? If yes, put it in our Transform phase.
2. Is this a type resolution issue? If yes, it belongs in the Checker or type resolution pass.
3. Is this a desugaring/lowering? If yes, it belongs in `src/transform/`.

---

## 2. Core Concepts

### Section-Based Output

A C file is emitted in sections (`CSection` enum) to handle forward declarations and topological ordering:
- `Headers` (#include)
- `TypeForw` (typedef struct Foo Foo;)
- `TypeDefs` (struct Foo { ... };)
- `ProcForw` (void bar(void);)
- `Data` (static string constants)
- `Procs` (void bar() { ... })
- `Init` (module initialization)

- Each module registers its initialization code into the appropriate dispatcher.

### CLoc (expression result carrier)

Every expression emission returns a `CLoc` which tracks:
- `kind`: Literal, LValue, Expr, etc.
- `storage`: Local, Member, Global
- `snippet`: The C code fragment
- `isIndirect`: Whether it's a pointer introduced by the backend

`locNone` = free slot — callee fills it. If caller has a dest, callee assigns to it.

### CProc (per-function state)

Tracks function-local state:
- `blocks`: Scope stack for labels and temporary management
- `locals`: Declared local variables (hoisted to top of function)
- `labels`: Counter for unique jump targets (try/catch)

---

## 3. Implementation Patterns

### NRVO (Named Return Value Optimization)

Large value-types (interfaces, tuples, results) are returned via an implicit out-parameter `Result*` rather than on the stack.
- `getTypeDesc` determines if a type needs NRVO
- `genCallExpr` injects the destination address as the first argument

---

## 4. Design Guidelines

1. **Avoid `peekResult`**: Pass a `CLoc` destination into `genExprToLoc` instead.
2. **Hoisting**: If an expression has side effects or is reused, use `getTemp(p)` to hoist it to a local.
3. **Mangle Everything**: Use `mangle(name)` for all user-defined symbols to avoid C keyword conflicts.
4. **Section Safety**: Always use `addLine(sec(g, section), ...)` to ensure code ends up in the right place.

---

## Builtin Strategy

### 3-Tier System

| Tier | Syntax | Maps To | Implementation |
|------|--------|---------|----------------|
| `@builtin("Name")` | Compiler-intercepted inline codegen | Internal Magic | `builtinLower` transform |
| `@runtime` | External library implementation | `runtime/core/*.h` | Standard library links |
| Extension Methods | `Type.method(args)` | Unified Function Call Syntax | `extensionMethodLower` |

**Checker sees normal signatures.** `extern function ... from` stores `nativeName` on the AST, wired to Symbol by collector. Only `builtinLower` (post-analyzer, C-backend transform) reads `@builtin`.

### Why builtinLower is Better

We move builtin handling to a pre-codegen transform:
- **Separation**: transform handles builtin normalization, codegen handles C emission
- **Testable**: AST-to-AST rewrite, tested independently
- **Dumb Codegen**: Codegen sees a normal call to a known runtime function

---

## Comparison Summary

| Aspect | Industry Standard | Ours |
|--------|-------------------|---------------------|
| Architecture | Often God objects | Modular, section-based |
| Frontend | Single or multi-pass | 3-pass (Collect/Resolve/Check) |
| Backend | Thick codegen | Thin/Dumb codegen |
| Memory | GC or manual | DRC (Deterministic RC) |
