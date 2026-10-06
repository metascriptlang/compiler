# Raiser Codegen — AST → bytecode

Compiles the post-Phase-3 AST into Raiser bytecode: `parse → check → transform → Raiser codegen → Raiser VM`. Phase 4 (DRC) and Phase 5 (C/JS) are skipped; the VM has its own memory model. What each node kind emits is in `expressions.ms` and `statements.ms`, the emit helpers in `context.ms`, the opcodes in `src/raiser/bytecode.ms`.

## Files

| File | Holds |
|------|-------|
| `index.ms` | hub |
| `context.ms` | `RaiserCompState`, emit helpers, register allocator, loop and scope state |
| `expressions.ms` / `statements.ms` | `compileExpr` / `compileStmt` |
| `rgen.ms` | `generateRaiser`, `generateRaiserProject`, class compilation, tests |
| `eval.ms` | full-pipeline evaluation, project and class integration tests |
| `valueCopy.ms` | static `Type` → flat `RaiserCopyPlan`, `CopyValue` emission |

## Rules

- **AST knowledge lives here, the VM has none** — this directory imports the types of `src/raiser/bytecode`, `value` and `module` and hands over a `RaiserModule`; `src/raiser/` never sees a node.
- **A site known bad at compile time queues a warning AND emits `Trap`** — unresolvable identifier, unsupported node kind, `new` without a constructor, unsupported compound-assign or update target; reaching one at runtime is a fatal vmError, not a catchable raise.
- **Collection order defines `funcIdx`, and `projectDecls[funcIdx]` must describe that same declaration** — functions and enums of all modules first, then classes (methods before their constructor), then builtins; bodies compile on demand (`resolveFunc → demandBody(funcIdx)` fills `functions[funcIdx]` in place), so a body nobody demands is never compiled and its warnings never fire.
- **Routine lookup uses the resolved symbol's module path and original name** — raw spelling is only the fallback of single-program compilation, and a call through a name a local or parameter binds is a closure call, whatever routine shares the spelling (eval "a call through a local closure calls the closure …").
- **Each module-level variable owns one VM global slot** — initializers run in dependency order, an imported module initializes once per project run, the entry module last.
- **`CopyValue` gives arrays and structs value semantics** — every compiled function carries a flat copy-plan table, applied at assignment, argument, return and container-store boundaries; shared references and `Span` are preserved.
- **An assignment into a location that already holds a struct or an array writes into that object** (`emitValueAssign`, NIM-REF CG-40) — an element, a field, a global or local binding, `p[]` and a `ref` parameter, so every pointer to the location keeps seeing it; an array takes the source length first; a parameter or a for-of binding is a view and rebinds; an empty location takes a copy.
- **A pointer or `ref` to anything else is a location value** (`RegAddr`, `GlobalAddr`, `ElemAddr`, `FieldAddr`; the reference VM's `rkRegisterAddr` / `rkNodeAddr`, vm.nim:927-979): `HiddenAddr` takes it (`AddrReg` … `AddrField`), and `HiddenDeref`, `p[0]`, an assignment, `+=` and `++` go through it (`LoadDeref`, `StoreDeref`). `transformForRaiser` runs `insertVarParamDerefs` last, so a `ref`/`out` argument arrives as `HiddenAddr`; a host call still receives the value. A location keeps the array or object it points into alive under ORC (`heldHandle`).
- **A spawned strand gets a graph copy of the parent's global slots** — globals are strand-local snapshots, not shared mutable state.
- **Spread is lowered before bytecode generation** — each source is evaluated once; array insertion goes through the VM `push` builtin.
- **Loops and generators arrive lowered** — `for` and `for..of` go through the loop lowering C uses, and a `function*` through C's generator lowering, before lambda lifting, so ranging a `Map` or a `Set` runs their generators as state machines, and a closure made in a loop body gets the env of its own iteration; a labelled `break` or `continue` jumps to the loop carrying the label. The native `for` / `for..of` compilation serves only the untransformed `rgen.ms` path.
- **Pending generic instances attach to their owning module before monomorphization, macro expansion and Raiser lowering** — on-demand compilation is scoped to the project image and restored afterwards.
- **A function value is a closure pair `{ fn: funcIdx, env }`, `env = -1` when nothing is captured** — `compileClosureCall` branches on it at runtime and appends the env as the LAST argument, so it lands at `R[arity]`; a function identifier inside an expression stays a raw integer.
- **Methods are top-level functions whose `this` is the closure env** — bound at `R[arity]`; `<Class>_new` creates the object, stores default properties and the method closures of its class chain, the most derived last (`{ fn, env: this }`, `env = -1` for a checked method that takes `this` as parameter 0), runs the constructor body and returns `this`; a method call is `LoadField` + `CallIndirect`.
- **An object keeps the class it was made with** — `<Class>_new` makes it with an entry of its function's class-type table (class key and the keys of its bases, the per-function idiom of the copy plans); `instanceof` and a checked `as` test that entry, a strand copy and a value copy keep it, and a failed checked `as` is fatal as on C.
- **`super(...)` calls the parent's `<Class>_init(this, args)`** — the parent's default properties and constructor body on the same object; a checked call to a method that has overrides loads the method from the receiver (NIM-REF CG-17), other method calls stay direct.
- **Registers are a bump allocator** — `resetTemps` after each top-level statement keeps the locals and reclaims the temps.

## Not handled

Each probed on `msc run --target=raiser`:

- `static` members — `cannot evaluate '<Class>' at comptime: symbol kind is Class`.
- A string index — `s[1]` stops with `expected an array, got value kind String` (a `for..of` over a string runs: `abc`, measured 2026-10-06).

## Tests

```bash
msc test src/codegen/raiser/rgen.ms    # parse → codegen → VM
msc test src/codegen/raiser/eval.ms    # parse → check → transform → codegen → VM
```

## Not verified here

Both test commands pass. The rules from "Routine lookup" to "Pending generic instances" are carried over from the previous text and were not exercised one by one.
