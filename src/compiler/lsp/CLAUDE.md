# MetaScript Self-Hosted LSP Module

Thin Language Server Protocol adapter. Intelligence lives in the compiler (`src/checker/suggest.ms`), not here. Inspired by the reference language server (~2,500 lines) over other common implementations (~13,000 lines).

**Target**: ~1,400 lines total (suggest.ms ~500 + lsp/ ~900).

---

## 1. Architecture: Dumb LSP, Smart Compiler

The LSP module (`src/compiler/lsp/`) is a **dumb transport layer**. It handles:
- JSON-RPC framing and parsing (`protocol.ms`)
- Socket I/O and message routing (`server.ms`)
- LSP command mapping (`handlers.ms`)

It NEVER:
- Manages symbol tables
- Performs type checking
- Walks the AST

**Why suggest.ms lives in checker/**: It needs `lookupSymbol`, `Scope` chains, `Type` fields, `ExportRegistry`, `ExtensionRegistry`. Putting it in `lsp/` would create an upward dependency violation. Same pattern as `orchestrator.ms` and `checkExprPass.ms`.

**Why the LSP is thin**: The reference implementation avoids reimplementing compiler logic in the LSP. We follow that proven pattern.

## 2. suggest.ms API

The compiler exports a single query function for all IDE features:

```ms
function suggest(pos: Position, ctx: CheckerContext): SuggestResult;
```

`SuggestResult` is a union that covers:
- `Completions` (member access, scope lookup)
- `Definitions` (goto definition)
- `TypeDefinition`
- `References`
- `Hover` (type formatting)
- `SignatureHelp`
- `Diagnostics` (current module errors)

---

## Reference Cross-Reference

| Self-Hosted | Reference LSP | Industry Standard |
|------------|--------------|-----|
| `suggest.ms` | `server.zig:594-967` | `suggest.ms` equivalent |
| `protocol.ms` | `jsonrpc.zig` | `sexp.ms` equivalent |
| `server.ms` | `server.zig` | `server.ms` equivalent |
| `handlers.ms` | (embedded) | (embedded) |
