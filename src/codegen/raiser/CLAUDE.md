# Raiser Codegen — AST → Bytecode Compiler

Compiles post-Phase-3 AST into Raiser bytecode. Parser/AST knowledge lives here; the VM (`src/raiser/`) knows nothing about AST nodes.

## Pipeline Position

```
Source.ms → [1 Parse] → [2 Check] → [3 Transform] → Raiser Codegen → Raiser VM
                                          ↓
                                   Phase 3 eliminates:
                                   MatchExpr/Stmt, DeferStmt, TryExpr,
                                   ForStmt, ForOfStmt, DestructuringDecl,
                                   AwaitExpr, closures with captures
```

Raiser skips Phase 4 (DRC analyzer) and Phase 5 (C/JS codegen). No ORC, no refcounting — the VM uses its own memory model.

## Files

```
src/codegen/raiser/
  CLAUDE.md          -- this file
  index.ms           -- hub: export { generateRaiser } from "./rgen"
  context.ms         -- RaiserCompState, emit helpers, register allocator, loop/scope state
  expressions.ms     -- compileExpr: expression nodes → bytecode
  statements.ms      -- compileStmt: statement nodes → bytecode
  rgen.ms            -- generateRaiser(program), generateRaiserProject(modules), class compilation, tests
  eval.ms            -- evalSourceFull/evalASTFull (full pipeline), project + class integration tests
```

## Handled NodeKinds

### Expressions (expressions.ms)

| NodeKind | Opcodes Emitted |
|----------|----------------|
| NumberLiteral | LoadConst |
| StringLiteral | LoadConst (string value) |
| BooleanLiteral | LoadConst |
| NullLiteral | LoadConst (nil) |
| Identifier | Move (from local register) |
| BinaryExpr (+,-,*,/,%,==,!=,<,<=,>,>=,&&,\|\|,&,\|,^,<<,>>) | AddI64/SubI64/MulI64/DivI64/ModI64 + compare-branch + BitAnd/BitOr/BitXor/ShiftLeft/ShiftRight |
| UnaryExpr (-,!,~) | NegI64, BitNot |
| CallExpr | Call/CallIndirect/Print (dispatch by callee kind) |
| ConditionalExpr (ternary) | BranchIfFalsy + Jump |
| AssignmentExpr (=,+=,-=,*=,/=,%=,&=,\|=,^=,<<=,>>=) | StoreLocal/StoreField/StoreIndex + arithmetic |
| UpdateExpr (++/--) | AddI64/SubI64 with LoadConst(1) |
| ArrayLiteral | NewArray + element compilation |
| ArrayAccess | LoadIndex / StoreIndex |
| MemberExpr | LoadField / StoreField |
| ObjectLiteral | NewObject + StoreField per property |
| TypeAssertion (as) | (compiles inner expression, no-op cast) |
| MoveExpr | (compiles inner expression) |
| ParenExpr | (compiles inner expression) |

### Statements (statements.ms)

| NodeKind | Opcodes Emitted |
|----------|----------------|
| ReturnStmt | Ret |
| ExprStmt | (delegates to compileExpr) |
| BlockStmt | (iterates children, scoped locals) |
| VariableDecl | LoadConst/compileExpr + declareLocal |
| IfStmt | BranchIfFalsy + Jump (with else patching) |
| WhileStmt | BranchIfFalsy + Jump (backward loop) |
| DoWhileStmt | BranchIfFalsy + Jump (body-first loop) |
| ForStmt | init + BranchIfFalsy + body + update + Jump |
| ForOfStmt | ArrayLen + BltI64 + LoadIndex iteration |
| BreakStmt | Jump (patched to loop exit) |
| ContinueStmt | Jump (backward to loop start) |
| FunctionDecl | (handled by rgen.ms two-phase compilation) |
| ClassDecl | (handled by rgen.ms two-phase compilation) |
| ExportDecl | (unwraps inner declaration or compiles as halt) |
| DecoratedDecl | (unwraps inner declaration) |
| ImportDecl | (resolves builtin names into function registry) |
| EnumDecl / InterfaceDecl / TypeAliasDecl | (compile-time only, skipped) |

### Declarations (rgen.ms two-phase)

| NodeKind | Compilation |
|----------|-------------|
| FunctionDecl | Phase 1: collect name→funcIdx. Phase 2: compileFuncBody → RaiserFunction |
| ClassDecl | Phase 1b: collect methods + ctor→funcIdx. Phase 2b: methods via compileFuncBody (this as R0), ctor via compileClassConstructor (NewObject + StoreField props/methods + body + Ret this) |
| EnumDecl | Phase 1: collect member names→values in globalEnumMap |

### Remaining TODO

| NodeKind | Notes |
|----------|-------|
| ThrowStmt | Error handling not yet in VM |
| ClassDecl (extends) | Inheritance deferred |
| ClassDecl (static) | Static methods/properties deferred |
| ClassDecl (get/set) | Getter/setter deferred |

## Architecture

### Compilation Flow (project)

```
generateRaiserProject(modules: RaiserModuleInput[]) → RaiserModule
  ├── Pass 1a: Collect functions + enums (all modules)
  │     funcIdx assigned in order: functions across all modules
  ├── Pass 1b: Collect classes (all modules)
  │     methods first, then constructor per class
  ├── Register builtins (defineConfig, etc.)
  ├── Pass 2: Compile function bodies → functions[]
  ├── Pass 2b: Compile class methods + constructors → functions[]
  ├── Emit builtin stubs → functions[]
  ├── Pass 3: Compile init functions (top-level code per module)
  │     Dependencies init first, entry module last
  └── Assemble RaiserModule(functions, initIndices, ...)
```

**Critical invariant**: Pass 1a/1b collection order MUST match Pass 2/2b compilation order. Functions are collected/compiled first (across all modules), then classes. Interleaving would cause funcIdx mismatch.

### Function Value Calling Convention

Function references stored in variables are wrapped as closure pairs `{ fn: funcIdx, env: -1 }` (sentinel -1 = no env). This enables uniform calling: `compileClosureCall` extracts `fn`/`env`, then runtime-branches on `env == -1` to either pass env as first arg (capturing closure) or skip it (non-capturing). Expression-level function identifiers (e.g., inside `{ fn: myFunc, env: ... }`) remain raw integers.

Expression-body functions (e.g., lifted arrows `(x) => x * 2`): detected in `compileFuncBody` — if body is not a statement kind, compiled as `compileExpr + emitRet`.

### Class Compilation — Methods as Closures

Methods compile as top-level functions with `this` as first parameter. Constructor creates object, sets default properties, stores method closures `{ fn: funcIdx, env: this }`, runs ctor body, returns `this`. Method calls flow through existing `CallIndirect` path via `LoadField`.

```
Point_new(x, y):
  R_this = NewObject
  StoreField(R_this, "x", nil)          ← default property
  StoreField(R_this, "getX", closure)   ← { fn: getX_idx, env: R_this }
  <compile ctor body>                   ← this.x = x; etc.
  Ret R_this

Point_getX(this):                       ← this is R0
  LoadField(R0, "x") → Ret
```

### Register Allocation

Linear bump allocator. `allocReg(s)` returns `s.nextReg++`. `resetTemps(s)` after each top-level statement resets `s.nextReg = s.locals.items.length` (preserves locals, reclaims temps). VM pre-allocates 256 register slots per frame.

### Emit Helpers (context.ms)

- `emitInst(s, inst)` — push instruction to code buffer
- `addConst(s, val)` — push constant, return index
- `allocReg(s)` — bump register counter, return index
- `emitLoadConst(s, reg, val)` — addConst + LoadConst ABx
- `emitRet(s, reg)` / `emitHalt(s)` — control flow
- `emitBranchIfFalsy(s, reg)` — BeqI64 R,zero + Jump placeholder
- `emitJumpPlaceholder(s)` / `patchJumpTo(s, idx, target)` — forward jump patching
- `pushLoop(s, startIp)` / `popLoop(s)` / `currentLoop(s)` — loop state for break/continue
- `declareLocal(s, name, reg)` / `resolveLocal(s, name)` — scope-based variable binding
- `registerFunc(s, name, idx)` / `resolveFunc(s, name)` — function resolution
- `declareEnum(s, name, val)` — enum member binding
- `registerBuiltin(s, name, idx)` / `resolveBuiltin(s, name)` — builtin function binding

## Relationship to src/raiser/

```
src/codegen/raiser/         src/raiser/
(Compiler — AST knowledge)  (VM — no AST knowledge)
         │                         │
    generates ──────────→  RaiserModule
    (bytecode.ms types)     (executes bytecode)
                                   │
                            vmDispatch.c (computed goto)
                            dispatch.h (C FFI header)
                            vm.ms (MetaScript fallback for objects/strings/calls)
```

The codegen imports types from `src/raiser/bytecode`, `src/raiser/value`, `src/raiser/module`. It produces a `RaiserModule` that the VM executes.

## Available Opcodes (52 total, from src/raiser/bytecode.ms)

**Memory (3):** LoadConst (ABx), Move (ABC), LoadNil (ABC)
**i64 Arithmetic (6):** AddI64, SubI64, MulI64, DivI64, ModI64, NegI64 (all ABC)
**i64 Compare-Branch (6):** BeqI64, BneI64, BltI64, BleI64, BgtI64, BgeI64 (ABC: if cond skip C)
**Control (5):** Jump (Ax: signed 24-bit), Call, Ret, Halt, Print (all ABC)
**Array (5):** NewArray, LoadIndex, StoreIndex, ArrayLen, ArrayPush (all ABC)
**Object (3):** NewObject, LoadField, StoreField (all ABC)
**String (6):** ConcatStr, EqStr, NeStr, StrLen, StrCharAt, StrSlice (all ABC)
**Indirect Call (1):** CallIndirect (ABC: func index from register)
**f64 Arithmetic (5):** AddF64, SubF64, MulF64, DivF64, NegF64 (all ABC)
**f64 Compare-Branch (6):** BeqF64, BneF64, BltF64, BleF64, BgtF64, BgeF64 (all ABC)
**Bitwise (6):** BitAnd, BitOr, BitXor, BitNot, ShiftLeft, ShiftRight (all ABC)

Compare-branch semantics: `BgtI64 A B C` — if R[A] > R[B], skip C instructions (ip already incremented).

## Testing

687 tests in rgen.ms across 27 test groups. 1272 tests in eval.ms (full pipeline + project + Phase 3 transforms).

```bash
# Codegen-only tests (parse → codegen → VM, no checker/transforms)
msc test src/codegen/raiser/rgen.ms

# Full-pipeline tests (parse → check → transform → codegen → VM)
msc test src/codegen/raiser/eval.ms
```

eval.ms uses `jsBackend=false` in `transformProgram` to enable all general transforms (lambdaLifting, tailCallLower, stringConcatFlatten, etc.). This means lifted arrows and other Phase 3 features are tested end-to-end.

Test groups: codegen basics, variables, comparisons, if-else, while, do-while, for-loops, functions, strings, string ops, string methods, logical, complex programs, ternary, update expressions, export unwrap, arrays, objects, compound assignments, compound assign targets, enums, closures, build.ms, bitwise, classes (31 tests), Phase 3 match/basics/tail-call/arrow (10 tests), project (14 tests), project classes (4 tests).
