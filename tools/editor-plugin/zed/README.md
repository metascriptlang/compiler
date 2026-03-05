# MetaScript for Zed

Native [Zed](https://zed.dev) extension for the [MetaScript](https://github.com/nickhatzz/metascript) language. Provides Tree-sitter syntax highlighting, LSP integration, auto-indent, code outline, and bracket matching.

## Features

- **Tree-sitter highlighting** -- Full syntax highlighting via the tree-sitter-metascript grammar
- **LSP integration** -- Completion, hover, go-to-definition, references, rename, diagnostics, inlay hints, and semantic tokens via `msc lsp`
- **Smart indentation** -- Auto-indent for blocks, functions, classes, match arms, and JSX
- **Code outline** -- Symbol list for functions, classes, interfaces, enums, methods, tests
- **Bracket matching** -- Matching and rainbow brackets for `{}`, `[]`, `()`
- **Injections** -- Highlights embedded C code within `@emit` strings

## Requirements

- **Zed** (latest stable)
- **msc** binary on your system PATH (for LSP features)

To install the MetaScript compiler:

```bash
git clone https://github.com/nickhatzz/metascript
cd metascript
zig build install
```

## Installation

### From Zed Extensions (when published)

Open Zed, go to `Extensions` (`Cmd+Shift+X`), search for "MetaScript", and click Install.

### Development / Local Install

1. Clone or locate this directory
2. In Zed, open the command palette (`Cmd+Shift+P`)
3. Run `zed: install dev extension`
4. Select the `zed/` directory

## File Types

| Extension | Language |
|-----------|----------|
| `.ms` | MetaScript |

> **Note**: The `.mts` extension is excluded from this extension to avoid conflicts with TypeScript's ES module files. Use `.ms` as the primary MetaScript file extension.

## LSP Features

The MetaScript language server (`msc lsp`) provides:

- **Completion** -- Context-aware code completion with type information
- **Hover** -- Type signatures and documentation on hover
- **Go to definition** -- Jump to symbol definitions
- **Find references** -- Find all references to a symbol
- **Rename** -- Project-wide symbol rename
- **Diagnostics** -- Inline error and warning reporting
- **Inlay hints** -- Inline type annotations
- **Semantic tokens** -- Enhanced highlighting from the language server

## Project Structure

```
zed/
  extension.toml                    -- Extension metadata and grammar reference
  Cargo.toml                       -- Minimal Rust project for LSP shim
  src/
    lib.rs                          -- LSP binary discovery (~25 lines)
  languages/
    metascript/
      config.toml                   -- Language config (comments, brackets, indent)
      highlights.scm                -- Syntax highlighting (synced from nvim)
      indents.scm                   -- Auto-indentation rules (synced from nvim)
      injections.scm                -- Embedded language highlighting (synced from nvim)
      brackets.scm                  -- Bracket matching (Zed-specific)
      outline.scm                   -- Code outline / symbol list (Zed-specific)
  README.md
```

## Query Sync

Query files (`highlights.scm`, `indents.scm`, `injections.scm`) are synced from the canonical source in `metascript.nvim/queries/metascript/` via the build script:

```bash
bun tools/editor-plugin/build.ts
```

The build script automatically adapts Neovim-specific predicates (`#lua-match?` to `#match?`) for Zed compatibility.

## License

MIT
