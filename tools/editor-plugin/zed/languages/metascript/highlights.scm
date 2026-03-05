; Metascript Syntax Highlighting Queries
; Synced from: tree-sitter-metascript/queries/highlights.scm

; Keywords (true keywords that cannot be identifiers in any context)
; NOTE: Contextual keywords (async, from, as, get, set, delete, catch, finally, await)
; are NOT in this list - they're highlighted based on structural context
[
  ; JavaScript/TypeScript core
  "class"
  "interface"
  "function"
  "const"
  "let"
  "var"
  "return"
  "if"
  "else"
  "for"
  "while"
  "new"
  "extends"
  "implements"
  ; TypeScript
  "type"
  ; ES modules
  "import"
  "export"
  "default"
  ; Metascript
  "macro"
  "extern"
  "defer"
  "distinct"
  "unreachable"
  "match"
  "when"
  "test"
  "expect"
  "move"
  "out"
  "borrow"
  ; Error handling
  "try"
  "catch"
  ; Extension methods
  "typeof"
] @keyword

; ===========================================================================
; Match Expression
; ===========================================================================

; Match arm arrow
(match_arm
  "=>" @punctuation.special)

; Match wildcard pattern
(match_wildcard) @variable.builtin

; Match binding pattern (variable capture)
(match_binding_pattern
  (identifier) @variable.parameter)

; ===========================================================================
; Type Assertion (as)
; ===========================================================================

; as keyword in type assertion: expr as Type
(type_assertion_expression
  "as" @keyword)

; Object type property names: { name: string }
(object_type_property
  name: (identifier) @property)

; Metascript-specific: Macro decorators (user macros applied to classes)
(macro_decorator
  "@" @keyword.directive
  name: (identifier) @keyword.directive)

; Metascript-specific: @comptime blocks
(macro_comptime
  "@comptime" @keyword.directive)

; Metascript-specific: macro declaration
(macro_declaration
  name: (identifier) @function.macro)

; Metascript-specific: @target blocks (conditional compilation)
(macro_target_block
  "@target" @keyword.directive)

; Metascript-specific: @emit statements (raw backend code)
(macro_emit_statement
  "@emit" @keyword.directive)

; Metascript-specific: @extern statements (native bindings)
(macro_extern_statement
  "@extern" @keyword.directive)

; Metascript-specific: extern macro declarations
(extern_macro
  name: (macro_name
    "@" @keyword.directive
    (identifier) @function.macro))

; ===========================================================================
; Variables - BASELINE (must be FIRST so all other rules override it)
; ===========================================================================
(identifier) @variable

; ===========================================================================
; Built-in Identifiers (predicates have higher priority than positional rules)
; ===========================================================================

; Uppercase identifiers are types (TypeScript convention)
((identifier) @type
  (#match? @type "^[A-Z]"))

; Built-in globals
((identifier) @variable.builtin
  (#any-of? @variable.builtin
    "arguments" "module" "console" "window" "document" "globalThis"
    "process" "Buffer" "exports" "require" "__dirname" "__filename"))

; Built-in type constructors
((identifier) @type.builtin
  (#any-of? @type.builtin
    "Object" "Function" "Boolean" "Symbol" "Number" "Math" "Date" "String" "RegExp"
    "Map" "Set" "WeakMap" "WeakSet" "Array" "ArrayBuffer" "DataView"
    "Int8Array" "Uint8Array" "Uint8ClampedArray" "Int16Array" "Uint16Array"
    "Int32Array" "Uint32Array" "Float32Array" "Float64Array" "BigInt64Array" "BigUint64Array"
    "Promise" "Proxy" "Reflect" "JSON" "Intl" "BigInt"
    "Error" "EvalError" "RangeError" "ReferenceError" "SyntaxError" "TypeError" "URIError"
    "URL" "URLSearchParams" "TextEncoder" "TextDecoder" "AbortController" "AbortSignal"
    "Blob" "File" "FileReader" "FormData" "Headers" "Request" "Response"
    "ReadableStream" "WritableStream" "TransformStream"))

; ===========================================================================
; Types
; ===========================================================================
(primitive_type) @type.builtin
(metascript_type) @type.builtin

; Type identifiers - TypeScript-style: dedicated node type for all type names
; This catches: type aliases, class names, interface names, type annotations, generics
(type_identifier) @type

; ===========================================================================
; Lifecycle Hooks (onDestroy, onCopy, onMove, onMoved)
; Highlighted as special functions - these are reserved extension method names
; ===========================================================================

; Lifecycle hook function declarations
(function_declaration
  name: (identifier) @function.builtin
  (#match? @function.builtin "^on(Destroy|Copy|Move|Moved)$"))

; Lifecycle hook method declarations (in case defined inside class)
(method_declaration
  name: (identifier) @function.builtin
  (#match? @function.builtin "^on(Destroy|Copy|Move|Moved)$"))

; ===========================================================================
; Async keyword (contextual - highlighted in structural context)
; ===========================================================================

; async in function declarations: async function foo()
(function_declaration
  "async" @keyword)

; async in arrow functions: async (x) => ...
(arrow_function
  "async" @keyword)

; await in await expressions: await fetch()
(await_expression
  "await" @keyword)

; await in for-await-of: for await (const x of ...)
(for_of_statement
  "await" @keyword)

; ===========================================================================
; Function/Method declarations
; ===========================================================================

; Use (_) wildcard to match both identifier and _contextual_keyword (get, set, delete, etc.)
(function_declaration
  name: (_) @function)

(method_declaration
  name: (_) @function.method)

; Class declarations - name is now type_identifier (handled by generic rule above)
; (class_declaration name: (type_identifier) @type) - already caught by (type_identifier) @type

; Interface declarations - name is now type_identifier (handled by generic rule above)
; (interface_declaration name: (type_identifier) @type) - already caught by (type_identifier) @type

; Interface properties
(interface_property
  name: (identifier) @property)

; Interface methods
(interface_method
  name: (identifier) @function.method)

; Property declarations
(property_declaration
  name: (identifier) @property)

; Parameters (allow contextual keywords like 'set', 'map', 'delete')
(parameter
  name: (_) @variable.parameter)

; Extension method receiver parameters
; Instance extension: function trim(this self: string): string
; Static extension: function resolve(this typeof Promise, value: number): number
(this_parameter
  "this" @keyword)

(this_parameter
  "typeof" @keyword)

(this_parameter
  name: (_) @variable.parameter)

; Extension receiver type - type_identifier already caught by (type_identifier) @type
; Primitive types still need explicit rule
(this_parameter
  receiver_type: (type
    (primitive_type) @type.builtin))

; Function calls
(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (member_expression
    property: (_) @function.method.call))

; Lifecycle hook calls (when called explicitly)
(call_expression
  function: (identifier) @function.builtin
  (#match? @function.builtin "^on(Destroy|Copy|Move|Moved)$"))

(call_expression
  function: (member_expression
    property: (identifier) @function.builtin)
  (#match? @function.builtin "^on(Destroy|Copy|Move|Moved)$"))

; Member access (allow contextual keywords like 'delete', 'get', 'set')
(member_expression
  property: (_) @property)

; Object literal properties: { key: value } or { key } (shorthand)
(pair
  key: (identifier) @property)

; Shorthand property: { name } instead of { name: name }
(shorthand_property
  (identifier) @property)

; Variables
(variable_declaration
  name: (identifier) @variable)

; Literals
(number) @number
(string) @string
(template_string) @string
(boolean) @boolean
(null) @constant.builtin
(undefined) @constant.builtin
(this) @variable.builtin

; Comments
; Must come BEFORE operator rules to prevent "/" in "*/" from being highlighted as operator
(comment) @comment

; Arrow functions (closures)
(arrow_function
  "=>" @punctuation.special)

; Arrow function parameters
(arrow_function_parameter
  name: (identifier) @variable.parameter)

; Rest/spread parameter
(rest_parameter
  "..." @operator
  name: (identifier) @variable.parameter)

; Destructuring patterns in arrow function parameters
; Array pattern element
(pattern_element
  name: (identifier) @variable.parameter)

; Object pattern property (shorthand)
(pattern_property
  name: (identifier) @variable.parameter)

; Object pattern property (with alias)
(pattern_property
  key: (identifier) @property
  value: (identifier) @variable.parameter)

; Rest pattern in destructuring
(rest_pattern
  "..." @operator
  name: (identifier) @variable.parameter)

; Function type
(function_type
  "=>" @punctuation.special)

; Function type named parameter
(function_type_parameter
  name: (identifier) @variable.parameter)

; Operators
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "**"
  "="
  "==="
  "!=="
  "=="
  "!="
  "+="
  "-="
  "*="
  "/="
  "%="
  "<"
  ">"
  "<="
  ">="
  "&&"
  "||"
  "!"
  "~"
  "&"
  "|"
  "^"
  "<<"
  ">>"
  ">>>"
  "++"
  "--"
  "?"
  "??"
  "?."
  ":"
  "..."
  ".."
  "|>"
] @operator

; Punctuation
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  ";"
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
  name: (identifier) @attribute)

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
