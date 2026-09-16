--- MetaScript Neovim Plugin
--- Tree-sitter highlighting, LSP integration, and editor support for the MetaScript language.
---
--- Usage:
---   require('metascript').setup()
---   require('metascript').setup({ lsp = { cmd = { "/path/to/msc", "lsp" } } })

local M = {}

--- Default configuration
---@class MetascriptConfig
---@field lsp? boolean|table Enable LSP client (default: true). Pass a table with cmd, on_attach, handlers, etc.
---@field treesitter? boolean Register tree-sitter parser (default: true)
---@field highlight? table Custom highlight group overrides (e.g., { ["@keyword"] = { bold = true } })
M.config = {
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
--- locate the MetaScript grammar. Uses tree-sitter/ for the compiled .so,
--- and tree-sitter-metascript/ (sibling) as the canonical grammar source.
local function register_treesitter()
  local root = plugin_root()
  local ts_dir = root .. "/tree-sitter"

  -- Always install bundled parser .so to nvim's parser directory.
  -- The bundled .so is the source of truth — TSInstall may produce an incomplete
  -- build (missing scanner.c), so we unconditionally overwrite on every startup.
  local bundled_so = ts_dir .. "/metascript.so"
  local nvim_parser_dir = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter/parser"
  local target_so = nvim_parser_dir .. "/metascript.so"
  local bundled_stat = vim.loop.fs_stat(bundled_so)
  if bundled_stat then
    vim.fn.mkdir(nvim_parser_dir, "p")
    vim.loop.fs_copyfile(bundled_so, target_so)
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

  -- Register file icons with nvim-web-devicons (used by neo-tree, bufferline, lualine, etc.)
  local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
  if devicons_ok then
    devicons.set_icon({
      ms  = { icon = "󰛦", color = "#FF9800", name = "MetaScript" },
      cms = { icon = "󰛦", color = "#546E7A", name = "MetaScriptC" },
      jms = { icon = "󰛦", color = "#66BB6A", name = "MetaScriptJS" },
      ems = { icon = "󰛦", color = "#CE93D8", name = "MetaScriptErlang" },
      wms = { icon = "󰛦", color = "#4DD0E1", name = "MetaScriptWASM" },
      rms = { icon = "󰛦", color = "#EF5350", name = "MetaScriptRuntime" },
    })
  end

  -- Register tree-sitter parser configuration.
  if M.config.treesitter then
    register_treesitter()
  end

  -- Set up LSP.
  if M.config.lsp then
    local lsp_opts = type(M.config.lsp) == "table" and M.config.lsp or {}
    require("metascript.lsp").setup(lsp_opts)
  end

  -- Set default LSP semantic token highlights for MetaScript.
  -- Links builtin functions/variables (defaultLibrary modifier) to "support" groups.
  -- Users can override via the highlight config or colorscheme.
  -- Unused symbols: gray + green curly underline via DiagnosticUnnecessary (tags:[1]).
  local function patch_unnecessary_hl()
    local hl = vim.api.nvim_get_hl(0, { name = "DiagnosticUnnecessary" })
    hl.undercurl = true
    hl.sp = vim.api.nvim_get_hl(0, { name = "DiagnosticHint" }).fg
    vim.api.nvim_set_hl(0, "DiagnosticUnnecessary", hl)
  end
  patch_unnecessary_hl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = patch_unnecessary_hl })

  local semantic_defaults = {
    ["@lsp.typemod.function.defaultLibrary.metascript"] = { link = "Special" },
    ["@lsp.typemod.variable.defaultLibrary.metascript"] = { link = "Special" },
    ["@lsp.typemod.type.defaultLibrary.metascript"] = { link = "Type" },
  }
  for group, attrs in pairs(semantic_defaults) do
    -- Only set if not already defined by colorscheme.
    if vim.fn.hlexists(group) == 0 or vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = group })) then
      vim.api.nvim_set_hl(0, group, attrs)
    end
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
  -- Check msc binary.
  local cmd = type(M.config.lsp) == "table" and M.config.lsp.cmd or { "msc", "lsp" }
  local bin = cmd[1] or "msc"
  table.insert(lines, string.format("  LSP command    : %s", table.concat(cmd, " ")))
  local msc_found = vim.fn.executable(bin) == 1
  table.insert(lines, string.format("  Binary found   : %s", msc_found and "yes" or "NO"))

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
