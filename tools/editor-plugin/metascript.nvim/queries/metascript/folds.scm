; MetaScript code folding queries for nvim-treesitter.

; ---------------------------------------------------------------------------
; Declarations
; ---------------------------------------------------------------------------

; Function declarations (including async functions)
(function_declaration
  body: (function_body) @fold)

; Macro declarations
(macro_declaration
  body: (macro_body) @fold)

; Class declarations
(class_declaration
  body: (class_body) @fold)

; Interface declarations
(interface_declaration
  body: (interface_body) @fold)

; Enum declarations
(enum_declaration
  body: (enum_body) @fold)

; Test declarations
(test_declaration
  body: (block) @fold)

; Method declarations (inside classes)
(method_declaration
  body: (block) @fold)

; ---------------------------------------------------------------------------
; Control flow
; ---------------------------------------------------------------------------

; Block statements
(block) @fold

; If statements (fold the entire if, including else)
(if_statement) @fold

; Switch statements
(switch_statement
  body: (switch_body) @fold)

; Match expressions
(match_expression
  body: (match_body) @fold)

; For / for-of / for-in loops
(for_statement) @fold
(for_of_statement) @fold
(for_in_statement) @fold

; While / do-while loops
(while_statement) @fold
(do_while_statement) @fold

; ---------------------------------------------------------------------------
; Imports
; ---------------------------------------------------------------------------

; Import clauses (when they span multiple lines)
(import_clause) @fold

; ---------------------------------------------------------------------------
; Literals
; ---------------------------------------------------------------------------

; Object literals
(object) @fold
(object_type) @fold

; Array literals
(array) @fold

; Arrow functions with block body
(arrow_function
  body: (block) @fold)

; ---------------------------------------------------------------------------
; MetaScript-specific
; ---------------------------------------------------------------------------

; @target conditional compilation blocks
(macro_target_block) @fold

; @target body blocks
(macro_target_body) @fold

; Extern declarations with bodies
(extern_class_body) @fold

; ---------------------------------------------------------------------------
; JSX
; ---------------------------------------------------------------------------

; JSX elements (fold opening to closing tag)
(jsx_element) @fold

; JSX fragments
(jsx_fragment) @fold

; ---------------------------------------------------------------------------
; Comments
; ---------------------------------------------------------------------------

; Multi-line comments (/* ... */)
(comment) @fold
