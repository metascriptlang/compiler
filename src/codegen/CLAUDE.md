# Phase 5: Code Generation

Two backends. C is primary (DRC, lifecycle hooks, compile via clang). JS is secondary (no analyzer, direct emission).

## Backends

| Backend | Directory | Entry Point | Analyzer Required |
|---------|-----------|-------------|-------------------|
| **C** | `c/` | `generateC(program, checkerCtx)` | Yes (Phase 4 DRC) |
| **JS** | `js/` | `generateJS(program)` | No |

## C Backend

See **[c/CLAUDE.md](c/CLAUDE.md)** for full architecture, data structures, builtin strategy, and implementation order.

Pipeline: `parse → check → transform → analyze → builtinLower → generateC`

## JS Backend (Existing)

Working. 10 test groups, covers literals, expressions, statements, declarations, imports/exports, Result denormalization.

Pipeline: `parse → check → transform → generateJS`

Files: `js/emit.ms` (StringBuf, JSGenerator), `js/expressions.ms`, `js/statements.ms`, `js/declarations.ms`, `js/jsgen.ms` (dispatcher + tests).
