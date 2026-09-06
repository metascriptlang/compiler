# Project Structure

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
  utils/   string.ms                -- string utilities (no indexOf/includes)
  diagnostics/ diagnostics.ms       -- error formatting
```

## Architecture Patterns

### Self-hosted execution
The compiler is a native binary (`msc`) built by the previous generation of
itself. It reads target `.ms`/`.cms` files as **raw strings** and parses them
with its own MetaScript parser. When debugging parse errors on target files
(e.g. prelude `.cms` files), the issue is always in our parser (`src/parser/`).

### Hub re-exports
Each module directory has `index.ms` that re-exports the public API. Import
directly or from the hub.

### Callback injection (circular import breaker)
`callbacks.ms` holds function pointers. `core.ms` registers real
implementations at module load. Sub-parsers import from `callbacks.ms` only —
no cycles.

### Flat Type interface (not discriminated union)
Avoids codegen bugs with self-referencing anonymous structs. All fields
present; unused fields empty/null. Fields: `kind`, `typeName`, `typeNames`,
`typeChildren`, `typeReturn`, `typeExtra`, `typeFlags`.

### Named-field AST (not sons[] array)
The standard reference uses a generic `sons: seq[PNode]` array with index
constants (`namePos = 0`, `paramsPos = 3`, `bodyPos = 6`). We use **named
fields in a discriminated union** (`NodeData`) with typed aliases
(`FunctionDeclData.fnReturnType`, `VariableDeclData.declType`). Intentional:

- **Self-documenting**: `d.fnReturnType` is clearer than `n.sons[3].sons[0]`
- **Type-safe**: each variant has exactly the fields it needs — no off-by-one
  index bugs
- **No capability loss**: everything the standard reference compiler can do,
  we can do with named fields

The tradeoff is that adding new fields to NodeData requires updating all
construction sites, while `sons[]` allows appending freely. We accept this
cost for the safety and clarity benefits.

**Type annotations as strings**: type annotations (`declType`,
`fnReturnType`, etc.) are stored as strings for simplicity. Positioned type
AST is stored separately via `Node.typeExpr` for LSP symbol recording — the
string path handles type resolution, the Node path handles position tracking.
This avoids modifying all 18 NodeData type-annotation fields.
