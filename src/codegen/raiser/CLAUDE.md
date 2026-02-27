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

## Post-Phase-3 NodeKinds (~28 surviving)

These are the only NodeKinds the codegen must handle:

**Literals (5):** NumberLiteral, StringLiteral, BooleanLiteral, NullLiteral, ArrayLiteral

**Expressions (8):** Identifier, BinaryExpr, UnaryExpr, CallExpr, MemberExpr, AssignmentExpr, ObjectExpr, ParenExpr

**Statements (8):** ExprStmt, ReturnStmt, BlockStmt, IfStmt, WhileStmt, BreakStmt, ContinueStmt, ThrowStmt

**Declarations (5):** VariableDecl, FunctionDecl, ClassDecl, InterfaceDecl, EnumDecl

**Module (2):** ImportDecl, ExportDecl

Phase 3 eliminates: MatchExpr → if/else chains, DeferStmt → try/finally, ForStmt/ForOfStmt → WhileStmt, TryExpr → Result + if/else, DestructuringDecl → individual assignments.

## Files

```
src/codegen/raiser/
  CLAUDE.md          -- this file
  index.ms           -- hub: export { generateRaiser } from "./rgen"
  context.ms         -- RaiserCompState, emit helpers, register allocator
  expressions.ms     -- compileExpr: expression nodes → bytecode
  statements.ms      -- compileStmt: statement nodes → bytecode
  rgen.ms            -- generateRaiser(program) → RaiserModule, E2E tests
```

## Current Implementation

### Handled NodeKinds

| NodeKind | File | Opcodes Emitted |
|----------|------|-----------------|
| NumberLiteral | expressions.ms | LoadConst |
| BooleanLiteral | expressions.ms | LoadConst |
| NullLiteral | expressions.ms | LoadConst (nil) |
| BinaryExpr (+,-,*,/,%) | expressions.ms | AddI64, SubI64, MulI64, DivI64, ModI64 |
| UnaryExpr (-) | expressions.ms | NegI64 |
| CallExpr (console.log) | expressions.ms | Print |
| ReturnStmt | statements.ms | Ret |
| ExprStmt | statements.ms | (delegates to compileExpr) |
| BlockStmt | statements.ms | (iterates children) |

### TODO NodeKinds

| NodeKind | Needed Opcodes | Priority |
|----------|---------------|----------|
| VariableDecl | LoadConst, Move, StoreLocal | High |
| Identifier | LoadLocal, Move | High |
| AssignmentExpr | StoreLocal | High |
| IfStmt | Beq/Bne/Bgt/etc + Jump | High |
| WhileStmt | Jump (backward), Bxx | High |
| FunctionDecl | Call, Ret | Medium |
| BreakStmt/ContinueStmt | Jump | Medium |
| StringLiteral | (needs string support) | Later |
| ArrayLiteral | NewArray, LoadIndex, StoreIndex | Later |
| ObjectExpr | NewObject, LoadField, StoreField | Later |
| MemberExpr | LoadField | Later |
| ClassDecl/InterfaceDecl | (struct layout compilation) | Later |
| EnumDecl | (constant folding) | Later |
| ImportDecl/ExportDecl | (multi-module linking) | Later |
| ThrowStmt | (error handling) | Later |

## Architecture

### Compilation Flow

```
generateRaiser(program: Node) → RaiserModule
  ├── createCompState()           -- empty code[], constants[], nextReg=0
  ├── for each statement:
  │     compileStmt(s, stmt)      -- dispatches by NodeKind
  │       └── compileExpr(s, expr) -- recursive, returns register number
  ├── emit Halt if no Ret/Halt at end
  └── makeTestModule(code, constants)
```

### Register Allocation

Linear bump allocator. Each `allocReg(s)` returns `s.nextReg++`. No reuse yet — every subexpression gets a fresh register. VM pre-allocates 256 register slots.

```
compileExpr(2 + 3 * 4):
  R0 = LoadConst 2       (allocReg → 0)
  R1 = LoadConst 3       (allocReg → 1)
  R2 = LoadConst 4       (allocReg → 2)
  R3 = MulI64 R1, R2     (allocReg → 3)
  R4 = AddI64 R0, R3     (allocReg → 4) ← result
```

### Emit Helpers (context.ms)

- `emitInst(s, inst)` — push instruction to code buffer
- `addConst(s, val)` — push constant, return index
- `allocReg(s)` — bump register counter, return index
- `emitLoadConst(s, reg, val)` — addConst + LoadConst ABx
- `emitRet(s, reg)` — Ret ABC
- `emitHalt(s)` — Halt ABC

## Relationship to src/raiser/

```
src/codegen/raiser/         src/raiser/
(Compiler — AST knowledge)  (VM — no AST knowledge)
         │                         │
    generates ──────────→  RaiserModule
    (bytecode.ms types)     (executes bytecode)
                                   │
                            dispatch.c (computed goto)
                            dispatch.h (C FFI header)
                            vm.ms (MetaScript fallback for Print)
```

The codegen imports types from `src/raiser/bytecode`, `src/raiser/value`, `src/raiser/module`. It produces a `RaiserModule` that the VM executes.

## C FFI Pattern (dispatch.c)

The VM uses computed goto dispatch in C for the hot loop:

```ms
// In src/raiser/vm.ms:
@include("dispatch.h")                                    // compiles dispatch.c, adds -I path
import { raiser_dispatch_impl } from "./dispatch.h";      // generates direct unmangled C call
```

Both lines are required: `@include` handles build plumbing, `import from` generates the actual call site.

## Testing

9 E2E tests in rgen.ms: `parseSource(code) → generateRaiser → createContext → load → execute → check`.

```bash
rm -rf out && msc test src/codegen/raiser/rgen.ms
```

Tests cover: return number, return addition, complex arithmetic, negation, console.log, parenthesized expressions, division, modulo.

## Available Opcodes (20 total, from src/raiser/bytecode.ms)

**Memory:** LoadConst (ABx), Move (ABC), LoadNil (ABC)
**i64 Arithmetic:** AddI64, SubI64, MulI64, DivI64, ModI64, NegI64 (all ABC)
**i64 Compare-Branch:** BeqI64, BneI64, BltI64, BleI64, BgtI64, BgeI64 (ABC: if cond skip C)
**Control:** Jump (Ax: signed 24-bit offset), Call, Ret, Halt, Print (all ABC)

Compare-branch semantics: `BgtI64 A B C` — if R[A] > R[B], skip C instructions (ip already incremented).
