# Phase 5: C Code Generation

Emits C source from the post-analyzer AST. Pipeline: `parse → check → transform → analyze → builtinLower → codegen`.

**Codegen stays thin** — the rule, its evidence and the checklist are in the root [`CLAUDE.md`](../../../CLAUDE.md), "Codegen Must Be Thin/Dumb". What belongs here: syntax mapping, section ordering, name mangling, C type mapping.

## Rules

- **A C file is assembled from sections, never written in order** — `CSection` (`context.ms`): `Headers`, `ForwardDecls`, `Types`, `SeqTypes`, `ProcHeaders`, `StringPool`, `GlobalVars`, `Procs`, `DatInit`, `ModuleInit`; write with `addLine(sec(g, section), ...)` so forward declarations and ordering hold. `DatInit` runs before `ModuleInit`.
- **`CLoc` carries where a value lives** — `kind` (`CLocKind`: `None` = a free slot the callee fills, `Temp`, `LocalVar`, `GlobalVar`, `Param`, `Field`, `Expr`, `Proc`), `storage`, the C `snippet`, `isIndirect` (the backend introduced a pointer), `locType`.
- **`CProc` carries the per-function state** — the block stack, the temp counter, break/loop depth, the `finally` and error-target stacks, indirect params and locals that auto-deref, and the per-name conflict counters that give every local a unique C name.
- **Hoist what has side effects or is reused** — `getTemp(p, cType)` gives a local temp.
- **Every user symbol goes through the manglers in `names.ms`** — no raw source name reaches C, so C keywords cannot collide.
- **Large value types return through an out-parameter, and it is the FIRST parameter** — structs, tuples and results (`isNrvoReturnType`, `types.ms`); interfaces and classes are references and return as pointers. Direct calls and closure calls agree: `genClHalfCastNrvo` / `genClFullCastNrvo` cast to a `void` return with `Type*` prepended.

## Builtins

| Form | Meaning | Lowered by |
|------|---------|------------|
| `@builtin("Name")` | compiler-intercepted call | `builtinLower` (`src/transform/native/`) |
| Extension method | `value.method(args)` on an `extern function ... (this ...)` | `extensionMethodLower` (`src/transform/lowering/`) |

**The checker sees normal signatures** — `extern function ... from` stores `nativeName` on the AST and the collector wires it to the Symbol; only `builtinLower` reads `@builtin`, so codegen sees a plain call to a known runtime function.

## Not verified here

The `CLoc` / `CProc` lines are read from the type definitions in `context.ms`, not from a traced emission.
