# Phase 5: C Code Generation

Emits C source from the post-analyzer AST. Nim-aligned architecture (section-based, modular) — not the reference compiler's 40K-line monolith.

**Pipeline**: `parse → check → transform → analyze → builtinLower → codegen`
**Target**: ~3-4K lines across ~10 files (vs reference's 50K)

---

## File Structure

```
src/codegen/c/
  index.ms        -- entry: generateC(program, checkerCtx) → string, section assembly
  context.ms      -- CGen, CProc, CBlock, CLoc, CSection enum, getTemp
  types.ms        -- Type → C type mapping, struct/enum emission, forward decls
  expressions.ms  -- Expression emission with CLoc dest carrier
  statements.ms   -- if, while, do-while, block, break, continue, return
  declarations.ms -- Function/class/interface/enum declaration emission
  calls.ms        -- Call emission, argument handling
  literals.ms     -- String pool, number formatting
  names.ms        -- Name mangling, identifier sanitization
  rc.ms           -- RC operation emission (reads DRC-injected nodes)
```

---

## Core Data Structures

### CSection (C file output model)

```ms
enum CSection {
  Headers, ForwardDecls, Types, SeqTypes,
  ProcHeaders, StringPool, GlobalVars, Procs, ModuleInit,
}
```

Each section is a `StringBuf`. Final assembly concatenates in enum order.

### CLoc (expression result carrier — Nim's TLoc)

```ms
interface CLoc {
  snippet: string;      // C code fragment ("x", "a->b", "T1_")
  kind: CLocKind;       // locNone, locTemp, locLocal, locGlobal, locParam, locExpr, locField
  storage: CStorage;    // onStack, onHeap, onStatic
  isPointer: boolean;   // determines -> vs .
  locType: Type;        // MetaScript type (for RC decisions)
}
```

`locNone` = free slot — callee fills it. If caller has a dest, callee assigns to it.

### CProc (per-function state — Nim's 3-section pattern)

```ms
interface CProc {
  name: string;         // mangled C name
  returnType: Type;
  locals: StringBuf;    // cpsLocals: variable declarations
  init: StringBuf;      // cpsInit: initialization code
  stmts: StringBuf;     // cpsStmts: statement code
  blocks: CBlock[];     // nested block stack
  labels: number;       // unique temp counter (T1_, T2_, ...)
  params: string[];     // parameter names
}
```

### CBlock (nested scope)

```ms
interface CBlock {
  locals: StringBuf;
  stmts: StringBuf;
  isLoop: boolean;
  breakLabel: string;   // nil if unused (lazy)
}
```

Block exit merges sections into parent block.

### CGen (module-level — NOT a god object, ~15 fields max)

```ms
interface CGen {
  sections: StringBuf[];     // CSection enum-indexed
  currentProc: CProc;
  typeCache: TypeCache;       // already-emitted types
  forwTypeCache: TypeCache;   // forward-declared types
  stringPool: StringPool;     // interned string literals
  declaredProcs: NameSet;     // prevents duplicate prototypes
  checkerCtx: CheckerContext;
  labels: number;             // module-scope unique counter
}
```

---

## Type Mapping (MetaScript → C)

| MetaScript | C Type | Semantics |
|-----------|--------|-----------|
| `number` / `float64` | `double` | value |
| `float32` | `float` | value |
| `int32` / `int64` | `int32_t` / `int64_t` | value |
| `uint8`..`uint64` | `uint8_t`..`uint64_t` | value |
| `boolean` | `bool` | value |
| `string` | `msString` | value (RC) |
| `void` / `null` | `void` / `NULL` | -- |
| enum | `typedef int32_t EnumName;` | value |
| interface (value type) | `struct InterfaceName { ... }` | value (copied) |
| class | `ClassName*` | pointer (RC) |
| `Array<number>` | `msNumberArray` | value (RC) |
| `Array<string>` | `msStringArray` | value (RC) |
| `Array<T*>` | `msArray` | value (RC) |
| `Result<T, E>` | `msResult_T_E` struct | value |
| `Function` (closure) | `ms_closure` (`{fn, env}`) | value (RC on env) |
| `Map<K, V>` / `Set<T>` | `msMap` / `msSet` | value (RC) |
| `Ref<T>` / `Ptr<T>` | `T*` | pointer |

**Forward declarations**: Two-tier cache — `forwTypeCache` for `typedef struct Foo Foo;` (breaks cycles), `typeCache` for full struct. Topological emit with cycle detection.

---

## What Codegen Receives

By Phase 5, all complex syntax is already lowered:

| Already Handled | By |
|----------------|----|
| `match` → `if/else` chain | matchLower |
| `defer` → `try/finally` | deferLower |
| `for..of` → `while` + iterator | forOfLower |
| `a?.b` → `a !== null ? a.b : null` | optionalChain |
| `x ?? y` → `x !== null ? x : y` | nullishCoalesce |
| Destructuring → multiple VariableDecl | destructuringLower |
| Arrow with captures → lifted fn + env struct | lambdaLifting |
| Extension methods → direct call | extensionMethodLower |
| All RC ops → explicit `ms_decref(&x)` etc. | analyzer/inject |
| Builtins → plain C-compatible calls | builtinLower |

**Codegen is "dumb"** — just emits what it sees. No dispatch tables, no builtin awareness, no RC interleaving.

---

## Builtin Strategy

### 3-Tier System (Nim-validated)

| Tier | Decorator | Maps To | Nim Equivalent |
|------|-----------|---------|----------------|
| `@builtin("Name")` | Compiler-intercepted inline codegen | `{.magic: "Name".}` |
| `@runtime("c_name")` | C runtime function (unmangled) | `{.importc: "name".}` |
| `extern function` | Raw C FFI | `{.importc.}` + `{.header.}` |

**Checker sees normal signatures** — decorators are opaque metadata. Only `builtinLower` (post-analyzer, C-backend transform) reads them.

### Why builtinLower is Better Than Nim

Nim handles ALL 200+ `TMagic` variants inside codegen (~3200 lines across `ccgexprs.nim`/`ccgcalls.nim`). We move this to a pre-codegen transform:
- **Separation**: transform handles builtin normalization, codegen handles C emission
- **Testable**: AST-to-AST rewrite, tested independently
- **Maintainable**: single file vs scattered 50+ helper functions in codegen
- **Extensible**: new `@runtime` builtins need only a `.ms` file edit, no compiler changes

### Auto-Import (`std/core.ms`)

Like Nim's `system.nim` — compiled first, exports injected into every module's scope. Provides type signatures for globals (console, Result, Promise). Validated: Nim does exactly this via `graph.compileSystemModule()` → `importAllSymbols(systemModule)`.

### Static Extensions (`this typeof Type`)

For types that aren't modules (Promise, Result). The reference compiler already has `is_static_receiver`.

```ms
@runtime("ms_promise_resolve")
export function resolve<T>(this typeof Promise, value: T): Promise<T>;
// Promise.resolve(42) → extensionMethodLower → resolve(42) → builtinLower → ms_promise_resolve(42)
```

**Dispatch strategy**:

| Builtin | Mechanism | Why |
|---------|-----------|-----|
| `Math.floor()` | Module namespace (`import * as Math`) | Math is a natural module |
| `console.log()` | Auto-import + `@builtin` | Global, needs printf codegen |
| `Promise.resolve()` | Static extension (`this typeof`) | Type, not a module |
| `Result.ok()` | Static extension (`this typeof`) | Type, not a module |
| `str.trim()` | Instance extension (`this s: string`) | String method |
| `arr.push()` | Instance extension (`this arr: T[]`) | Array method |

---

## Decorator & Directive Plumbing

Both use `@` syntax. Semicolon disambiguates:
- **Decorator** = `@name(...) decl` → attaches to next declaration, stored on Symbol
- **Directive** = `@name(...);` → standalone with `;`, module-level, stored on Program node

Nim uses same `{. .}` syntax with positional disambiguation (parser context). Haxe has no standalone directives — must attach to a declaration. Our semicolon approach is explicit and simple.

**Symbol fields** (DONE):
- `runtimeName: string` — set by collectPass when `@runtime("c_name")` found
- `builtinKind: string` — set by collectPass when `@builtin("Name")` found

**Parser** (DONE): `@name(args) decl` → `DecoratedDecl { decorators: [MacroInvocation], decoratedNode }`. `@name(args);` → `ExprStmt { MacroInvocation }` (standalone directive).

**Collector** (DONE): `collectDecorated` in collectPass.ms reads decorators, calls `extractDecoratorInfo` (from `decoratorHelpers.ms`, returns primitives only — DRC #22 safe), sets `sym.runtimeName`/`sym.builtinKind`. Note: nested `@dec export function` crashes DRC at collect time (DRC #23) — parse-level works.

---

## Key Codegen Patterns

### Expression Emission

Every emitter takes `(gen: CGen, node: Node, dest: CLoc)`:
- `dest.kind == locNone` → callee fills dest freely
- `dest.kind != locNone` → callee generates assignment to dest

### Temporaries

```ms
function getTemp(proc: CProc, cType: string): CLoc {
  proc.labels += 1;
  const name = "T" + proc.labels + "_";
  emitToLocals(proc, cType + " " + name + ";");
  return { snippet: name, kind: CLocKind.Temp, ... };
}
```

Temps declared in `proc.locals`, used in `proc.stmts` — guarantees valid C89 (declarations before statements).

### Statement Mapping

| MetaScript | C Output |
|-----------|----------|
| `const x = expr;` | `Type x = expr;` (+ DRC ops already in AST) |
| `if/while/do-while` | Direct 1:1 mapping |
| `return expr;` | `return expr;` (DRC cleanup already injected) |
| `try/catch/finally` | `setjmp`/`longjmp` pattern (see below) |
| `throw expr` | `ms_throw(expr);` |

### try/catch via setjmp/longjmp

```c
{
  msSafePoint __sp;
  ms_push_safepoint(&__sp);
  if (setjmp(__sp.context) == 0) {
    // try body
  } else {
    msException* e = ms_curr_exception;
    ms_clear_exception();
    // catch body
  }
  ms_pop_safepoint();
  // finally body
}
```

### Closures

Lambda lifting (Phase 3) already converts to: lifted function + env struct + `ms_closure { .fn, .env }`. Codegen emits env struct in `Types`, lifted function in `Procs`, closure construction at use site.

---

## RC Integration (Minimal)

Phase 4 (Analyzer) already injected all RC calls as explicit AST nodes:
- `=destroy(x)` → `ms_decref(&x)` ExprStmt
- `=copy(x)` → `ms_incref(x)` ExprStmt
- `=wasMoved(x)` → `ms_ptr_was_moved(&x)` ExprStmt
- try/finally wrapping → already in AST

Codegen's `rc.ms` only: (1) recognizes DRC-injected call names, (2) determines `&` vs direct pass based on type. **No interleaving of RC logic in codegen** — massive simplification vs reference compiler (6K+ lines scattered across 40K).

---

## Implementation Order

### Phase 5a: Foundation (~800 lines) — DONE
1. ~~`c/context.ms` — CGen, CProc, CBlock, CLoc, sections, getTemp~~ DONE
2. ~~`c/names.ms` — name mangling, identifier sanitization~~ DONE
3. ~~`c/literals.ms` — string pool, number formatting~~ DONE
4. ~~`c/types.ms` — basic type mapping (primitives, enums, interfaces, classes)~~ DONE

### Phase 5b: Builtin Lowering (~400 lines) — DONE
5. ~~`transform/c/builtinLower.ms` — rewrite builtin MemberExpr/CallExpr to C-compatible AST~~ DONE
6. ~~Symbol field additions — `runtimeName`, `builtinKind` on Symbol interface~~ DONE
7. ~~collectPass decorator reading — extract `@runtime`/`@builtin` args~~ DONE

### Phase 5c: Expressions + Statements (~1200 lines) — DONE
8. ~~`c/expressions.ms` — all expression kinds (returns string snippets, not CLoc — value-type adaptation)~~ DONE
9. ~~`c/statements.ms` — if, while, do-while, block, break, continue, return, throw, try/catch~~ DONE
10. ~~`c/calls.ms` — call emission integrated into expressions.ms (genCallExpr)~~ DONE

### Phase 5d: Declarations (~800 lines) — DONE
11. ~~`c/declarations.ms` — functions, classes, interfaces, enums, exports, globals~~ DONE
12. ~~`c/index.ms` — `generateC()` entry point, section assembly~~ DONE

### Phase 5e: Advanced (~400 lines)
13. ~~try/catch (setjmp/longjmp) — implemented in statements.ms~~ DONE
14. ~~Closure emission (env struct + lifted functions) — closure pair detection, ms_closure literal, closure vs direct call protocol, arrow function lifting, fnDeclNames pre-pass~~ DONE
15. Generic monomorphization — BLOCKED: needs checker-level instantiation registry (substituteType/instantiateGeneric exist but no AST duplication infrastructure yet)

Test at each phase with `msc test`. Each file gets inline tests.

---

## Comparison Summary

| Aspect | Reference (40K lines) | Nim (~11K lines) | Ours (~3-4K lines) |
|--------|----------------------|-------------------|---------------------|
| Architecture | God object, monolith | Modular, section-based | Modular, section-based |
| DRC in codegen | Interleaved (6K+ lines) | Pre-processed | Pre-processed (Phase 4) |
| Builtin dispatch | BuiltinCallKind (5K lines) | TMagic in codegen (3.2K lines) | Pre-codegen transform |
| Type emission | String comparison | Cache + forward decls | Cache + forward decls |
| Expression model | Direct string emit | TLoc carrier | CLoc carrier |
| Proc sections | Single buffer | locals/init/stmts | locals/init/stmts |
| State tracking | 120+ fields + flags | BModule/BProc/TBlock | CGen/CProc/CBlock |
| Tree-shaking | RuntimeFeature bitset | Demand-driven | Demand-driven |
