# MetaScript Self-Hosted LSP Module

Thin Language Server Protocol adapter. Intelligence lives in the compiler (`src/checker/suggest.ms`), not here. Inspired by Nim's nimsuggest (~2,500 lines) over the reference LSP (~13,000 lines).

**Target**: ~1,400 lines total (suggest.ms ~500 + lsp/ ~900).

## 1. Architecture

```
  Editor (VS Code / Neovim / etc.)
      |
      |  JSON-RPC over stdin/stdout
      v
  +-----------------------------+
  | src/lsp/                    |  Thin protocol adapter (~900 lines)
  |   server.ms    ~300 lines   |  Main loop, document store, diagnostics
  |   protocol.ms  ~200 lines   |  JSON-RPC framing, JSON helpers
  |   handlers.ms  ~350 lines   |  Per-method dispatch, format responses
  |   index.ms      ~50 lines   |  Hub re-exports
  +-----------------------------+
      |
      |  function calls (no protocol knowledge)
      v
  +-----------------------------+
  | src/checker/suggest.ms ~500 |  Intelligence IN the compiler
  |                             |
  |  findNodeAtPosition()       |  AST walk -> node at cursor
  |  typeToString()             |  Type -> human-readable string
  |  getSymbolAtCursor()        |  Node + symbol resolution
  |  getCompletionCandidates()  |  Scope walk, filter, sort
  |  formatHover()              |  Markdown hover info
  |  collectSymbolsInFile()     |  Document outline
  |  formatSignature()          |  Signature help
  +-----------------------------+
      |
      |  uses existing compiler infrastructure
      v
  +---------------------------------------------------------------+
  | checker/types.ms   -- TypeKind(27), Type, typeNameOf()        |
  | checker/symbol.ms  -- SymbolTable, Scope chain, lookupSymbol  |
  | checker/context.ms -- CheckerContext, ExportRegistry          |
  | parser/            -- parseSource()                           |
  | ast/node.ms        -- Node, NodeKind(37+), SourceLocation     |
  +---------------------------------------------------------------+
```

**Why suggest.ms lives in checker/**: It needs `lookupSymbol`, `Scope` chains, `Type` fields, `ExportRegistry`, `ExtensionRegistry`. Putting it in `lsp/` would create an upward dependency violation. Same pattern as `orchestrator.ms` and `checkExprPass.ms`.

**Why the LSP is thin**: The reference server.zig has 374 lines of type formatting, 1800 lines for completion, 1800 for hover -- all reimplementing compiler logic. Nim avoids this: `suggest.nim` (986 lines) exports 4 functions, `nimsuggest.nim` (1,406 lines) is just a socket multiplexer. We follow Nim.

## 2. suggest.ms API

### Data Types

```ms
export interface SgSuggest {
    name: string;
    kind: SymbolKind;
    symType: Type;
    location: SourceLocation;
    modulePath: string;
    isExported: boolean;
    docComment: string;        // empty if none
}

export enum SgCompletionKind {
    Identifier,      // bare identifier
    MemberAccess,    // after "."
    Import,          // inside import { } from "..."
    TypeAnnotation,  // after ":"
}

export interface SgFileSymbols {
    names: string[];
    kinds: SymbolKind[];
    locations: SourceLocation[];
}
```

### Core Functions

| Function | Input | Output | What it does |
|----------|-------|--------|-------------|
| `findNodeAtPosition(program, line, col)` | AST + cursor | Node or null | Walk AST depth-first, find innermost node at cursor |
| `typeToString(t)` | Type | string | Full recursive formatting: `(a: number) => boolean`, `Result<T, E>`, `T[]` |
| `getSymbolAtCursor(ctx, program, line, col)` | CheckerContext + AST + cursor | SgSuggest or null | findNode + resolve symbol (Identifier/MemberExpr/CallExpr) |
| `getCompletionCandidates(ctx, kind, prefix, objectType)` | Context + completion kind | SgSuggest[] | Walk scope chain, filter by prefix, sort by relevance |
| `formatHover(suggest)` | SgSuggest | string | Markdown code block with type info |
| `collectSymbolsInFile(ctx, program)` | Context + AST | SgFileSymbols | All top-level declarations for document outline |
| `formatSignature(sym)` | Symbol | string[] | Function signature(s) for signature help (handles overloads) |
| `detectCompletionContext(source, line, col)` | Raw text + cursor | SgCompletionKind | Scan backwards: "." = MemberAccess, ":" = TypeAnnotation, etc. |

### Data Sources

| Function | Reads from |
|----------|-----------|
| `findNodeAtPosition` | `ProgramData.programStmts`, recursive walk through NodeData children |
| `typeToString` | `Type.kind`, `.typeName`, `.typeNames`, `.typeChildren`, `.typeReturn`, `.typeExtra` |
| `getSymbolAtCursor` | `lookupSymbol(ctx.table, name)`, `getProperty(type, name)` |
| `getCompletionCandidates` | `ctx.table.current` scope chain, `ctx.extensionRegistry`, `ctx.exportRegistry` |
| `collectSymbolsInFile` | `ProgramData.programStmts` top-level iteration |
| `detectCompletionContext` | Raw source string character scanning (no AST) |

## 3. LSP Module Files

### protocol.ms (~200 lines)

JSON-RPC framing. No LSP semantics.

```ms
// Read Content-Length header + JSON payload from stdin
export function readMessage(input: string, startPos: number, out bytesRead: number): Result<string, string>

// Write "Content-Length: N\r\n\r\n" + JSON to stdout
export function writeMessage(content: string): void

// JSON building helpers (no JSON library -- hand-built strings)
export function jsonString(val: string): string     // escape + quote
export function jsonNumber(val: number): string
export function jsonBool(val: boolean): string
export function jsonNull(): string
export function jsonArray(items: string[]): string

// JSON field extraction (predictable LSP structure -- no full parser)
export function getJsonField(json: string, field: string): string
export function getJsonNumber(json: string, field: string): number
export function getJsonObject(json: string, field: string): string
```

### handlers.ms (~350 lines)

One function per LSP method. Extract params, call suggest.ms, format response.

```ms
export interface LspResponse {
    id: string;
    body: string;
    isError: boolean;
}

// Lifecycle
export function handleInitialize(id: string, params: string): LspResponse
export function handleShutdown(id: string): LspResponse

// Document sync (notifications -- no response, trigger diagnostics)
export function handleDidOpen(params: string, out diagUri: string, out diagJson: string): void
export function handleDidChange(params: string, out diagUri: string, out diagJson: string): void
export function handleDidClose(params: string): void

// Requests
export function handleHover(id: string, params: string): LspResponse
export function handleCompletion(id: string, params: string): LspResponse
export function handleDefinition(id: string, params: string): LspResponse
export function handleDocumentSymbol(id: string, params: string): LspResponse
export function handleSignatureHelp(id: string, params: string): LspResponse
```

**Every handler follows the same pattern:**
1. Extract params from JSON (uri, line, character)
2. Look up source in document store
3. `parseSource(source)` + `checkSource(source)` -> CheckerContext + AST
4. Call suggest.ms function(s)
5. Format result as JSON
6. Return `LspResponse`

### server.ms (~300 lines)

Main loop + document store.

```ms
export interface LspDocument {
    uri: string;
    source: string;
    version: number;
}

export interface LspDocumentStore {
    documents: LspDocument[];
}

export interface LspServerState {
    initialized: boolean;
    shutdownRequested: boolean;
    documents: LspDocumentStore;
}

export function runServer(): void             // main loop: read -> dispatch -> write
export function compileForLsp(source: string): CheckerContext  // parse + 3-pass check
export function generateDiagnostics(uri: string, source: string): string
export function uriToPath(uri: string): string   // "file:///a/b.ms" -> "/a/b.ms"
export function pathToUri(path: string): string   // "/a/b.ms" -> "file:///a/b.ms"
```

### index.ms (~50 lines)

Hub. Re-exports `runServer` and public types.

## 4. Handler Mapping

| LSP Method | Handler | suggest.ms call | Returns |
|------------|---------|----------------|---------|
| `initialize` | `handleInitialize` | -- | Server capabilities |
| `shutdown` | `handleShutdown` | -- | `null` |
| `textDocument/didOpen` | `handleDidOpen` | -- | Diagnostics notification |
| `textDocument/didChange` | `handleDidChange` | -- | Diagnostics notification |
| `textDocument/didClose` | `handleDidClose` | -- | -- |
| `textDocument/hover` | `handleHover` | `getSymbolAtCursor` + `formatHover` | Hover markdown |
| `textDocument/completion` | `handleCompletion` | `detectCompletionContext` + `getCompletionCandidates` | CompletionItem[] |
| `textDocument/definition` | `handleDefinition` | `getSymbolAtCursor` | Location |
| `textDocument/documentSymbol` | `handleDocumentSymbol` | `collectSymbolsInFile` | DocumentSymbol[] |
| `textDocument/signatureHelp` | `handleSignatureHelp` | `getSymbolAtCursor` + `formatSignature` | SignatureInfo[] |

## 5. Trans-Am Integration

suggest.ms is Trans-Am-agnostic. It takes `CheckerContext` + `Node`, regardless of source.

### Phase 1: Without Trans-Am (initial)

```
didChange -> store source in LspDocumentStore
hover     -> parseSource(text) -> checkSource(text) -> suggest query -> format
```

Re-parses/re-checks every request. Acceptable for single-file (~2ms per check).

### Phase 2: With Trans-Am (future)

```
didChange -> transam.setFileText(path, text)         // input query
hover     -> transam.executeQuery(Symbols, path)      // cached
          -> suggest query using cached CheckerContext
```

Only `server.ms` changes (swap `compileForLsp` for Trans-Am queries). suggest.ms and handlers stay identical.

| Trans-Am Query | LSP Usage |
|---------------|-----------|
| `file_text(path)` | Set by didOpen/didChange |
| `parse(path)` | Depends on file_text, returns AST |
| `symbols(path)` | Depends on parse, returns CheckerContext |
| `diagnostics(path)` | Depends on symbols, returns errors |

## 6. Diagnostics Flow

Pushed as notifications via `textDocument/publishDiagnostics`.

**Triggers**: didOpen, didChange (publish errors), didClose (publish empty = clear).

**Error sources**:

| Source | Severity |
|--------|----------|
| Lexer | Error (1) |
| Parser | Error (1) |
| Checker | Error (1) or Warning (2) |

**SourceLocation to LSP Range**: Compiler is 1-indexed lines, LSP is 0-indexed. `{ line: loc.line - 1, character: loc.column }`. End position: heuristic `column + name.length`.

**Enhancement needed**: `addError(ctx, msg)` currently stores `string[]`. For LSP, need location attached. Add `LspDiagnostic { message, location, severity }` to CheckerContext.

## 7. Server Capabilities

```json
{
  "capabilities": {
    "textDocumentSync": { "openClose": true, "change": 1 },
    "hoverProvider": true,
    "completionProvider": { "triggerCharacters": [".", "\""] },
    "definitionProvider": true,
    "documentSymbolProvider": true,
    "signatureHelpProvider": { "triggerCharacters": ["(", ","] }
  }
}
```

`change: 1` = full sync (entire document on every change). Incremental sync deferred.

## 8. What We Keep from Reference

| Pattern | Ref Location | Why |
|---------|-------------|-----|
| URI-to-path conversion | `server.zig:uriToPath` | Essential. `file:///` prefix strip. |
| Content-Length framing | `jsonrpc.zig` | Core protocol. Direct port. |
| Error code constants | `jsonrpc.zig:ErrorCode` | LSP spec-mandated (-32700 to -32801). |
| Completion trigger chars | `server.zig` | `[".", "\""]` -- dot + quote. |
| Signature help triggers | `server.zig` | `["(", ","]` -- paren + comma. |
| SymbolKind mappings | `server.zig` | Function→3, Variable→6, Class→7, Interface→8, Enum→13. |

## 9. What We Skip

| Feature | Ref Lines | Why Deferred |
|---------|-----------|-------------|
| Semantic tokens | ~500 | TextMate grammars handle syntax highlighting |
| Inlay hints | ~180 | Non-essential, needs inferred type display |
| Code actions | ~200 | Needs code modification APIs |
| Rename | ~200 | Needs find-all-references across modules |
| Formatting | ~300 | Needs separate formatter module |
| Incremental text sync | ~150 | Start with full sync |
| Cross-module definition | ~300 | Phase 2, needs module graph |
| Background worker | ~230 | Optimization, not correctness |
| HTML element docs | ~1025 | JSX-specific, defer |

## 10. Existing Infrastructure

### Already exists (suggest.ms builds on)

| What | File | API |
|------|------|-----|
| Symbol lookup | `checker/symbol.ms` | `lookupSymbol(table, name)`, `lookupLocal`, `lookupExport` |
| Scope chain | `checker/symbol.ms` | `Scope { symbols, scopeKind, parent }` |
| Type introspection | `checker/types.ms` | `TypeKind(27)`, `getProperty()`, `getReturnType()`, `getElementType()` |
| Type name (basic) | `checker/types.ms` | `typeNameOf(t)` -- 12 primitive cases |
| Assignability | `checker/compat.ms` | `isAssignable(source, target)` |
| Full check | `checker/checkPass.ms` | `checkSource(input): CheckerContext` |
| Cross-module exports | `checker/context.ms` | `ExportRegistry`, `findExportedSymbol()` |
| Extension methods | `checker/context.ms` | `ExtensionRegistry`, `findExtension()` |
| Parse | `parser/validation.ms` | `parseSource(input): Result<Node, string>` |
| Node positions | `ast/node.ms` | `SourceLocation { line, column }` on every Node |

### Gaps to fill (suggest.ms creates)

| Gap | Notes |
|-----|-------|
| `typeToString` (full) | `typeNameOf` handles 12 cases. Need all 27 TypeKinds recursively. |
| `findNodeAtPosition` | No AST walker by position exists. New. |
| `getCompletionCandidates` | No completion collection. Walk scope + filter + sort. |
| `formatHover` | No Markdown formatter. New. |
| `collectSymbolsInFile` | `collectTopLevel` writes to symbol table. Need read-only list version. |
| `detectCompletionContext` | Text scanning. New. |
| Enhanced error locations | `addError` stores `string[]`. Need `SourceLocation` per error. |

## 11. Implementation Priority

### Phase 1: Diagnostics + Hover (~800 lines)

**Goal**: Open `.ms` in VS Code, see red squiggles, hover shows types.

| Order | File | What |
|-------|------|------|
| 1 | `checker/suggest.ms` | `typeToString`, `findNodeAtPosition`, `getSymbolAtCursor`, `formatHover` |
| 2 | `lsp/protocol.ms` | `readMessage`, `writeMessage`, JSON helpers |
| 3 | `lsp/server.ms` | Main loop, document store, `compileForLsp`, `generateDiagnostics` |
| 4 | `lsp/handlers.ms` | `handleInitialize`, `handleHover`, didOpen/didChange/didClose |
| 5 | `lsp/index.ms` | Hub |

Enhancement: Add `LspDiagnostic` to `checker/context.ms`.

### Phase 2: Completion + Definition (~300 lines)

Add to suggest.ms: `getCompletionCandidates`, `detectCompletionContext`.
Add to handlers.ms: `handleCompletion`, `handleDefinition`.

### Phase 3: Advanced (~300 lines)

Add: `collectSymbolsInFile`, `formatSignature`, `handleDocumentSymbol`, `handleSignatureHelp`. Cross-module support via `ExportRegistry`.

## 12. DRC Constraints

### Interface Name Prefixing

| Module | Prefix | Examples |
|--------|--------|---------|
| `suggest.ms` | `Sg` | `SgSuggest`, `SgFileSymbols`, `SgCompletionKind` |
| `lsp/*.ms` | `Lsp` | `LspDocument`, `LspDocumentStore`, `LspResponse` |

### Standard Workarounds

- **string[] wrap**: `SgFileSymbols { names: string[] }` not bare `string[]`
- **No fresh interface as arg**: Store `SgSuggest` in `const` before pushing to array
- **No try in match arms**: Use if-else for handler dispatch
- **Loop-var codegen**: Extract symbol reads into helper functions taking Symbol as parameter
- **No C-style for in match arms**: Use while or for..of

### Handler Dispatch (if-else, not match)

```ms
// Match + try = broken. Use if-else chain:
if (method === "textDocument/hover") {
    return handleHover(id, params);
} else if (method === "textDocument/completion") {
    return handleCompletion(id, params);
} else if ...
```

## 13. Testing Strategy

### suggest.ms: Inline tests

```ms
testGroup("typeToString", () => {
    test("function type", () => {
        const fn = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
        check(typeToString(fn) === "(a: number, b: string) => boolean");
    });
});

testGroup("findNodeAtPosition", () => {
    test("find identifier", () => {
        const pr = parseSource("const x = 42;");
        if (!pr.ok) { check(false); return; }
        const node = findNodeAtPosition(pr.value, 1, 6);
        check(node !== null);
    });
});

testGroup("getSymbolAtCursor", () => {
    test("variable hover", () => {
        const ctx = checkSource("const myVar: number = 42;");
        const pr = parseSource("const myVar: number = 42;");
        if (!pr.ok) { check(false); return; }
        const sg = getSymbolAtCursor(ctx, pr.value, 1, 6);
        check(sg !== null);
        check(sg.name === "myVar");
    });
});
```

### protocol.ms: Inline tests

```ms
testGroup("JSON-RPC", () => {
    test("jsonString escapes", () => {
        check(jsonString("hello") === "\"hello\"");
    });
    test("getJsonField", () => {
        check(getJsonField("{\"method\":\"hover\"}", "method") === "hover");
    });
});
```

### Test commands

```bash
rm -rf out && msc test src/checker/suggest.ms   # suggest tests
rm -rf out && msc test src/lsp/index.ms          # LSP tests
rm -rf out && msc test src/index.ms              # full suite
```

---

## Reference Cross-Reference

| Self-Hosted | Reference LSP | Nim |
|------------|--------------|-----|
| `suggest.ms` | `server.zig:594-967` (type fmt) + scattered handlers | `compiler/suggest.nim` (986 lines) |
| `protocol.ms` | `jsonrpc.zig` (309 lines) | `nimsuggest/sexp.nim` (657 lines) |
| `server.ms` | `server.zig` (10,630 lines) | `nimsuggest/nimsuggest.nim` (1,406 lines) |
| `handlers.ms` | (embedded in server.zig) | (embedded in nimsuggest.nim) |
| Trans-Am integration | `server.zig:3838+` (transam_db field) | Module graph reuse (simpler) |
