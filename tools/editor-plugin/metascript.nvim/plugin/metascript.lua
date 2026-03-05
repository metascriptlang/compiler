-- Auto-loaded plugin entry point for metascript.nvim.
-- Registers user commands. Loaded once by Neovim's runtime path mechanism.

if vim.g.loaded_metascript then
  return
end
vim.g.loaded_metascript = true

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
