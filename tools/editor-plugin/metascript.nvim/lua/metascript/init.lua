--- MetaScript Neovim Plugin
--- Tree-sitter highlighting, LSP integration, and editor support for the MetaScript language.
---
--- Usage:
---   require('metascript').setup()
---   require('metascript').setup({ server_path = '/usr/local/bin/msc', lsp = true })

local M = {}

--- Default configuration
---@class MetascriptConfig
---@field server_path string Path to the msc binary (default: "msc")
---@field lsp boolean|table Enable LSP client (default: true). Pass a table for fine-grained LSP options.
---@field treesitter boolean Register tree-sitter parser config (default: true)
---@field highlight table|nil Custom highlight group overrides (e.g., { ["@keyword"] = { bold = true } })
M.config = {
  server_path = "msc",
  lsp = true,
  treesitter = true,
  highlight = nil,
}

--- Internal state
local _setup_done = false

--- Resolve the plugin root directory dynamically from this file's location.
--- Returns the path to metascript.nvim/ (three levels up from lua/metascript/init.lua).
---@return string
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2) -- strip leading "@"
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

--- Register the tree-sitter parser configuration so nvim-treesitter (or manual parsers) can
--- locate the MetaScript grammar from the bundled tree-sitter/ directory.
local function register_treesitter()
  local root = plugin_root()
  local ts_dir = root .. "/tree-sitter"

  -- Register with nvim-treesitter if available.
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok and parsers then
    local parser_config = parsers.get_parser_configs()
    if parser_config and not parser_config.metascript then
      parser_config.metascript = {
        install_info = {
          url = ts_dir,
          files = { "src/parser.c" },
          generate_requires_npm = false,
          requires_generate_from_grammar = false,
        },
        filetype = "metascript",
        used_by = {},
      }
    end
  end

  -- Register parser via vim.treesitter (Neovim 0.9+) regardless of nvim-treesitter presence.
  -- This enables built-in tree-sitter highlighting even without the nvim-treesitter plugin.
  pcall(vim.treesitter.language.register, "metascript", "metascript")

  -- Ensure our bundled queries are the definitive source.
  -- This overrides any globally installed queries so the plugin stays self-contained.
  local query_dir = root .. "/queries/metascript"
  for _, query_name in ipairs({ "highlights", "indents", "folds", "locals", "textobjects", "injections" }) do
    local path = query_dir .. "/" .. query_name .. ".scm"
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      pcall(vim.treesitter.query.set, "metascript", query_name, content)
    end
  end
end

--- Apply user-supplied highlight overrides.
---@param overrides table<string, table> Map of highlight group name to highlight attributes.
local function apply_highlight_overrides(overrides)
  if not overrides or type(overrides) ~= "table" then
    return
  end
  for group, attrs in pairs(overrides) do
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

--- Set up the MetaScript plugin.
---@param opts MetascriptConfig|nil User configuration (merged with defaults).
function M.setup(opts)
  if _setup_done then
    return
  end
  _setup_done = true

  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Register tree-sitter parser configuration.
  if M.config.treesitter then
    register_treesitter()
  end

  -- Set up LSP.
  if M.config.lsp then
    local lsp_opts = type(M.config.lsp) == "table" and M.config.lsp or {}
    require("metascript.lsp").setup(M.config.server_path, lsp_opts)
  end

  -- Apply highlight overrides.
  apply_highlight_overrides(M.config.highlight)
end

--- Get the plugin root directory. Exposed for use by health.lua and other modules.
---@return string
function M.plugin_root()
  return plugin_root()
end

--- Display diagnostic information about the plugin installation.
function M.info()
  local root = plugin_root()
  local lines = {}
  table.insert(lines, "metascript.nvim")
  table.insert(lines, string.rep("-", 40))
  table.insert(lines, string.format("  Plugin root    : %s", root))
  table.insert(lines, string.format("  Neovim version : %s", vim.version and tostring(vim.version()) or "unknown"))
  table.insert(lines, string.format("  Server path    : %s", M.config.server_path))

  -- Check msc binary.
  local msc_found = vim.fn.executable(M.config.server_path) == 1
  table.insert(lines, string.format("  msc available  : %s", msc_found and "yes" or "NO"))

  -- Check tree-sitter parser.
  local parser_ok = pcall(vim.treesitter.language.inspect, "metascript")
  table.insert(lines, string.format("  TS parser      : %s", parser_ok and "installed" or "not found"))

  -- Check nvim-treesitter plugin.
  local nvim_ts_ok = pcall(require, "nvim-treesitter")
  table.insert(lines, string.format("  nvim-treesitter: %s", nvim_ts_ok and "yes" or "no"))

  -- LSP status.
  local lsp_enabled = M.config.lsp and true or false
  table.insert(lines, string.format("  LSP enabled    : %s", lsp_enabled and "yes" or "no"))
  if lsp_enabled then
    local clients = vim.lsp.get_clients and vim.lsp.get_clients({ name = "metascript" })
      or vim.lsp.get_active_clients and vim.lsp.get_active_clients({ name = "metascript" })
      or {}
    table.insert(lines, string.format("  LSP clients    : %d active", #clients))
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Restart the MetaScript language server for all attached buffers.
function M.restart_server()
  require("metascript.lsp").restart()
end

return M
