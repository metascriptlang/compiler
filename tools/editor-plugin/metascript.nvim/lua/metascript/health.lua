--- MetaScript health check integration.
--- Run with :checkhealth metascript

local M = {}

--- Helper: report using the appropriate API for the Neovim version.
local health = {}
if vim.health then
  health.start = vim.health.start or function() end
  health.ok = vim.health.ok
  health.warn = vim.health.warn
  health.error = vim.health.error
  health.info = vim.health.info or function() end
else
  -- Neovim < 0.10 fallback.
  local h = require("health")
  health.start = h.report_start or h.start or function() end
  health.ok = h.report_ok or h.ok
  health.warn = h.report_warn or h.warn
  health.error = h.report_error or h.error
  health.info = h.report_info or h.info or function() end
end

function M.check()
  health.start("metascript.nvim")

  -- 1. Neovim version check.
  local nvim_ver = vim.version()
  if nvim_ver then
    local ver_str = string.format("%d.%d.%d", nvim_ver.major, nvim_ver.minor, nvim_ver.patch)
    if nvim_ver.major > 0 or (nvim_ver.major == 0 and nvim_ver.minor >= 9) then
      health.ok("Neovim version: " .. ver_str .. " (>= 0.9 required)")
    else
      health.error(
        "Neovim version: " .. ver_str .. " (>= 0.9 required)",
        { "Upgrade Neovim to 0.9 or later: https://github.com/neovim/neovim/releases" }
      )
    end
  else
    health.warn("Could not determine Neovim version")
  end

  -- 2. Bundled tree-sitter/ directory.
  local root = require("metascript").plugin_root()
  local ts_dir = root .. "/tree-sitter"
  local grammar_path = ts_dir .. "/grammar.js"
  local parser_c_path = ts_dir .. "/src/parser.c"

  if vim.fn.isdirectory(ts_dir) == 1 and vim.fn.filereadable(grammar_path) == 1 then
    health.ok("Bundled tree-sitter/ directory found: " .. ts_dir)
  else
    health.error(
      "Bundled tree-sitter/ directory missing or incomplete",
      { "Expected at: " .. ts_dir, "Re-install the plugin or check your plugin manager" }
    )
  end

  if vim.fn.filereadable(parser_c_path) == 1 then
    health.ok("parser.c present in tree-sitter/src/")
  else
    health.warn(
      "parser.c not found in tree-sitter/src/",
      { "Run `tree-sitter generate` inside " .. ts_dir .. " to regenerate" }
    )
  end

  -- 3. tree-sitter CLI.
  if vim.fn.executable("tree-sitter") == 1 then
    health.ok("tree-sitter CLI found")
  else
    health.warn(
      "tree-sitter CLI not found (needed for parser compilation)",
      { "Install tree-sitter-cli: npm install -g tree-sitter-cli" }
    )
  end

  -- 4. Compiled parser loadable by Neovim.
  local parser_ok = pcall(vim.treesitter.language.inspect, "metascript")
  if parser_ok then
    health.ok("tree-sitter-metascript parser loaded")
  else
    health.warn(
      "tree-sitter-metascript parser not compiled/installed",
      {
        "Install via nvim-treesitter: :TSInstall metascript",
        "Or compile manually: cc -shared -o parser.so -I src src/parser.c  (in " .. ts_dir .. ")",
      }
    )
  end

  -- 5. msc binary (LSP server).
  local config = require("metascript").config
  local server_path = config.server_path or "msc"
  if vim.fn.executable(server_path) == 1 then
    health.ok("msc binary found: " .. server_path)
  else
    health.error(
      "msc binary not found: " .. server_path,
      {
        "Install MetaScript or set server_path in setup()",
        "Example: require('metascript').setup({ server_path = '/path/to/msc' })",
      }
    )
  end

  -- 6. nvim-treesitter plugin (optional).
  local nvim_ts_ok = pcall(require, "nvim-treesitter")
  if nvim_ts_ok then
    health.ok("nvim-treesitter plugin installed")
  else
    health.info(
      "nvim-treesitter plugin not installed (optional but recommended)",
      { "Install: https://github.com/nvim-treesitter/nvim-treesitter" }
    )
  end

  -- 7. nvim-treesitter-textobjects (optional).
  local ts_textobjects_ok = pcall(require, "nvim-treesitter-textobjects")
  if ts_textobjects_ok then
    health.ok("nvim-treesitter-textobjects installed")
  else
    health.info("nvim-treesitter-textobjects not installed (optional, enables textobject queries)")
  end

  -- 8. nvim-lspconfig (optional).
  local lspconfig_ok = pcall(require, "lspconfig")
  if lspconfig_ok then
    health.ok("nvim-lspconfig installed")
  else
    health.info("nvim-lspconfig not installed (plugin uses manual vim.lsp.start fallback)")
  end
end

return M
