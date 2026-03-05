--- MetaScript LSP client configuration.
--- Uses vim.lsp.start() (Neovim 0.8+) with optional lspconfig integration.

local M = {}

--- Internal: store configuration for restarts.
local _server_path = "msc"
local _lsp_opts = {}
local _client_id = nil

--- Root markers used to detect the project root directory.
local ROOT_MARKERS = { "package.json", ".git", "src", "tsconfig.json", ".metascript" }

--- Detect the project root by walking up from the buffer's directory.
---@param bufnr number Buffer number.
---@return string root The detected project root, or the buffer's directory as fallback.
local function find_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return vim.fn.getcwd()
  end

  -- Prefer vim.fs.find (Neovim 0.8+).
  if vim.fs and vim.fs.find then
    local results = vim.fs.find(ROOT_MARKERS, {
      path = vim.fs.dirname(bufname),
      upward = true,
      stop = vim.env.HOME,
    })
    if results and #results > 0 then
      return vim.fs.dirname(results[1])
    end
  end

  -- Fallback: buffer directory.
  return vim.fn.fnamemodify(bufname, ":p:h")
end

--- Build the LSP client configuration table.
---@param server_path string Path to the msc binary.
---@param root_dir string Project root directory.
---@param user_opts table User-supplied LSP overrides.
---@return table config vim.lsp.start-compatible configuration.
local function build_config(server_path, root_dir, user_opts)
  local config = {
    name = "metascript",
    cmd = { server_path, "lsp" },
    root_dir = root_dir,
    filetypes = { "metascript" },
    single_file_support = true,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    settings = {},
    init_options = {},
    on_attach = function(client, bufnr)
      -- Enable inlay hints if supported (Neovim 0.10+).
      if vim.lsp.inlay_hint and client.server_capabilities.inlayHintProvider then
        vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
      end
    end,
  }

  -- Merge user capabilities if provided.
  if user_opts.capabilities then
    config.capabilities = vim.tbl_deep_extend("force", config.capabilities, user_opts.capabilities)
  end

  -- Attempt to merge cmp-nvim-lsp capabilities if available.
  local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if cmp_ok and cmp_lsp.default_capabilities then
    config.capabilities = vim.tbl_deep_extend("force", config.capabilities, cmp_lsp.default_capabilities())
  end

  -- Pass through user overrides.
  if user_opts.settings then
    config.settings = user_opts.settings
  end
  if user_opts.init_options then
    config.init_options = user_opts.init_options
  end
  if user_opts.on_attach then
    config.on_attach = user_opts.on_attach
  end
  if user_opts.cmd then
    config.cmd = user_opts.cmd
  end

  return config
end

--- Attempt to configure the LSP via nvim-lspconfig if it is installed.
--- Returns true if lspconfig handled setup, false otherwise.
---@param server_path string
---@param user_opts table
---@return boolean
local function try_lspconfig(server_path, user_opts)
  local lspconfig_ok, lspconfig = pcall(require, "lspconfig")
  if not lspconfig_ok then
    return false
  end

  local configs_ok, configs = pcall(require, "lspconfig.configs")
  if not configs_ok then
    return false
  end

  -- Register the MetaScript server if it does not already exist.
  if not configs.metascript then
    configs.metascript = {
      default_config = {
        cmd = { server_path, "lsp" },
        filetypes = { "metascript" },
        root_dir = lspconfig.util.root_pattern(unpack(ROOT_MARKERS)),
        single_file_support = true,
        settings = {},
      },
    }
  end

  -- Build setup opts.
  local setup_opts = {
    cmd = user_opts.cmd or { server_path, "lsp" },
    settings = user_opts.settings or {},
    on_attach = user_opts.on_attach,
    capabilities = user_opts.capabilities,
  }

  -- Merge cmp-nvim-lsp capabilities.
  local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if cmp_ok and cmp_lsp.default_capabilities then
    setup_opts.capabilities = vim.tbl_deep_extend(
      "force",
      vim.lsp.protocol.make_client_capabilities(),
      cmp_lsp.default_capabilities(),
      setup_opts.capabilities or {}
    )
  end

  lspconfig.metascript.setup(setup_opts)
  return true
end

--- Set up the MetaScript LSP client.
--- Tries lspconfig first; falls back to manual vim.lsp.start() via an autocmd.
---@param server_path string Path to the msc binary.
---@param user_opts table Additional LSP configuration.
function M.setup(server_path, user_opts)
  _server_path = server_path or "msc"
  _lsp_opts = user_opts or {}

  -- Try lspconfig first.
  if try_lspconfig(_server_path, _lsp_opts) then
    return
  end

  -- Manual fallback: attach via autocmd on FileType.
  local group = vim.api.nvim_create_augroup("MetascriptLsp", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "metascript",
    callback = function(args)
      local bufnr = args.buf
      local root_dir = find_root(bufnr)
      local config = build_config(_server_path, root_dir, _lsp_opts)
      _client_id = vim.lsp.start(config, { bufnr = bufnr })
    end,
    desc = "Start MetaScript LSP client",
  })

  -- Attach to any already-open metascript buffers.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "metascript" then
      local root_dir = find_root(bufnr)
      local config = build_config(_server_path, root_dir, _lsp_opts)
      _client_id = vim.lsp.start(config, { bufnr = bufnr })
    end
  end
end

--- Restart the MetaScript language server.
--- Stops all active metascript LSP clients and re-attaches to open buffers.
function M.restart()
  -- Collect all metascript clients.
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ name = "metascript" })
    or vim.lsp.get_active_clients and vim.lsp.get_active_clients({ name = "metascript" })
    or {}

  -- Stop each client.
  for _, client in ipairs(clients) do
    client.stop()
  end

  -- Small delay to allow the server process to exit, then re-attach.
  vim.defer_fn(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "metascript" then
        local root_dir = find_root(bufnr)
        local config = build_config(_server_path, root_dir, _lsp_opts)
        vim.lsp.start(config, { bufnr = bufnr })
      end
    end
    vim.notify("[metascript] LSP server restarted", vim.log.levels.INFO)
  end, 500)
end

return M
