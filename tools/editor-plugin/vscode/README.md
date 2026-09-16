# MetaScript for Visual Studio Code

Language support for [MetaScript](https://github.com/metascriptlang/metascript) -- a systems programming language with TypeScript syntax, compile-time macros, match expressions, Rust-style error handling, and multiple backends (C, JavaScript, Erlang experimental).

## Features

### Syntax Highlighting

Rich TextMate grammar covering all MetaScript syntax:

- Keywords, control flow, declarations
- Match expressions with `=>` arms and `|` alternatives
- Macro decorators (`@target`, `@comptime`, `@emit`, `@derive`, etc.)
- Sized integers (`int8`-`int64`, `uint8`-`uint64`, `float32`, `float64`)
- Ownership keywords (`move`, `borrow`, `defer`, `unreachable`)
- JSX tags and attributes
- Template literals with `${expr}` interpolation
- `.code` compile-time character code access

### Semantic Highlighting

When the language server is running, semantic tokens provide more accurate highlighting than the TextMate grammar alone, including:

- Correct differentiation of types, variables, parameters, and functions
- Mutable vs. immutable bindings
- Compile-time vs. runtime expressions

### Language Server Features

Powered by the `msc lsp` language server:

- **Diagnostics** -- real-time error and warning reporting
- **Completions** -- context-aware suggestions with snippet support
- **Hover** -- type information and documentation on hover
- **Go to Definition** -- jump to symbol definitions
- **Find References** -- find all usages of a symbol
- **Rename** -- project-wide symbol renaming
- **Inlay Hints** -- inline type annotations and parameter names
- **Code Actions** -- quick fixes and refactoring suggestions

### Code Snippets

30+ snippets for common MetaScript patterns:

| Prefix | Description |
|--------|-------------|
| `fn` | Function declaration |
| `efn` | Exported function declaration |
| `iface` | Interface (data struct) |
| `match` | Match expression |
| `rmatch` | Match expression with return |
| `enum` | Enum declaration |
| `forof` | For-of loop |
| `test` | Test case |
| `testgroup` | Test group |
| `imp` | Import statement |
| `result` | Result<T, E> type |
| `try` | Try expression with catch |
| `target` | @target conditional block |
| `defer` | Defer statement |
| `extern` | Extern FFI function |
| `class` | Class declaration |
| `type` | Type alias |
| `distinct` | Distinct type |
| `arrow` | Arrow function |
| `move` | Move ownership |
| `outp` | Out parameter |

Type any prefix and press Tab to expand.

### Status Bar

The status bar shows the language server state:

- **Spinning icon** -- server is starting
- **Check mark** -- server is ready
- **Error icon** -- server has stopped or crashed

Click the status bar item to restart the language server.

### Auto-Restart

If the language server crashes, the extension automatically restarts it with exponential backoff (up to 5 attempts). After 5 failures, it stops and prompts you to restart manually.

## Installation

### From VS Code Marketplace

Search for "MetaScript" in the Extensions view (`Ctrl+Shift+X` / `Cmd+Shift+X`) and click Install.

### From VSIX

1. Build the extension:
   ```bash
   cd tools/editor-plugin/vscode
   npm install
   npm run package
   ```
2. Install the `.vsix` file:
   ```bash
   code --install-extension metascript-0.2.0.vsix
   ```

### Development

1. Open this directory in VS Code
2. Run `npm install`
3. Press `F5` to launch the Extension Development Host

## Configuration

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `metascript.serverPath` | string | `""` | Path to `msc` executable. Leave empty to auto-detect. |
| `metascript.trace.server` | string | `"off"` | LSP trace level: `off`, `messages`, or `verbose`. |
| `metascript.diagnostics.enable` | boolean | `true` | Enable diagnostics from the language server. |
| `metascript.inlayHints.enable` | boolean | `true` | Enable inlay hints (type annotations, parameter names). |
| `metascript.semanticHighlighting.enable` | boolean | `true` | Enable semantic token highlighting. |
| `metascript.completion.snippets` | boolean | `true` | Enable snippet completions from the server. |

## Commands

| Command | Description |
|---------|-------------|
| `MetaScript: Restart Language Server` | Stop and restart the LSP server |
| `MetaScript: Expand Macro at Cursor` | Show the expanded form of a macro |
| `MetaScript: Show Output Channel` | Open the MetaScript output panel |

## Requirements

- **VS Code** 1.85.0 or later
- **MetaScript compiler** (`msc`) installed and available on PATH, or configured via `metascript.serverPath`

To install the MetaScript compiler:

```bash
git clone https://github.com/metascriptlang/metascript
cd metascript
```

## Server Discovery

The extension searches for `msc` in the following order:

1. `metascript.serverPath` setting (supports `~` expansion)
2. Workspace directory: `./zig-out/bin/ms`, `./bin/ms`, `./node_modules/.bin/ms`
3. Extension directory: `./bin/ms`
4. System PATH

## Troubleshooting

**Server not found**: Set `metascript.serverPath` to the full path of your `msc` binary, or ensure it is on your system PATH.

**Server crashes on startup**: Open the MetaScript output channel (`MetaScript: Show Output Channel`) to see error details. Try running `msc lsp` directly in a terminal to check for issues.

**No semantic highlighting**: Verify that `metascript.semanticHighlighting.enable` is `true` and that the server is in the "Ready" state (check the status bar).

**Stale diagnostics**: Use `MetaScript: Restart Language Server` to force a fresh analysis.

## Contributing

Contributions are welcome. Please file issues and pull requests at [github.com/metascriptlang/metascript](https://github.com/metascriptlang/metascript).

## License

MIT
