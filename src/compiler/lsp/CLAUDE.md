# MetaScript Self-Hosted LSP Module

Language Server Protocol adapter over the compiler. Entry: `lspRunServer` in `server.ms`, started by `msc lsp`. The intelligence lives in the compiler, not here: the checker side is `src/checker/suggest.ms` (the `sg*` queries: hover, completion candidates, signature help, import edits), and the document state is a Trans-Am db (`src/compiler/transam/CLAUDE.md`).

## Rules

- **A handler asks the compiler, it does not re-implement it** — type information comes from `dbTypeCheck` and the `sg*` queries; no symbol table and no checking rule is written here.
- **`suggest.ms` lives in `checker/`, not here** — it needs `Scope` chains, `Type` fields and the export registries, and an `lsp/` home would make the checker depend upward on the transport.
- **JSON text is built, never `JSON.stringify`'d** — `format.ms` and `responseBuilder.ms` concatenate; strings go through `lspJsonString` (`jsonEncode.ms`), the std JSON string encoder.
- **Positions convert once, in `position.ms`** — an LSP character counts UTF-16 code units, a checker column counts bytes from 1; a handler converting many positions of one source takes a `LineIndex`.
- **`handlers/lifecycleParked.ms` is unregistered on purpose** — a `<module>Parked.ms` holds contracts that are red on an open compiler bug (`src/test/CLAUDE.md`); `grep -rn lifecycleParked src` finds no importer.
- **A new handler registers in `lspDispatch`** (`handlers/lifecycle.ms`), the router every request goes through.

## Layout

The file names carry their job. Two things they do not say: `protocol.ms` is the facade the handlers import the wire vocabulary through (`jsonEncode`, `jsonRpc`, `fileUri`), and `replayScenarios.ms` holds the scenarios the in-memory driver and the real-process driver (`src/test/lsp/run.ms`) both run.

## Tests

```bash
msc test src/compiler/lsp/server.ms            # server and its handlers, in-memory transcripts
msc run src/test/lsp/run.ms                    # replay the scenarios against a real `msc lsp` process
```
