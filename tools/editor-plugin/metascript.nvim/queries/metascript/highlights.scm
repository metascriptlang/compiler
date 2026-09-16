; MetaScript Syntax Highlighting Queries
; Comprehensive highlights following nvim-treesitter ecma/typescript patterns
; Covers all 143 named node types in the MetaScript tree-sitter grammar

; ===========================================================================
; Variables — BASELINE (must be FIRST so all other rules override it)
; ===========================================================================

(identifier) @variable

; ===========================================================================
; Special Identifiers (predicates override baseline)
; ===========================================================================

; PascalCase identifiers are types (TypeScript convention)
((identifier) @type
  (#lua-match? @type "^[A-Z]"))

; UPPER_CASE identifiers are constants
((identifier) @constant
  (#lua-match? @constant "^_*[A-Z][A-Z%d_]*$"))

; Built-in globals
((identifier) @variable.builtin
  (#any-of? @variable.builtin
    "arguments" "module" "window" "document" "globalThis"
    "process" "exports" "require" "__dirname" "__filename"
    "self"))

; Built-in classes / namespaces
((identifier) @type.builtin
  (#any-of? @type.builtin
    "Object" "Function" "Boolean" "Symbol" "Number" "Math" "Date" "String" "RegExp"
    "Map" "Set" "WeakMap" "WeakSet" "Promise" "Proxy" "Reflect" "Intl" "BigInt"
    "Array" "Buffer" "Pointer" "ArrayBuffer" "DataView"
    "Int8Array" "Uint8Array" "Uint8ClampedArray" "Int16Array" "Uint16Array"
    "Int32Array" "Uint32Array" "Float32Array" "Float64Array" "BigInt64Array" "BigUint64Array"
    "Error" "EvalError" "RangeError" "ReferenceError" "SyntaxError" "TypeError" "URIError"
    "URL" "URLSearchParams" "TextEncoder" "TextDecoder" "AbortController" "AbortSignal"
    "Blob" "File" "FileReader" "FormData" "Headers" "Request" "Response"
    "ReadableStream" "WritableStream" "TransformStream"
    "console" "JSON"))

; Built-in functions
((identifier) @function.builtin
  (#any-of? @function.builtin
    "eval" "isFinite" "isNaN" "parseFloat" "parseInt"
    "decodeURI" "decodeURIComponent" "encodeURI" "encodeURIComponent"
    "require"))

; NaN and Infinity are number builtins
((identifier) @number
  (#any-of? @number "NaN" "Infinity"))

; ===========================================================================
; Types
; ===========================================================================

; Type identifiers — all type name positions
(type_identifier) @type

; Built-in primitive types: string, number, boolean, void, any, never, unknown
(primitive_type) @type.builtin

; MetaScript sized types: int8, int16, int32, int64, uint8-64, float32, float64, etc.
(metascript_type) @type.builtin

; Type annotation colon
(type_annotation
  ":" @punctuation.delimiter)

; Type parameters and arguments angle brackets
(type_parameters
  [
    "<"
    ">"
  ] @punctuation.bracket)

; type_arguments — angle brackets are internal to generic_type, not matchable here

; Union/intersection/discriminated-union operators are internal to their node types
; and not matchable as children — highlighting handled by the generic operator rules

; Discriminated variant key
(discriminated_variant
  key: (identifier) @variable.member)

; Object type property names
(object_type_property
  name: (identifier) @variable.member)

; Parenthesized type
(parenthesized_type
  [
    "("
    ")"
  ] @punctuation.bracket)

; Generic type: TypeName<T> — capture the type name
(generic_type
  (type_identifier) @type)

; Array type brackets: Type[]
(array_type
  [
    "["
    "]"
  ] @punctuation.bracket)

; Object type braces
(object_type
  [
    "{"
    "}"
  ] @punctuation.bracket)

; Function type arrow
(function_type
  "=>" @punctuation.special)

; Function type named parameters
(function_type_parameter
  name: (identifier) @variable.parameter)

; ===========================================================================
; Function/Method Declarations
; ===========================================================================

; Function declarations
(function_declaration
  name: (_) @function)

; Method declarations
(method_declaration
  name: (_) @function.method)

; Lifecycle hook function declarations
(function_declaration
  name: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

; Lifecycle hook method declarations
(method_declaration
  name: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

; Variable assigned arrow function → treat as function
(variable_declaration
  name: (identifier) @function
  (arrow_function))

; Variable assigned arrow function → treat as function (with type annotation between)
(variable_declaration
  name: (identifier) @function
  (type_annotation)
  (arrow_function))

; Class declarations — name is type_identifier, caught by (type_identifier) @type
; Interface declarations — same
; Struct declarations — same
; Enum declarations — same

; Interface properties
(interface_property
  name: (identifier) @variable.member)

; Interface methods
(interface_method
  name: (identifier) @function.method)

; Property declarations (in class bodies)
(property_declaration
  name: (identifier) @variable.member)

; Enum members
(enum_member
  (identifier) @constant)

; Extern enum members
(extern_enum_member
  (identifier) @constant)

; Type alias declaration name
(type_alias_declaration
  name: (type_identifier) @type)

; ===========================================================================
; Function/Method Calls
; ===========================================================================

; Direct function calls: foo()
(call_expression
  function: (identifier) @function.call)

; Method calls: obj.method()
(call_expression
  function: (member_expression
    property: (_) @function.method.call))

; Generic function calls: foo<T>()
(generic_call_expression
  function: (identifier) @function.call)

; Generic method calls: obj.method<T>()
(generic_call_expression
  function: (member_expression
    property: (_) @function.method.call))

; Await then call: await foo()
(call_expression
  function: (await_expression
    (identifier) @function.call))

; Await then method call: await obj.method()
(call_expression
  function: (await_expression
    (member_expression
      property: (_) @function.method.call)))

; Lifecycle hook calls
(call_expression
  function: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

(call_expression
  function: (member_expression
    property: (identifier) @function.builtin)
  (#lua-match? @function.builtin "^on[A-Z]"))

; Constructor: new Foo()
(new_expression
  (identifier) @constructor)

(new_expression
  (member_expression
    property: (_) @constructor))

; ===========================================================================
; Member Access
; ===========================================================================

; Property access: obj.property (must come before function call rules in priority,
; but tree-sitter uses last-match-wins, so call rules above override this)
(member_expression
  property: (_) @variable.member)

; Object literal properties: { key: value }
(pair
  key: (identifier) @variable.member)

; Shorthand property: { name }
(shorthand_property
  (identifier) @variable.member)

; ===========================================================================
; Parameters — Comprehensive
; ===========================================================================

; Regular parameters
(parameter
  name: (_) @variable.parameter)

; Arrow function single parameter: x => ...
(arrow_function
  parameters: (identifier) @variable.parameter)

; Arrow function named parameters
(arrow_function_parameter
  name: (identifier) @variable.parameter)

; Rest parameters: ...args
(rest_parameter
  "..." @operator
  name: (identifier) @variable.parameter)

; Destructuring patterns in parameters
; Array pattern element
(pattern_element
  name: (identifier) @variable.parameter)

; Object pattern property (shorthand): ({ a })
(pattern_property
  name: (identifier) @variable.parameter)

; Object pattern property with alias: ({ a: b })
(pattern_property
  key: (identifier) @variable.member
  value: (identifier) @variable.parameter)

; Rest pattern in destructuring: ...rest
(rest_pattern
  "..." @operator
  name: (identifier) @variable.parameter)

; Extension method receiver parameters: function trim(this self: string)
(this_parameter
  "this" @variable.builtin)

(this_parameter
  "typeof" @keyword.operator)

(this_parameter
  name: (_) @variable.parameter)

(this_parameter
  receiver_type: (type
    (primitive_type) @type.builtin))

; ===========================================================================
; Variables
; ===========================================================================

; Variable declarations
(variable_declaration
  name: (identifier) @variable)

; Labeled statements
(labeled_statement
  label: (identifier) @label)

; ===========================================================================
; Match Expression (MetaScript-specific)
; ===========================================================================

; Match expression keyword
(match_expression
  "match" @keyword.conditional)

; Match or-pattern pipe
(match_or_pattern
  "|" @punctuation.delimiter)

; Match array pattern brackets
(match_array_pattern
  [
    "["
    "]"
  ] @punctuation.bracket)

; Match literal patterns
(match_literal_pattern
  (string) @string)
(match_literal_pattern
  (number) @number)
(match_literal_pattern
  (boolean) @boolean)

; Match arm arrow
(match_arm
  "=>" @punctuation.special)

; Match wildcard pattern: _
(match_wildcard) @variable.builtin

; Match binding pattern (variable capture)
(match_binding_pattern
  (identifier) @variable.parameter)

; Match guard
(match_arm
  guard: (_) @keyword.conditional)

; ===========================================================================
; Decorators / Macros (MetaScript-specific)
; ===========================================================================

; User-defined decorators: @MyDecorator
(macro_decorator
  "@" @attribute
  name: (identifier) @attribute)

; @comptime blocks
(macro_comptime
  "@comptime" @attribute)

; @target blocks (conditional compilation)
(macro_target_block
  "@target" @attribute)

; @emit statements (raw backend code)
(macro_emit_statement
  "@emit" @attribute)

; @emit expression (in return statements etc.)
(macro_emit_expr
  "@emit" @attribute)

; @extern statements (native bindings)
(macro_extern_statement
  "@extern" @attribute)

; Macro declarations
(macro_declaration
  name: (identifier) @function.macro)

; Extern macro declarations
(extern_macro
  name: (macro_name
    "@" @attribute
    (identifier) @attribute))

; Compiler directive statements: @include("..."); @compile("..."); etc.
(macro_directive_statement
  (macro_decorator
    "@" @attribute
    name: (identifier) @attribute))

; ===========================================================================
; Extern Declarations (MetaScript-specific)
; ===========================================================================

; Extern declaration keyword
(extern_declaration
  "extern" @keyword)

(extern_function
  name: (_) @function)

(extern_method
  "extern" @keyword
  name: (_) @function.method
  "from" @keyword.import)

; Operator identifiers (backtick-quoted: `==`, `<`, `[]`, etc.)
; Highlight as function name — the backticks are part of the token
; but the semantic meaning is "this is a function/method name".
(operator_identifier) @function

(class_extern_method
  (macro_decorator
    "@" @attribute
    name: (identifier) @attribute))
(class_extern_method
  name: (_) @function.method)
(class_extern_method
  "static" @keyword.modifier)
(class_extern_method
  "extern" @keyword)
(class_extern_method
  "from" @keyword.import)

(extern_class
  "from" @keyword.import)

(extern_var
  "from" @keyword.import)

(extern_const
  "from" @keyword.import)

(extern_enum
  "from" @keyword.import)

(extern_macro
  "from" @keyword.import)

(extern_function
  "from" @keyword.import)

; ===========================================================================
; Test Declarations (MetaScript-specific)
; ===========================================================================

(test_declaration
  name: (string) @string)

; ===========================================================================
; Literals
; ===========================================================================

[
  (this)
] @variable.builtin

[
  (null)
  (undefined)
] @constant.builtin

(boolean) @boolean

(number) @number

(string) @string

(template_string) @string

; Template string interpolation: ${ }
(template_string
  "${" @punctuation.special
  "}" @punctuation.special)

; Comments
(comment) @comment @spell

; Documentation comments: /** ... */
((comment) @comment.documentation
  (#lua-match? @comment.documentation "^/[*][*][^*].*[*]/$"))

; ===========================================================================
; Keywords — Conditional
; ===========================================================================

[
  "if"
  "else"
  "switch"
  "case"
  "match"
  "when"
] @keyword.conditional

; default in switch
(switch_default
  "default" @keyword.conditional)

; ===========================================================================
; Keywords — Repeat / Loop
; ===========================================================================

[
  "for"
  "of"
  "in"
  "do"
  "while"
  "continue"
] @keyword.repeat

; ===========================================================================
; Keywords — Return / Yield
; ===========================================================================

"return" @keyword.return

; ===========================================================================
; Keywords — Function
; ===========================================================================

"function" @keyword.function

; ===========================================================================
; Keywords — Operator
; ===========================================================================

[
  "new"
  "typeof"
] @keyword.operator

; as in type assertions
(type_assertion_expression
  "as" @keyword.operator)

; ===========================================================================
; Keywords — Exception / Error Handling
; ===========================================================================

[
  "try"
  "catch"
] @keyword.exception

; ===========================================================================
; Keywords — Import / Export
; ===========================================================================

[
  "import"
  "export"
] @keyword.import

; from in import/export statements
(import_statement
  "from" @keyword.import)
(import_statement
  "as" @keyword.import)
(export_statement
  "from" @keyword.import)

; ===========================================================================
; Keywords — Type Definitions
; ===========================================================================

[
  "interface"
  "enum"
  "type"
  "struct"
  "class"
  "actor"
] @keyword.type

; ===========================================================================
; Keywords — Coroutine
; ===========================================================================

; async in function declarations
(function_declaration
  "async" @keyword.coroutine)

; async in arrow functions
(arrow_function
  "async" @keyword.coroutine)

; await in await expressions
(await_expression
  "await" @keyword.coroutine)

; await in for-await-of
(for_of_statement
  "await" @keyword.coroutine)

; ===========================================================================
; Keywords — Modifiers
; ===========================================================================

[
  "readonly"
  "static"
] @keyword.modifier

; ===========================================================================
; Keywords — General
; ===========================================================================

[
  "const"
  "let"
  "var"
  "extends"
  "implements"
  "break"
  "default"
] @keyword

; export default
(export_statement
  "default" @keyword)

; ===========================================================================
; Keywords — MetaScript-specific
; ===========================================================================

[
  "extern"
  "macro"
  "distinct"
] @keyword

[
  "defer"
  "move"
  "borrow"
  "out"
] @keyword

"test" @keyword

"expect" @keyword

; try expression: try expr catch fallback
(try_expression
  "try" @keyword.exception)
(try_expression
  "catch" @keyword.exception)

; defer statement
(defer_statement
  "defer" @keyword)

; expect statement
(expect_statement
  "expect" @keyword)

; unreachable statement
(unreachable_statement
  "unreachable" @keyword)

; ===========================================================================
; Operators
; ===========================================================================

[
  "--"
  "-"
  "-="
  "+"
  "++"
  "+="
  "*"
  "**"
  "*="
  "/"
  "/="
  "%"
  "="
  "=="
  "==="
  "!="
  "!=="
  "<"
  "<="
  ">"
  ">="
  "<<"
  ">>"
  ">>>"
  "&&"
  "||"
  "&"
  "|"
  "^"
  "~"
  "!"
  "?"
  "??"
  "..."
  ".."
  "|>"
] @operator

; Ternary operator ? : — special category
(ternary_expression
  [
    "?"
    ":"
  ] @keyword.conditional.ternary)

; Binary division (disambiguated from comment slash)
(binary_expression
  "/" @operator)

; Arrow function =>
(arrow_function
  "=>" @punctuation.special)

; Match arm =>
(match_arm
  "=>" @punctuation.special)

; ===========================================================================
; Punctuation — Brackets
; ===========================================================================

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

; ===========================================================================
; Punctuation — Delimiters
; ===========================================================================

[
  ";"
  "."
  ","
  ":"
] @punctuation.delimiter

; ===========================================================================
; JSX Syntax Highlighting
; ===========================================================================

; JSX element tags (lowercase = HTML, uppercase = component)
(jsx_opening_element
  name: (identifier) @tag)

(jsx_closing_element
  name: (identifier) @tag)

(jsx_self_closing_element
  name: (identifier) @tag)

; JSX member expression tags (e.g., Foo.Bar)
(jsx_member_expression
  object: (identifier) @tag
  property: (identifier) @tag)

; JSX namespaced names (e.g., svg:rect)
(jsx_namespaced_name
  (identifier) @tag)

; JSX attributes
(jsx_attribute
  name: (identifier) @tag.attribute)

; JSX attribute string values
(jsx_attribute
  value: (string) @string)

; JSX text content
(jsx_text) @string

; JSX expression container braces
(jsx_expression_container
  "{" @punctuation.special
  "}" @punctuation.special)

; JSX spread attribute
(jsx_spread_attribute
  "{" @punctuation.special
  "..." @operator
  "}" @punctuation.special)

; JSX fragment delimiters
(jsx_fragment
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; JSX tag delimiters
(jsx_opening_element
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

(jsx_closing_element
  "<" @punctuation.bracket
  "/" @punctuation.bracket
  ">" @punctuation.bracket)

(jsx_self_closing_element
  "<" @punctuation.bracket
  "/" @punctuation.bracket
  ">" @punctuation.bracket)
