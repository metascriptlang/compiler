-- Filetype detection for MetaScript files.
-- Extensions: .ms (primary), .mts (MetaScript TypeScript-style)

vim.filetype.add({
  extension = {
    ms = "metascript",
    mts = "metascript",
  },
})
