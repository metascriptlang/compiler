; MetaScript textobject queries for nvim-treesitter-textobjects.
; Enables motions like vaf (select around function), vif (select inner function), etc.

; ---------------------------------------------------------------------------
; Functions
; ---------------------------------------------------------------------------

; Function declarations (outer = entire declaration, inner = body)
(function_declaration) @function.outer
(function_declaration
  body: (function_body) @function.inner)

; Macro declarations
(macro_declaration) @function.outer
(macro_declaration
  body: (macro_body) @function.inner)

; Method declarations
(method_declaration) @function.outer
(method_declaration
  body: (block) @function.inner)

; Arrow functions
(arrow_function) @function.outer
(arrow_function
  body: (block) @function.inner)

; ---------------------------------------------------------------------------
; Classes
; ---------------------------------------------------------------------------

; Class declarations
(class_declaration) @class.outer
(class_declaration
  body: (class_body) @class.inner)

; Interface declarations (MetaScript interfaces are data structs)
(interface_declaration) @class.outer
(interface_declaration
  body: (interface_body) @class.inner)

; Enum declarations
(enum_declaration) @class.outer
(enum_declaration
  body: (enum_body) @class.inner)

; ---------------------------------------------------------------------------
; Parameters / Arguments
; ---------------------------------------------------------------------------

; Function parameters
(parameter) @parameter.inner

; Arrow function parameters
(arrow_function_parameter) @parameter.inner

; Rest parameters
(rest_parameter) @parameter.inner

; Extension method receiver
(this_parameter) @parameter.inner

; Call arguments (each expression is a parameter)
(arguments
  (_) @parameter.inner)

; ---------------------------------------------------------------------------
; Conditionals
; ---------------------------------------------------------------------------

(if_statement) @conditional.outer
(if_statement
  consequence: (_) @conditional.inner)

(switch_statement) @conditional.outer
(switch_body) @conditional.inner

(switch_case) @conditional.outer

; Match expressions (MetaScript pattern matching)
(match_expression) @conditional.outer
(match_body) @conditional.inner

; Individual match arms
(match_arm) @conditional.outer
(match_arm
  value: (_) @conditional.inner)

; ---------------------------------------------------------------------------
; Loops
; ---------------------------------------------------------------------------

(for_statement) @loop.outer
(for_statement
  (_) @loop.inner . )

(for_of_statement) @loop.outer
(for_of_statement
  body: (_) @loop.inner)

(for_in_statement) @loop.outer
(for_in_statement
  body: (_) @loop.inner)

(while_statement) @loop.outer
(while_statement
  (_) @loop.inner . )

(do_while_statement) @loop.outer
(do_while_statement
  body: (_) @loop.inner)

; ---------------------------------------------------------------------------
; Blocks
; ---------------------------------------------------------------------------

(block) @block.outer

; Match arms as block-level textobjects
(match_arm) @block.inner

; ---------------------------------------------------------------------------
; Comments
; ---------------------------------------------------------------------------

(comment) @comment.outer

; ---------------------------------------------------------------------------
; Assignments / Statements
; ---------------------------------------------------------------------------

(variable_declaration) @assignment.outer
(variable_declaration
  name: (identifier) @assignment.lhs)

(assignment_expression) @assignment.outer
(assignment_expression
  left: (_) @assignment.lhs)
(assignment_expression
  right: (_) @assignment.rhs)

; Expression statements
(expression_statement) @statement.outer

; Return statements
(return_statement) @return.outer
(return_statement
  (_) @return.inner)

; ---------------------------------------------------------------------------
; Calls
; ---------------------------------------------------------------------------

(call_expression) @call.outer
(call_expression
  arguments: (arguments) @call.inner)

; ---------------------------------------------------------------------------
; JSX
; ---------------------------------------------------------------------------

(jsx_element) @tag.outer
(jsx_self_closing_element) @tag.outer

; JSX attributes
(jsx_attribute) @parameter.inner

; ---------------------------------------------------------------------------
; Numbers / Strings
; ---------------------------------------------------------------------------

(number) @number.inner
(string) @string.inner
(template_string) @string.inner
