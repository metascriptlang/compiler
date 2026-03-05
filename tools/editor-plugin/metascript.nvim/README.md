# metascript.nvim

Batteries-included Neovim plugin for the [MetaScript](https://github.com/nickhatzz/metascript) language. Ships with a bundled tree-sitter grammar, highlight queries, LSP integration, smart indentation, code folding, and textobject support -- no external grammar coordination needed.
## Features

- **Tree-sitter highlighting** -- Full syntax highlighting via the bundled tree-sitter-metascript grammar, including JSX, match expressions, macros, and lifecycle hooks
- **Injections** -- Highlights embedded C and JavaScript code within `@emit` strings
- **LSP integration** -- Completion, hover, go-to-definition, references, rename, diagnostics, inlay hints, and semantic tokens via `msc lsp`
- **Smart indentation** -- Tree-sitter powered auto-indent for blocks, functions, classes, match arms, and JSX
- **Code folding** -- Fold functions, classes, interfaces, enums, match bodies, imports, and comments
- **Snippets** -- 30+ high-quality snippets for common patterns (compatible with LuaSnip)
- **Fallback Syntax** -- Regex-based highlighting for users without Tree-sitter
- **Scope tracking** -- Scope-aware highlighting and navigation via locals queries
- **Textobjects** -- Select around/inside functions, classes, parameters, conditionals, loops, and match arms (requires nvim-treesitter-textobjects)
- **Health checks** -- `:checkhealth metascript` verifies your setup
- **Self-contained** -- Grammar, queries, and plugin live in one directory; no sync issues

### Snippets

To use the bundled snippets with [LuaSnip](https://github.com/L3MON4D3/LuaSnip), add the following to your configuration:

```lua
require("luasnip.loaders.from_vscode").lazy_load({
  paths = { vim.fn.stdpath("data") .. "/site/pack/packer/start/metascript.nvim" } -- Adjust path to your plugin manager
})
```

If you use `lazy.nvim`, it's even simpler:

```lua
{
  "nickhatzz/metascript.nvim",
  dependencies = { "L3MON4D3/LuaSnip" },
  config = function()
    require("metascript").setup()
    require("luasnip.loaders.from_vscode").lazy_load({
      paths = { require("metascript").plugin_root() }
    })
  end
}
```

## Requirements
- **Neovim >= 0.9** (0.10+ recommended for full tree-sitter and LSP features)
- **msc** binary (for LSP features)
- **nvim-treesitter** (optional, recommended for automatic parser compilation)
- **nvim-treesitter-textobjects** (optional, for textobject motions)

## Installation

### lazy.nvim

```lua
{
  "nickhatzz/metascript.nvim",
  ft = { "metascript" },
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    -- Optional:
    -- "nvim-treesitter/nvim-treesitter-textobjects",
  },
  opts = {
    server_path = "msc",
    lsp = true,
    treesitter = true,
  },
}
```

### packer.nvim

```lua
use {
  "nickhatzz/metascript.nvim",
  requires = { "nvim-treesitter/nvim-treesitter" },
  ft = { "metascript" },
  config = function()
    require("metascript").setup({
      server_path = "msc",
    })
  end,
}
```

### vim-plug

```vim
Plug 'nvim-treesitter/nvim-treesitter'
Plug 'nickhatzz/metascript.nvim'

" In your init.vim / init.lua:
lua require('metascript').setup()
```

### Manual

Clone this repository into your Neovim runtime path:

```bash
git clone https://github.com/nickhatzz/metascript.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/metascript.nvim
```

Then add to your `init.lua`:

```lua
require("metascript").setup()
```

## Configuration

```lua
require("metascript").setup({
  -- Path to the msc binary (string, default: "msc")
  server_path = "msc",

  -- Enable LSP client (boolean or table, default: true)
  -- Pass `false` to disable, or a table for fine-grained control:
  lsp = {
    -- Override the LSP command (default: { server_path, "lsp" })
    -- cmd = { "/path/to/msc", "lsp" },

    -- LSP settings passed to the server
    -- settings = {},

    -- Custom on_attach callback
    -- on_attach = function(client, bufnr) ... end,

    -- Override capabilities (merged with defaults + cmp-nvim-lsp)
    -- capabilities = {},
  },

  -- Register tree-sitter parser configuration (boolean, default: true)
  treesitter = true,

  -- Custom highlight group overrides (table or nil)
  highlight = {
    -- Example: make keywords bold
    -- ["@keyword"] = { bold = true },
  },
})
```

## Commands

| Command | Description |
|---|---|
| `:MetascriptInfo` | Show plugin information and diagnostic status |
| `:MetascriptRestartServer` | Restart the MetaScript language server |
| `:checkhealth metascript` | Run health checks for the plugin |

## LSP Features

The MetaScript language server (`msc lsp`) provides:

- **Completion** -- Context-aware code completion with type information
- **Hover** -- Type signatures and documentation on hover
- **Go to definition** -- Jump to symbol definitions
- **Find references** -- Find all references to a symbol (cross-file)
- **Rename** -- Project-wide symbol rename (cross-file)
- **Document symbols** -- Outline view of the current file
- **Signature help** -- Function parameter hints
- **Diagnostics** -- Inline error and warning reporting
- **Inlay hints** -- Inline type annotations (Neovim 0.10+)
- **Semantic tokens** -- Enhanced highlighting from the language server

## Tree-sitter Parser

The grammar source is bundled in the `tree-sitter/` subdirectory. This is a fully valid tree-sitter project that can also be used by other editors (VS Code, Emacs, Helix) by pointing them at `tree-sitter/`.

### With nvim-treesitter (recommended)

The plugin automatically registers the parser configuration. Just run:

```vim
:TSInstall metascript
```

nvim-treesitter will compile the parser from the bundled `tree-sitter/src/parser.c`.

### Manual compilation

```bash
cd /path/to/metascript.nvim/tree-sitter
cc -shared -o metascript.so -I src src/parser.c -O2
```

Then place `metascript.so` in your Neovim parser directory:

```bash
cp metascript.so ~/.local/share/nvim/site/parser/metascript.so
```

### Regenerating the parser

If you modify `grammar.js`, regenerate with:

```bash
cd /path/to/metascript.nvim/tree-sitter
npm install        # first time only
tree-sitter generate
tree-sitter test   # run test corpus
```

## Keybinding Suggestions

Add these to your `on_attach` or in a MetaScript-specific `ftplugin`:

```lua
-- LSP keybindings (in your on_attach or ftplugin/metascript.lua)
vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = true, desc = "Go to definition" })
vim.keymap.set("n", "gr", vim.lsp.buf.references, { buffer = true, desc = "Find references" })
vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = true, desc = "Hover documentation" })
vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { buffer = true, desc = "Rename symbol" })
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { buffer = true, desc = "Code actions" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { buffer = true, desc = "Previous diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { buffer = true, desc = "Next diagnostic" })

-- Textobject keybindings (requires nvim-treesitter-textobjects)
-- vaf / daf / caf = select/delete/change around function
-- vif / dif / cif = select/delete/change inner function
-- vac / dac / cac = select/delete/change around class
-- via / dia / cia = select/delete/change inner argument/parameter
```

## File Types

| Extension | Filetype |
|---|---|
| `.ms` | `metascript` |
| `.mts` | `metascript` |

## Project Structure

```
metascript.nvim/
  lua/metascript/
    init.lua          -- Main plugin module (setup, config, commands)
    lsp.lua           -- LSP client configuration (lspconfig + manual fallback)
    health.lua        -- :checkhealth integration
  ftdetect/
    metascript.lua    -- Filetype detection (.ms, .mts)
  ftplugin/
    metascript.lua    -- Buffer-local settings (comments, indent, folding)
  queries/metascript/
    highlights.scm    -- Syntax highlighting queries
    injections.scm    -- Language injection queries (@emit C code)
    indents.scm       -- Smart indentation queries
    folds.scm         -- Code folding queries
    locals.scm        -- Scope and definition tracking
    textobjects.scm   -- Textobject selection queries
  plugin/
    metascript.lua    -- Auto-loaded user commands
  snippets/
    metascript.json   -- VS Code-format snippets (for LuaSnip)
  syntax/
    metascript.vim    -- Fallback regex highlighting (non-Tree-sitter)
  tree-sitter/        -- Bundled tree-sitter grammar (editor-agnostic)
    grammar.js        -- Grammar definition
    package.json      -- Tree-sitter project manifest
    Cargo.toml        -- Rust bindings
    queries/          -- Canonical queries (synced from queries/metascript/)
    src/              -- Generated parser (parser.c, grammar.json, node-types.json)
    bindings/         -- Node.js and Rust bindings
    test/corpus/      -- Test cases for the grammar
  README.md
```

## License

MIT
