# MetaScript Self-Hosted Compiler

Self-hosted compiler for the MetaScript language, written in MetaScript (.ms files). Targets C and JavaScript backends (Erlang postponed).

## Build Commands

```bash
# Run all tests (ALWAYS rm out/ first — stale artifacts cause false passes)
rm -rf out && msc test src/index.ms

# Run without tests
msc run src/index.ms

# Rebuild reference compiler (ALWAYS rm .zig-cache when changing shared sources)
cd ~/projects/metascript && rm -rf .zig-cache && zig build install
```

## Pipeline

```
Source.ms --> [1 Parse] --> [2 TypeCheck] --> [3 Transform] --> [4 DRC] --> [5 Codegen] --> output
```

- Phase 1 (Parse): COMPLETE -- 37 NodeKind, 80+ TokenKind, recursive descent + Pratt precedence
- Phase 2 (TypeCheck): COMPLETE single-module -- 3-pass (collect, resolve, check). Cross-module deferred.
- Phases 3-5: NEXT -- transforms, DRC injection, codegen

## Project Structure

```
src/
  index.ms                          -- entry point + smoke tests
  ast/     node.ms                  -- NodeKind(37), NodeData, Node, 50+ type aliases
           printer.ms               -- debug printer (exhaustive match)
  lexer/   token.ms                 -- TokenKind(80+), identToKeyword
           scanner.ms               -- core lexer (char scanning)
           lexer.ms                 -- lex() main function
           state.ms / chars.ms      -- lexer state machine, char classification
  parser/  context.ms               -- ParserState, peek, advance
           typeAnnotation.ms        -- type annotation parser
           expressions/core.ms      -- parseExpression (Pratt precedence)
           expressions/call.ms      -- call, member access, array access
           expressions/arrow.ms     -- arrow functions
           expressions/object.ms    -- object/array literals
           expressions/match.ms     -- match expressions
           statements/core.ms       -- parseProgram, parseBlock, parseStatement
           statements/declaration.ms -- functions, classes, interfaces, enums, imports
           statements/control.ms    -- loops, break, continue, switch
           statements/errorHandling.ms -- try/catch/finally, throw
           statements/callbacks.ms  -- callback injection (breaks circular imports)
  checker/ types.ms                 -- TypeKind(27), flat Type interface, constructors
           symbol.ms                -- SymbolTable, Scope chain, Symbol
           context.ms               -- CheckerContext, error collection
           collectPass.ms           -- Pass 1: collect declarations
           resolvePass.ms           -- Pass 2: resolve type annotations
           checkPass.ms             -- Pass 3: type inference + validation
           compat.ms                -- type compatibility (isAssignable)
  utils/   string.ms                -- DRC-safe string utilities (no indexOf/includes)
  diagnostics/ diagnostics.ms       -- error formatting
```

## Architecture Patterns

### Hub re-exports
Each module directory has `index.ms` that re-exports the public API. Import directly or from hub.

### Callback injection (circular import breaker)
`callbacks.ms` holds function pointers. `core.ms` registers real implementations at module load.
Sub-parsers import from `callbacks.ms` only -- no cycles.

### Flat Type interface (not discriminated union)
Avoids DRC codegen bugs with self-referencing anonymous structs. All fields present; unused fields empty/null.
Fields: `kind`, `typeName`, `typeNames`, `typeChildren`, `typeReturn`, `typeExtra`, `typeFlags`.

### Testing
Each .ms file has inline tests via `testGroup` + `test` + `check` from `std/testing`. 93 test groups across 24 files.

## DRC Gotchas (Reference Compiler Bugs Affecting All .ms Code)

These are NOT design choices -- they are codegen bugs you MUST work around:

1. **NEVER** `let x; x = try f();` -- DRC destroys the intermediate Result, use-after-free. Use `const x = try f();`
2. **NEVER** pass `makeSymbol(...)` or fresh interface as function arg -- DRC double-frees. Store in local `const` first, or create inside the callee.
3. **ALWAYS** use `const x = try f();` with immediate use in the return expression.
4. **string[] is VALUE TYPE** -- `push()` inside functions does not propagate to caller. Inline loops or wrap in interface.
5. **try inside match arms** -- emits `/* unsupported: try_expr */`. Avoid.
6. **break/continue in match arms** -- targets the switch, not the enclosing loop.
7. **Standalone `try f();` in while loop** -- DRC scope bug, all outer variables become undeclared. Use `advance()` instead.
8. **No indexOf/includes** -- use `slice`, `length`, `findChar`, `charAt` from `utils/string.ms`.
9. **`type` is reserved** -- use `tokenType`, `nodeType`, etc.
10. **Circular imports silently drop** -- keep mutually recursive functions in the same file.

## Match Expression Rules

- String/number/enum literals as patterns: WORKS
- Block arms with side effects: WORKS (`return match (x) { p => { sideEffect(); value } }`)
- `"a".code` in patterns: WORKS
- `try` in match arms: FAILS
- Bare identifiers in patterns are always BINDINGS (not value comparison)
- `|` for alternatives: `1 | 2 | 3 => ...`

## Reference Compiler Locations

- `/Users/le/projects/metascript/` -- Zig-based reference compiler
  - `src/codegen/c/cgen.zig`, `src/transform/drc_inject.zig`, `src/transform/pipeline.zig`
- `/Users/le/projects/nim/compiler/` -- Nim reference
  - `transf.nim`, `lambdalifting.nim`, `injectdestructors.nim`

## Backends

- **C**: Primary. DRC memory management, lifecycle hooks, compile via clang. Phase 4 (DRC) required.
- **JavaScript**: Secondary. No DRC needed, direct JS emission. Simpler codegen path.
- **Erlang**: POSTPONED.

## Next Phase: Transforms (Phase 3)

Priority order: `result_desugar`, `match_lower`, `defer_lower`, `for_of_lower`, `optional_chain`, `nullish_coalesce`, `type_coercion`, `lambda_lifting`, `liftdestructors`.
Simple fixed-order runner first, pluggable pipeline later.
