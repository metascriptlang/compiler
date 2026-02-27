# Phase 5: Code Generation

Three backends. C is primary (DRC, lifecycle hooks, compile via clang). JS is secondary (no analyzer, direct emission). Raiser is the bytecode backend (no DRC, own VM).

## Backends

| Backend | Directory | Entry Point | Analyzer Required |
|---------|-----------|-------------|-------------------|
| **C** | `c/` | `generateC(program, checkerCtx)` | Yes (Phase 4 DRC) |
| **JS** | `js/` | `generateJS(program)` | No |
| **Raiser** | `raiser/` | `generateRaiser(program)` | No |

## C Backend

See **[c/CLAUDE.md](c/CLAUDE.md)** for full architecture, data structures, builtin strategy, and implementation order.

Pipeline: `parse → check → transform → analyze → builtinLower → generateC`

## JS Backend (Existing)

Working. 10 test groups, covers literals, expressions, statements, declarations, imports/exports, Result denormalization.

Pipeline: `parse → check → transform → generateJS`

Files: `js/emit.ms` (StringBuf, JSGenerator), `js/expressions.ms`, `js/statements.ms`, `js/declarations.ms`, `js/jsgen.ms` (dispatcher + tests).

## Raiser Backend (Bytecode)

See **[raiser/CLAUDE.md](raiser/CLAUDE.md)** for full architecture, NodeKind coverage, and opcode mapping.

Pipeline: `parse → check → transform → generateRaiser → Raiser VM`

Skips Phase 4 (DRC) entirely — the Raiser VM has its own memory model. Compiles post-Phase-3 AST (~28 NodeKinds) to 20 bytecode opcodes. VM executes via computed goto dispatch in C (`src/raiser/dispatch.c`).

Files: `raiser/context.ms` (compiler state, emit helpers), `raiser/expressions.ms`, `raiser/statements.ms`, `raiser/rgen.ms` (generator + 9 E2E tests), `raiser/index.ms` (hub).
