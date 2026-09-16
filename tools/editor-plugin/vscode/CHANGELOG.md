# Changelog

All notable changes to the MetaScript VS Code extension will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-05

### Added
- Semantic token highlighting powered by the LSP server
- Code snippets for 30+ common patterns (fn, match, interface, enum, result, try, macros, etc.)
- Inlay hints support (type annotations, parameter names)
- Status bar indicator showing language server state (starting/ready/error)
- Automatic server restart on crash (up to 5 attempts with exponential backoff)
- `MetaScript: Restart Language Server` command
- `MetaScript: Show Output Channel` command
- `MetaScript: Expand Macro at Cursor` command (requires server support)
- Configuration options: inlayHints.enable, semanticHighlighting.enable, completion.snippets
- Auto-restart on configuration changes (serverPath, trace.server)
- Timestamped logging to output channel

### Improved
- TextMate grammar: JSX tag support, `unreachable` keyword, `move` keyword, `out` parameter modifier
- TextMate grammar: `.code` compile-time char code highlighting, `when` guard keyword
- TextMate grammar: `distinct type` declarations, sized integers (int8-int64, uint8-uint64, float32, float64)
- TextMate grammar: Better doc-comment highlighting (`/** */` with @param, @returns tags)
- TextMate grammar: Match alternative `|` operator, pipe operator `|>`
- Server discovery: settings -> workspace bin/ -> extension bin/ -> PATH (with ~ expansion)
- Proper error handling with actionable messages ("Open Settings" button when server not found)
- Extension properly disposes all resources on deactivation

### Changed
- Publisher updated to `metascript-lang`
- Display name capitalized to `MetaScript`
- Repository URL updated to `https://github.com/metascriptlang/metascript`

## [0.1.0] - 2025-12-01

### Added
- Initial release
- TextMate syntax highlighting for MetaScript (.ms, .mts)
- Language server client connecting to `msc lsp` via stdio
- Language configuration (brackets, comments, folding, indentation)
- Light and dark file icons
