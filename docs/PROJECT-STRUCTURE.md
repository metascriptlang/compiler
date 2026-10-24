# Project Structure

One line per directory under `src/`: what it owns and where a reader enters it. Phase order and
contracts are in [`PIPELINE.md`](PIPELINE.md); the files inside a directory are not listed here
because `ls` is current.

| Directory | Owns | Enter at |
|---|---|---|
| `src/index.ms` | CLI dispatch only; also imports the guard and position tests so test discovery finds them | top level |
| `ast/` | node definitions re-exported from `std/meta/node`, the child visitor, the debug dump (`printer.ms`), `fieldspec.ms` (the one per-kind field spec) and the guards that keep the child tables whole | `index.ms` |
| `lexer/` | source text to tokens; `TokenKind` lives in `std/meta/token` | `lexer.ms` `lex` |
| `parser/` | recursive descent + Pratt precedence; `statements/` and `expressions/` split by node family | `statements/core.ms` `parseProgram` |
| `binder/` | flow graph the checker's narrowing reads | `index.ms` `bindFlowGraph` |
| `checker/` | the three passes (collect, resolve, check), flow narrowing, and `suggest.ms`, the position queries the LSP calls | `orchestrator.ms` `checkModuleGraph` |
| `monomorphize/` | mangled names for generic instances; instances themselves are made by the checker (`checker/instantiate.ms`) | `registry.ms` `monoInstanceName` |
| `transform/` | AST lowering passes; the C-only tail is `native/` | `index.ms` `transformProgram`; `native/index.ms` |
| `analyzer/` | DRC injection (C backend only) | `index.ms` `analyzeProgram` |
| `codegen/c/` | C emitter, one module of C per source module | `index.ms` `generateCModule` |
| `codegen/js/` | JS emitter | `jsgen.ms` `generateJS` |
| `codegen/raiser/` | AST to Raiser bytecode | `rgen.ms` `generateRaiser` |
| `raiser/` | the bytecode VM: values, heaps, scheduler, host registry | `context.ms` `createContext` / `execute` |
| `module/` | import resolution, the module graph and loader; `cimport/` and `cparse/` turn a C header into module source | `loader.ms` `loadModuleGraph` |
| `embed/` | the embedding API over the Raiser VM (create an interpreter, evaluate a module, call a routine) | `index.ms` `createInterpreter` |
| `compiler/` | the commands behind `msc`: `compile.ms` (build, run, test), `commands.ms` (check, dump, fmt, ...), options, build config, C compiler and cache | `src/index.ms` |
| `compiler/fmt/` | the formatter | `printer/index.ms` `formatNode` |
| `compiler/lsp/` | the language server ([`CLAUDE.md`](../src/compiler/lsp/CLAUDE.md)) | `server.ms` `lspRunServer` |
| `compiler/meta/` | macro expansion and `@comptime` evaluation over the Raiser VM, and the host bridge table | `expand.ms`, `comptime.ms`, `hostTable.ms` |
| `compiler/package/` | `msc add` / `install` / `publish` / `login` and the registry client ([`PACKAGE.md`](PACKAGE.md)) | `index.ms` `runPackageCommand` |
| `compiler/transam/` | the incremental query engine ([`TRANSAM.md`](TRANSAM.md)) | `index.ms` |
| `utils/` | compiler-side helpers that import only `std/*` (colour, paths, command line, link state, string and source-line helpers) | per file |
| `test/` | the suite, the corpus, the guards and the lane runners ([`CLAUDE.md`](../src/test/CLAUDE.md)) | `index.ms` |

## Architecture Patterns

### Self-hosted execution
The compiler is a native binary (`msc`) built by the previous generation of
itself. It reads target `.ms`/`.cms` files as **raw strings** and parses them
with its own MetaScript parser. When debugging parse errors on target files
(e.g. prelude `.cms` files), the issue is always in our parser (`src/parser/`).

### Callback injection (circular import breaker)
Four `callbacks.ms` files hold function slots that the owning module registers at load;
[`PIPELINE.md`](PIPELINE.md) §Module dependency rules lists them and the trap.

### Flat Type class (not discriminated union)
`Type` (`std/meta/node.ms`) is one class: every field is present and the unused ones are
empty or null. This avoids codegen bugs with self-referencing anonymous structs.

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
`fnReturnType`, etc.) are stored as strings. The positioned type AST rides beside
them in `Node.typeExpr` / `typeExprs` (`std/meta/node.ms`) for LSP symbol recording.
