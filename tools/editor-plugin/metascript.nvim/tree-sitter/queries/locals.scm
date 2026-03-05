; MetaScript locals (scope tracking) queries for nvim-treesitter.
; Enables scope-aware highlighting, go-to-definition, and rename.

; ---------------------------------------------------------------------------
; Scopes
; ---------------------------------------------------------------------------

; Top-level program
(program) @local.scope

; Function scopes
(function_declaration) @local.scope
(function_body) @local.scope
(macro_declaration) @local.scope
(macro_body) @local.scope
(method_declaration) @local.scope

; Arrow function scopes
(arrow_function) @local.scope

; Block scopes
(block) @local.scope

; Control flow scopes
(if_statement) @local.scope
(for_statement) @local.scope
(for_of_statement) @local.scope
(for_in_statement) @local.scope
(while_statement) @local.scope
(do_while_statement) @local.scope

; Match expression scopes (each arm is a scope)
(match_expression) @local.scope
(match_arm) @local.scope

; Switch scopes
(switch_case) @local.scope
(switch_default) @local.scope

; Class / interface scopes
(class_declaration) @local.scope
(interface_declaration) @local.scope

; ---------------------------------------------------------------------------
; Definitions
; ---------------------------------------------------------------------------

; Variable declarations: const x, let x, var x
(variable_declaration
  name: (identifier) @local.definition.var)

; Function declarations
(function_declaration
  name: (_) @local.definition.function)

; Macro declarations
(macro_declaration
  name: (identifier) @local.definition.function)

; Class declarations
(class_declaration
  name: (type_identifier) @local.definition.type)

; Interface declarations
(interface_declaration
  name: (type_identifier) @local.definition.type)

; Enum declarations
(enum_declaration
  name: (identifier) @local.definition.type)

; Enum members
(enum_member
  name: (identifier) @local.definition.var)

; Type alias declarations
(type_alias_declaration
  name: (type_identifier) @local.definition.type)

; Function parameters
(parameter
  name: (_) @local.definition.parameter)

; Extension method receiver parameters
(this_parameter
  name: (_) @local.definition.parameter)

; Arrow function parameters
(arrow_function_parameter
  name: (identifier) @local.definition.parameter)

; Rest parameters
(rest_parameter
  name: (identifier) @local.definition.parameter)

; Destructuring pattern elements
(pattern_element
  name: (identifier) @local.definition.var)

; Destructuring pattern properties (shorthand)
(pattern_property
  name: (identifier) @local.definition.var)

; Destructuring pattern properties (aliased)
(pattern_property
  value: (identifier) @local.definition.var)

; Rest pattern in destructuring
(rest_pattern
  name: (identifier) @local.definition.var)

; For-of loop variable
(for_of_statement
  name: (identifier) @local.definition.var)

; For-in loop variable
(for_in_statement
  name: (identifier) @local.definition.var)

; Match binding patterns (capture variables)
(match_binding_pattern
  (identifier) @local.definition.var)

; Import bindings
(import_clause
  (identifier) @local.definition.import)

(import_statement
  (identifier) @local.definition.import)

; Class properties
(property_declaration
  name: (identifier) @local.definition.field)

; Interface properties
(interface_property
  name: (identifier) @local.definition.field)

; Method declarations
(method_declaration
  name: (identifier) @local.definition.method)

; Interface methods
(interface_method
  name: (identifier) @local.definition.method)

; ---------------------------------------------------------------------------
; References
; ---------------------------------------------------------------------------

(identifier) @local.reference

; Type references
(type_identifier) @local.reference
