; MetaScript injections for Tree-sitter
; Highlights code embedded in strings within @emit and @target blocks

; @emit("...") - typically C code in the C backend
(macro_emit_statement
  (string) @injection.content
  (#set! injection.language "c"))

(macro_emit_expr
  (string) @injection.content
  (#set! injection.language "c"))

; @target("c") { ... } - contents are MetaScript, but if there's an @emit inside,
; it's handled by the rule above.

; JSDoc-style comments (if applicable)
((comment) @injection.content
  (#set! injection.language "jsdoc"))
