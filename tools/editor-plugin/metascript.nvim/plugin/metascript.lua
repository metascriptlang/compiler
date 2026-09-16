-- Auto-loaded plugin entry point for metascript.nvim.
-- Registers user commands. Loaded once by Neovim's runtime path mechanism.

if vim.g.loaded_metascript then
  return
end
vim.g.loaded_metascript = true

-- Register file icons early so neo-tree/bufferline see them before setup() runs.
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

-- :MetascriptInfo -- Display plugin diagnostic information.
vim.api.nvim_create_user_command("MetascriptInfo", function()
  local ok, ms = pcall(require, "metascript")
  if ok then
    ms.info()
  else
    vim.notify("[metascript] Plugin not loaded. Call require('metascript').setup() first.", vim.log.levels.WARN)
  end
end, {
  desc = "Show MetaScript plugin information and diagnostics",
})

-- :MetascriptRestartServer -- Restart the MetaScript language server.
vim.api.nvim_create_user_command("MetascriptRestartServer", function()
  local ok, ms = pcall(require, "metascript")
  if ok then
    ms.restart_server()
  else
    vim.notify("[metascript] Plugin not loaded. Call require('metascript').setup() first.", vim.log.levels.WARN)
  end
end, {
  desc = "Restart the MetaScript language server",
})
