-- Filetype plugin for MetaScript.
-- Sets buffer-local options for editing .ms and .mts files.

if vim.b.did_ftplugin_metascript then
  return
end
vim.b.did_ftplugin_metascript = true

-- Comment formatting.
vim.bo.commentstring = "// %s"
vim.bo.comments = "s1:/*,mb:*,ex:*/,:///,://"

-- Indentation: 4-space tabs (matches MetaScript convention).
vim.bo.tabstop = 4
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.expandtab = true

-- Format options:
--   c = auto-wrap comments
--   r = insert comment leader on <Enter>
--   o = insert comment leader on 'o'/'O'
--   q = allow formatting with gq
--   j = remove comment leader when joining lines
vim.bo.formatoptions = "croqj"

-- Keyword characters: include $ (valid in MetaScript identifiers).
vim.bo.iskeyword = vim.bo.iskeyword .. ",$"

-- Fold method: use tree-sitter or expression-based folding.
-- Tree-sitter folding is preferred if the parser is available.
local parser_ok = pcall(vim.treesitter.language.inspect, "metascript")
if parser_ok then
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
else
  vim.wo.foldmethod = "syntax"
end
vim.wo.foldlevel = 99  -- Start with all folds open.

-- Match pairs: braces, brackets, parens, angle brackets.
vim.bo.matchpairs = "(:),{:},[:],<:>"

-- Suffixes for file completion.
vim.bo.suffixesadd = ".ms,.mts"

-- Path: look in src/ and standard include directories for gf navigation.
vim.opt_local.path:append("src")
vim.opt_local.path:append(".")

-- Undo ftplugin settings when filetype changes.
vim.b.undo_ftplugin = table.concat({
  "setlocal commentstring<",
  "setlocal comments<",
  "setlocal tabstop<",
  "setlocal shiftwidth<",
  "setlocal softtabstop<",
  "setlocal expandtab<",
  "setlocal formatoptions<",
  "setlocal iskeyword<",
  "setlocal foldmethod<",
  "setlocal foldexpr<",
  "setlocal foldlevel<",
  "setlocal matchpairs<",
  "setlocal suffixesadd<",
  "setlocal path<",
}, " | ")
