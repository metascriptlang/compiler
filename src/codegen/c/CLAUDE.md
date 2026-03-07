# Phase 5: C Code Generation

Emits C source from the post-analyzer AST. Nim-aligned architecture (section-based, modular) — not the reference compiler's 40K-line monolith.

**Pipeline**: `parse → check → transform → analyze → builtinLower → codegen`
**Target**: ~3-4K lines across ~10 files (vs reference's 50K)

---

## CRITICAL: Codegen Is a Thin/Dumb Emitter

**The C codegen layer (`src/codegen/c/`) must be a thin/dumb emitter.** It should only dump what earlier phases (Transform, Checker, Analyzer) have already processed and transformed. It must NOT contain logic that belongs in Transform or earlier phases.

### The Rule

Whenever working on something that ends at C codegen, **first check `~/projects/nim/compiler/`** (especially `ccgexprs.nim`, `ccgstmts.nim`, `ccgtypes.nim`, `transf.nim`, `lambdalifting.nim`, `closureiters.nim`) to see if the equivalent logic lives in an earlier phase (transform, semantic analysis, etc.) rather than codegen. **If Nim handles it before codegen, we should too.**

### Why This Matters — Evidence from 7 Issues (2026-03-04)

Every time we put logic in codegen that belongs earlier, we create bugs that are hard to diagnose and fix:

| Issue | What Went Wrong | Where the Fix Belongs |
|-------|-----------------|-----------------------|
| #7 `stringTruthiness` wrongly applying to booleans | Transform applied string coercion to non-string types | **Transform** (stringTruthiness), NOT codegen |
| #5 String param `*` mismatch | Pointer/value confusion reaching codegen unresolved | **Transform/Checker** — resolve before codegen sees it |
| #3 Function type emitted as `void*` | Type alias not resolved, codegen guessing | **Type resolution** phase, not codegen fallback |
| #1 Result.ok/err not denormalized | JS codegen has helpers but C doesn't; try expressions not hoisted | **Transform** (resultDesugar) should hoist try expressions |
| #6 JS method calls broken | builtinLower desugars for C only, not target-aware | **Transform** (builtinLower) should be target-aware |
| #4 Async env typed as `double` | Transform creates untyped synthetic nodes | **Transform** — Nim transforms pre-check so types are resolved |
| #2 try/catch runtime | Codegen pattern correct, just needs runtime types | Correctly in **codegen** (the exception) |

Only 1 of 7 issues actually belonged in codegen. The other 6 were transform/checker bugs that manifested as codegen failures because codegen was forced to compensate for incomplete earlier phases.

### Checklist Before Adding Codegen Logic

1. Does Nim handle this in `transf.nim`, `lambdalifting.nim`, `closureiters.nim`, or semantic analysis? If yes, put it in our Transform phase.
2. Is this a type resolution issue? If yes, it belongs in the Checker or type resolution pass.
3. Is this a desugaring/lowering? If yes, it belongs in `src/transform/`.
4. Is this pure C syntax emission (mapping an already-resolved AST node to a C string)? Only then does it belong here.

---

## File Structure

```
src/codegen/c/
  index.ms        -- entry: generateC(program, checkerCtx) → string, section assembly
  context.ms      -- CGen, CProc, CBlock, CLoc, CSection enum, getTemp
  types.ms        -- Type → C type mapping, struct/enum emission, forward decls
  expressions.ms  -- Expression emission (includes call emission, argument handling)
  statements.ms   -- if, while, do-while, block, break, continue, return
  declarations.ms -- Function/class/interface/enum declaration emission
  literals.ms     -- String pool, number formatting
  names.ms        -- Name mangling, identifier sanitization
```

---

## Core Data Structures

### CSection (C file output model)

```ms
enum CSection {
  Headers, ForwardDecls, Types, SeqTypes,
  ProcHeaders, StringPool, GlobalVars, Procs,
  DatInit,      // data/type initialization (runs first)
  ModuleInit,   // user top-level code (runs second)
}
```

Each section is a `StringBuf`. Final assembly concatenates in enum order.

### Module Initialization (two-phase)

```
main(argc, argv, env)
  └─ MsMain()
       ├─ MsPreMainInner()        // data init phase
       │    └─ <module>__DatInit000()   // type info, static data
       └─ MsMainInner()           // code init phase
            └─ <module>__Init000()      // user top-level code
            └─ main_()                  // user's main() if defined
```

- Init function names are module-qualified: `mangleModuleName(path) + "__Init000"`
- POSIX main forwards `argc`/`argv`/`env` into `cmdCount`/`cmdLine`/`gEnv` globals
- User-defined `main()` is mangled to `main_()` (C keyword avoidance) and called from MsMainInner
- DatInit runs before Init to ensure data is ready for user code
- `msProgramResult` global is the process exit code (returned from main)
- Multi-module: each module registers its DatInit/Init into the appropriate dispatcher

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
| `Array<number>` | `msNumberArray` | value (RC); mutable params → pointer |
| `Array<string>` | `msStringArray` | value (RC); mutable params → pointer |
| `Array<T*>` | `msArray` | value (RC); mutable params → pointer |
| `Result<T, E>` | `msResult_T_E` struct | value |
| `Function` (closure) | `msClosure` (`{fn, env}`) | value (RC on env) |
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
| All RC ops → explicit `msDecref(&x)` etc. | analyzer/inject |
| Builtins → plain C-compatible calls | builtinLower |
| Generic functions → concrete FunctionDecl nodes | monomorphize |
| Generic types → concrete InterfaceDecl/ClassDecl nodes | monomorphize |

**Codegen is "dumb"** — just emits what it sees. No dispatch tables, no builtin awareness, no RC interleaving, no generic awareness.

---

## Builtin Strategy

### 3-Tier System (Nim-validated)

| Tier | Syntax | Maps To | Nim Equivalent |
|------|--------|---------|----------------|
| `@builtin("Name")` | Compiler-intercepted inline codegen | `{.magic: "Name".}` |
| `extern function ... from "c_name"` | C runtime function (unmangled) | `{.importc: "name".}` |
| `extern function` (no `from`) | Raw C FFI (name = symbol name) | `{.importc.}` + `{.header.}` |

**Checker sees normal signatures.** `extern function ... from` stores `nativeName` on the AST, wired to Symbol by collector. Only `builtinLower` (post-analyzer, C-backend transform) reads `@builtin`.

### Why builtinLower is Better Than Nim

Nim handles ALL 200+ `TMagic` variants inside codegen (~3200 lines across `ccgexprs.nim`/`ccgcalls.nim`). We move this to a pre-codegen transform:
- **Separation**: transform handles builtin normalization, codegen handles C emission
- **Testable**: AST-to-AST rewrite, tested independently
- **Maintainable**: single file vs scattered 50+ helper functions in codegen
- **Extensible**: new `extern function ... from` declarations need only a `.cms` file edit, no compiler changes

### Auto-Import (`std/core.ms`)

Like Nim's `system.nim` — compiled first, exports injected into every module's scope. Provides type signatures for globals (console, Result, Promise). Validated: Nim does exactly this via `graph.compileSystemModule()` → `importAllSymbols(systemModule)`.

### Static Extensions (`this typeof Type`)

For types that aren't modules (Promise, Result). The reference compiler already has `is_static_receiver`.

```ms
extern function resolve<T>(this typeof Promise, value: T): Promise<T> from "ms_promise_resolve";
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
- `nativeName: string` — set by `extern function ... from "c_name"` syntax
- `builtinKind: string` — set by collectPass when `@builtin("Name")` found

**FFI**: `extern function name(...): T from "c_name";` — parser stores `nativeName` on FunctionDeclData, collector wires it to `sym.nativeName`. Codegen reads `sym.nativeName` for C emission.

**Parser** (DONE): `@name(args) decl` → `DecoratedDecl { decorators: [MacroInvocation], decoratedNode }`. `@name(args);` → `ExprStmt { MacroInvocation }` (standalone directive).

**Collector** (DONE): `collectDecorated` in collectPass.ms reads decorators, calls `extractDecoratorInfo` (from `decoratorHelpers.ms`, returns primitives only — DRC #22 safe), sets `sym.nativeName`/`sym.builtinKind`. `collectFunction` also wires `nativeName` from `extern function ... from` AST. Note: nested `@dec export function` crashes DRC at collect time (DRC #23) — parse-level works.

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
| `throw expr` | `msThrow(expr);` |

### try/catch via setjmp/longjmp

```c
{
  msSafePoint __sp;
  msPushSafepoint(&__sp);
  if (setjmp(__sp.context) == 0) {
    // try body
  } else {
    msException* e = msCurrException;
    msClearException();
    // catch body
  }
  msPopSafepoint();
  // finally body
}
```

### Closures

Lambda lifting (Phase 3) already converts to: lifted function + env struct + `msClosure { .fn, .env }`. Codegen emits env struct in `Types`, lifted function in `Procs`, closure construction at use site.

---

## RC Integration (Zero Awareness)

Phase 4 (Analyzer) already injected all RC calls as explicit AST nodes:
- `=destroy(x)` → `msDecref(&x)` ExprStmt
- `=copy(x)` → `msIncref(x)` ExprStmt
- `=wasMoved(x)` → `msPtrWasMoved(&x)` ExprStmt
- try/finally wrapping → already in AST

**Codegen has zero RC awareness.** DRC-injected calls (`msDecref`, `msIncref`, etc.) are regular `CallExpr` nodes — `genCallExpr` in `expressions.ms` emits them identically to any other function call. No special RC file, no call-name recognition, no `&` vs direct pass logic. **Massive simplification vs reference compiler** (6K+ lines of interleaved RC logic scattered across 40K).

---

## Implementation Order

### Phase 5a: Foundation (~800 lines) — DONE
1. ~~`c/context.ms` — CGen, CProc, CBlock, CLoc, sections, getTemp~~ DONE
2. ~~`c/names.ms` — name mangling, identifier sanitization~~ DONE
3. ~~`c/literals.ms` — string pool, number formatting~~ DONE
4. ~~`c/types.ms` — basic type mapping (primitives, enums, interfaces, classes)~~ DONE

### Phase 5b: Builtin Lowering (~400 lines) — DONE
5. ~~`transform/native/builtinLower.ms` — rewrite builtin MemberExpr/CallExpr to C-compatible AST~~ DONE
6. ~~Symbol field additions — `runtimeName`, `builtinKind` on Symbol interface~~ DONE
7. ~~collectPass decorator reading — extract `@builtin` args, `extern from` wiring~~ DONE

### Phase 5c: Expressions + Statements (~1200 lines) — DONE
8. ~~`c/expressions.ms` — all expression kinds (returns string snippets, not CLoc — value-type adaptation)~~ DONE
9. ~~`c/statements.ms` — if, while, do-while, block, break, continue, return, throw, try/catch~~ DONE
10. ~~Call emission — integrated into expressions.ms (genCallExpr)~~ DONE

### Phase 5d: Declarations (~800 lines) — DONE
11. ~~`c/declarations.ms` — functions, classes, interfaces, enums, exports, globals~~ DONE
12. ~~`c/index.ms` — `generateC()` entry point, section assembly~~ DONE

### Phase 5e: Advanced (~400 lines)
13. ~~try/catch (setjmp/longjmp) — implemented in statements.ms~~ DONE
14. ~~Closure emission (env struct + lifted functions) — closure pair detection, msClosure literal, closure vs direct call protocol, arrow function lifting, fnDeclNames pre-pass~~ DONE
15. ~~Generic monomorphization — handled by monomorphize module (Phase 2.5). Codegen receives concrete InterfaceDecl/FunctionDecl nodes — zero generic awareness needed.~~ DONE

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
