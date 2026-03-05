/**
 * Metascript Grammar for Tree-sitter
 * TypeScript syntax + compile-time macros + multi-backend
 *
 * Synced with: src/lexer/token.zig (via tokens-generated.js)
 */

module.exports = grammar({
  name: 'metascript',

  extras: $ => [/\s/, $.comment],

  conflicts: $ => [
    [$.block, $.object],
    [$.parameter, $._expression],
    [$.function_body_statement, $._macro_body_statement],
    [$.macro_emit_statement, $.macro_emit_expr],
    // Arrow function vs parenthesized expression: (x) => vs (x)
    [$.arrow_function_parameter, $._expression],
    // Type identifier conflicts - identifier can be both type and expression
    [$._type_identifier, $._expression],
    [$._type_identifier, $.arrow_function],
    [$._type_identifier, $.arrow_function_parameter],
    [$._type_identifier, $._simple_type],
    [$._type_identifier, $._simple_type, $._expression, $.arrow_function_parameter],
    [$._type_identifier, $._expression, $.arrow_function_parameter],
    // Type annotation vs expression in various contexts
    [$.type, $._expression],
    [$.generic_type, $._expression],
    // Arrow function vs type (both use =>)
    [$.type, $.arrow_function],
    // Arrow function with return type vs expression
    [$._expression, $.arrow_function],
    // Function type vs arrow function params (both start with '(')
    [$.function_type, $.arrow_function_parameters],
    // Parenthesized type vs function type
    [$.parenthesized_type, $.function_type],
    // Type vs arrow function parameter vs expression (3-way)
    [$.type, $.arrow_function_parameter, $._expression],
    // Type vs arrow function parameter (2-way for , case)
    [$.type, $.arrow_function_parameter],
    // Parenthesized expression vs arrow function params (both start with '(')
    [$.parenthesized_expression, $.arrow_function_parameters],
    [$.arrow_function_parameter, $.parenthesized_expression],
    // Assignment expression vs arrow function parameter default value
    [$.assignment_expression, $.arrow_function_parameter],
    // More specific: entire expression sequence in parens
    [$.parenthesized_expression, $.arrow_function],
    [$.assignment_expression, $.arrow_function_parameters],
    // Function type parameter vs type (named param vs just type)
    [$.function_type_parameter, $.type],
    // Function type parameter vs type annotation (x: T in function type vs type annotation)
    [$.function_type_parameter, $.type_annotation],
    // Parenthesized type vs function type parameter (both can be (T))
    [$.parenthesized_type, $.function_type_parameter],
    // Simple type vs arrow function parameter (both can be just identifier)
    [$._simple_type, $.arrow_function_parameter],
    // 4-way conflict for identifier in parens after colon
    [$.type, $._simple_type, $._expression, $.arrow_function_parameter],
    // Type vs simple type (simple_type is subset of type)
    [$.type, $._simple_type],
    // Destructuring: {} could be object or object_pattern
    [$.object, $.object_pattern],
    // Destructuring: [] could be array or array_pattern
    [$.array, $.array_pattern],
    // Destructuring: identifier in pattern vs expression
    [$._expression, $.pattern_element],
    // Destructuring: {x: y} could be object pair or pattern property with alias
    [$._expression, $.pattern_property],
    // Destructuring: {x} could be object or pattern property shorthand
    [$.pair, $.pattern_property],
    // Shorthand property vs pattern property: { x } in object vs destructuring
    [$.shorthand_property, $.pattern_property],
    // JSX vs type parameters: <div> vs <T>
    [$.type_parameters, $._jsx_element_name],
    // Match pattern conflicts - identifier could be match binding or arrow function
    [$.match_binding_pattern, $.arrow_function],
    [$.match_binding_pattern, $._expression],
    [$.match_literal_pattern, $._expression],
    [$.match_array_pattern, $.array],
    // Object type vs object literal/block - both start with '{'
    [$.object_type, $.object, $.block],
    [$.object_type, $.object],
    [$.object_type, $.block],
    [$.object_type, $.object_pattern],
    [$.object_type, $.object, $.object_pattern],
    // Object type property vs pair/expression (object literal key: value, ternary ?)
    [$.object_type_property, $.pair],
    [$.object_type_property, $.pattern_property],
    [$.object_type_property, $._expression],
    // Object type property type_identifier vs expression/pattern_property
    [$._type_identifier, $._expression, $.pattern_property],
    // Type assertion: 'as' keyword vs 'as' contextual identifier
    [$.type_assertion_expression, $._expression],
    // Type assertion + generic: expr as Identifier<T> vs expr as Identifier < expr
    [$.type, $.generic_type],
  ],

  word: $ => $.identifier,

  rules: {
    program: $ => repeat($._statement),

    // =========================================================================
    // Statements
    // =========================================================================

    _statement: $ => choice(
      $.import_statement,
      $.export_statement,
      $.class_declaration,
      $.interface_declaration,
      $.enum_declaration,
      $.function_declaration,
      $.macro_declaration,
      $.extern_declaration,
      $.variable_declaration,
      $.type_alias_declaration,
      $.test_declaration,
      $.expect_statement,
      $.defer_statement,
      $.return_statement,
      $.unreachable_statement,
      $.if_statement,
      $.switch_statement,
      $.for_statement,
      $.for_of_statement,
      $.for_in_statement,
      $.while_statement,
      $.do_while_statement,
      $.break_statement,
      $.continue_statement,
      $.labeled_statement,
      $.expression_statement,
      $.block,
    ),

    // =========================================================================
    // Imports / Exports
    // =========================================================================

    import_statement: $ => seq(
      'import',
      choice(
        // import { foo, bar } from "module"
        seq($.import_clause, 'from', $.string),
        // import * as Utils from "module"
        seq('*', 'as', $.identifier, 'from', $.string),
        // import MyModule from "module"
        seq($.identifier, 'from', $.string),
      ),
      optional(';'),
    ),

    import_clause: $ => seq(
      '{',
      commaSep1(choice(
        $.identifier,
        seq($.identifier, 'as', $.identifier),  // aliased import
      )),
      '}',
    ),

    export_statement: $ => choice(
      // export { foo, bar } from "module" - re-export
      seq('export', '{', commaSep1($.identifier), '}', 'from', $.string, optional(';')),
      // export { foo, bar }
      seq('export', '{', commaSep1($.identifier), '}', optional(';')),
      // export default ...
      seq('export', 'default', choice($.function_declaration, $.class_declaration, $._expression), optional(';')),
      // export const/let/function/class/interface/enum/type/macro/extern
      seq('export', choice(
        $.variable_declaration,
        $.function_declaration,
        $.class_declaration,
        $.interface_declaration,
        $.enum_declaration,
        $.type_alias_declaration,
        $.macro_declaration,
        $.extern_declaration,
        $.test_declaration,
      )),
    ),

    // Metascript: test declaration
    // test "name" { ... }
    test_declaration: $ => seq(
      'test',
      field('name', $.string),
      field('body', $.block),
    ),

    // Metascript: expect statement
    // expect expr;
    expect_statement: $ => seq(
      'expect',
      $._expression,
      ';',
    ),

    // Metascript: defer statement
    defer_statement: $ => seq('defer', choice($._expression, $.block), ';'),

    // =========================================================================
    // Declarations
    // =========================================================================

    class_declaration: $ => seq(
      repeat($.macro_decorator),
      'class',
      field('name', $._type_identifier),
      optional($.type_parameters),
      optional(seq('extends', $.type)),
      optional(seq('implements', commaSep1($.type))),
      field('body', $.class_body),
    ),

    class_body: $ => seq(
      '{',
      repeat(choice($.property_declaration, $.method_declaration)),
      '}',
    ),

    interface_declaration: $ => seq(
      'interface',
      field('name', $._type_identifier),
      optional($.type_parameters),
      optional(seq('extends', commaSep1($.type))),
      field('body', $.interface_body),
    ),

    interface_body: $ => seq(
      '{',
      repeat(choice($.interface_property, $.interface_method)),
      '}',
    ),

    interface_property: $ => seq(
      field('name', $.identifier),
      optional('?'),  // optional property
      $.type_annotation,
      ';',
    ),

    interface_method: $ => seq(
      field('name', $.identifier),
      optional('?'),  // optional method
      $.parameters,
      optional($.type_annotation),
      ';',
    ),

    enum_declaration: $ => seq(
      'enum',
      field('name', $.identifier),
      field('body', $.enum_body),
    ),

    enum_body: $ => seq(
      '{',
      optional(seq(
        $.enum_member,
        repeat(seq(',', $.enum_member)),
        optional(','),  // trailing comma
      )),
      '}',
    ),

    enum_member: $ => seq(
      field('name', $.identifier),
      optional(seq('=', field('value', $._expression))),
    ),

    property_declaration: $ => seq(
      repeat($.macro_decorator),
      field('name', $.identifier),
      optional($.type_annotation),
      optional(seq('=', $._expression)),
      ';',
    ),

    method_declaration: $ => seq(
      repeat($.macro_decorator),
      field('name', $.identifier),
      $.parameters,
      optional($.type_annotation),
      field('body', $.block),
    ),

    function_declaration: $ => seq(
      repeat($.macro_decorator),
      optional('async'),
      'function',
      field('name', $._identifier_or_keyword),
      optional($.type_parameters),
      $.parameters,
      optional($.type_annotation),
      field('body', $.function_body),
    ),

    // Function body can contain @extern statements
    function_body: $ => seq('{', repeat($.function_body_statement), '}'),

    function_body_statement: $ => choice(
      $.macro_extern_statement,
      $.macro_target_block,
      $.macro_emit_statement,
      $._statement,
    ),

    // Metascript: macro declaration
    // Syntax: macro name(params) { ... }
    // Usage: name(args) - called like normal function
    macro_declaration: $ => seq(
      'macro',
      field('name', $.identifier),
      optional($.type_parameters),
      $.parameters,
      optional($.type_annotation),
      field('body', $.macro_body),
    ),

    // Metascript: extern declaration (FFI / compiler intrinsics)
    // extern function printf(fmt: string): i32;
    // extern class FILE;
    // extern macro target(...): void;
    // extern const BUILD_VERSION: string;
    extern_declaration: $ => seq(
      repeat($.macro_decorator),  // @native, @library, @include, @target
      'extern',
      choice(
        $.extern_function,
        $.extern_var,
        $.extern_const,
        $.extern_class,
        $.extern_enum,
        $.extern_macro,
      ),
    ),

    extern_function: $ => seq(
      'function',
      field('name', $.identifier),
      optional($.type_parameters),
      $.parameters,
      optional($.type_annotation),
      ';',
    ),

    extern_class: $ => seq(
      'class',
      field('name', $.identifier),
      optional($.type_parameters),
      optional(seq('extends', $.type)),
      choice(
        ';',  // Opaque: extern class FILE;
        $.extern_class_body,  // With fields: extern class stat_t { ... }
      ),
    ),

    extern_class_body: $ => seq(
      '{',
      repeat(choice(
        $.interface_property,  // Reuse interface property syntax
        $.interface_method,    // Reuse interface method syntax
      )),
      '}',
    ),

    extern_macro: $ => seq(
      'macro',
      field('name', $.macro_name),  // @target, @emit, etc.
      optional($.type_parameters),
      $.parameters,
      optional($.type_annotation),
      ';',
    ),

    // Macro name: @ followed by identifier (e.g., @target, @emit)
    macro_name: $ => seq('@', $.identifier),

    extern_var: $ => seq(
      'var',
      field('name', $.identifier),
      optional(seq('as', $.string)),  // Optional C name
      $.type_annotation,
      ';',
    ),

    extern_const: $ => seq(
      'const',
      field('name', $.identifier),
      optional(seq('as', $.string)),  // Optional C name
      $.type_annotation,
      ';',
    ),

    extern_enum: $ => seq(
      'enum',
      field('name', $.identifier),
      optional(seq('as', $.string)),  // Optional C name
      '{',
      optional(seq($.extern_enum_member, repeat(seq(',', $.extern_enum_member)))),
      optional(','),
      '}',
    ),

    extern_enum_member: $ => seq(
      field('name', $.identifier),
      optional(seq('=', $._expression)),  // Optional value
    ),

    // Macro body can contain @target blocks and @emit statements
    macro_body: $ => seq('{', repeat($._macro_body_statement), '}'),

    _macro_body_statement: $ => choice(
      $.macro_target_block,
      $.macro_emit_statement,
      $._statement,
    ),

    // @target("c") { ... } else { ... } - conditional compilation with else
    // @target("c", "js") { ... } - multiple targets
    macro_target_block: $ => seq(
      '@target',
      '(',
      commaSep1($.string),  // Support multiple targets: @target("c", "js")
      ')',
      $.macro_target_body,
      optional($.macro_target_else),  // Optional else clause
    ),

    // else { ... } or else @target(...) { ... }
    macro_target_else: $ => seq(
      'else',
      choice(
        $.macro_target_block,  // Chained: else @target("js") { }
        $.macro_target_body,   // Fallback: else { }
      ),
    ),

    macro_target_body: $ => seq('{', repeat(choice($.macro_emit_statement, $._statement)), '}'),

    // @emit("code") - raw backend code emission
    macro_emit_statement: $ => seq(
      '@emit',
      optional($.type_parameters),  // @emit<boolean>("confirm($msg)")
      '(',
      $.string,
      ')',
      optional(';'),
    ),

    // @extern("name") - native function binding (in function body) - legacy
    macro_extern_statement: $ => seq(
      '@extern',
      '(',
      $.string,
      ')',
      ';',
    ),

    variable_declaration: $ => seq(
      choice('const', 'let', 'var'),
      field('name', $.identifier),
      optional($.type_annotation),
      optional(seq('=', $._expression)),
      ';',
    ),

    // Type alias with optional distinct
    type_alias_declaration: $ => seq(
      'type',
      field('name', $._type_identifier),
      optional($.type_parameters),
      '=',
      optional('distinct'),  // Metascript: distinct types
      $.type,
      ';',
    ),

    // =========================================================================
    // Macros (Metascript decorators)
    // =========================================================================

    macro_decorator: $ => seq(
      '@',
      field('name', $.identifier),
      optional($.macro_arguments),
    ),

    macro_arguments: $ => seq('(', optional(commaSep1($._expression)), ')'),

    // =========================================================================
    // Types
    // =========================================================================

    // Type identifier - alias that produces type_identifier node (like TypeScript)
    _type_identifier: $ => alias($.identifier, $.type_identifier),

    type_annotation: $ => seq(':', $.type),

    type: $ => choice(
      $.primitive_type,
      $.metascript_type,
      $._type_identifier,  // Use type_identifier for user-defined types
      $.array_type,
      $.union_type,
      $.generic_type,
      $.function_type,      // (T) => U - closure/function type
      $.parenthesized_type, // (T) - for grouping in complex types
      $.object_type,        // { name: string, age: number }
    ),

    primitive_type: $ => choice(
      'string', 'number', 'boolean', 'char', 'void', 'any', 'unknown', 'never',
    ),

    metascript_type: $ => choice(
      // Sized integer types
      'int8', 'int16', 'int32', 'int64',
      'uint8', 'uint16', 'uint32', 'uint64',
      // Sized float types
      'float32', 'float64',
      // Type aliases
      'int', 'float', 'double',
      // Typed arrays (JavaScript built-in binary data types)
      'Uint8Array', 'Int8Array', 'Uint16Array', 'Int16Array',
      'Uint32Array', 'Int32Array', 'Float32Array', 'Float64Array',
      // BigInt
      'bigint',
    ),

    array_type: $ => prec.left(seq($.type, '[', optional($.number), ']')),

    union_type: $ => prec.left(seq($.type, '|', $.type)),

    generic_type: $ => seq($._type_identifier, '<', commaSep1($.type), '>'),

    // Function type: (T, U) => V or (x: T, y: U) => V or () => void
    // Supports both TypeScript styles:
    //   - Types only: (number, string) => void
    //   - Named params: (x: number, y: string) => void
    // Use prec.dynamic to prefer function_type when => is seen after )
    function_type: $ => prec.dynamic(3, prec.right(2, seq(
      '(',
      optional(commaSep1($.function_type_parameter)),
      ')',
      '=>',
      field('return_type', $.type),
    ))),

    // Function type parameter: either just a type or named (x: type)
    // Uses _simple_type to avoid parenthesized_type ambiguity
    function_type_parameter: $ => choice(
      // Named parameter: x: number
      seq(
        field('name', $.identifier),
        ':',
        field('type', $._simple_type),
      ),
      // Type only: number (uses _simple_type to avoid ambiguity with parenthesized_type)
      $._simple_type,
    ),

    // Simple type - types that don't start with '(' to avoid function_type ambiguity
    _simple_type: $ => choice(
      $.primitive_type,
      $.metascript_type,
      $._type_identifier,
      $.array_type,
      $.union_type,
      $.generic_type,
    ),

    // Parenthesized type for grouping: (string | number)[]
    parenthesized_type: $ => prec(1, seq('(', $.type, ')')),

    // Object type literal: { name: string, age: number }
    object_type: $ => seq(
      '{',
      optional(seq(
        $.object_type_property,
        repeat(seq(choice(',', ';'), $.object_type_property)),
        optional(choice(',', ';')),
      )),
      '}',
    ),

    object_type_property: $ => seq(
      optional('readonly'),
      field('name', $.identifier),
      optional('?'),
      ':',
      field('type', $.type),
    ),

    type_parameters: $ => seq('<', commaSep1($.identifier), '>'),

    parameters: $ => seq('(', optional(commaSep1($.parameter)), ')'),

    parameter: $ => choice(
      // Instance extension receiver: function trim(this self: string): string
      // The 'this' keyword followed by name: Type makes it a method on that type
      $.this_parameter,
      // Normal parameter: name: type = default (allow keywords like 'set', 'map')
      seq(
        optional('...'),  // Rest/variadic parameter
        field('name', $._identifier_or_keyword),
        optional($.type_annotation),
        optional(seq('=', $._expression)),
      ),
    ),

    // Extension method receiver parameter
    // Instance: this name: Type (e.g., this self: string, this set: Set<T>)
    // Static: this typeof Type (e.g., this typeof Promise)
    this_parameter: $ => seq(
      'this',
      choice(
        // Static extension: this typeof Type (no parameter name)
        seq(
          'typeof',
          field('receiver_type', $.type),
        ),
        // Instance extension: this name: Type (allow keywords like 'set', 'map')
        seq(
          field('name', $._identifier_or_keyword),
          ':',
          field('receiver_type', $.type),
        ),
      ),
    ),

    // =========================================================================
    // Control Flow
    // =========================================================================

    block: $ => seq('{', repeat($._statement), '}'),

    return_statement: $ => seq('return', optional($._expression), ';'),

    unreachable_statement: $ => prec.left(choice(
      seq('unreachable', '(', $.string, ')', optional(';')),
      seq('unreachable', ';'),
      prec(-1, seq('unreachable')),
    )),

    if_statement: $ => prec.right(seq(
      'if', '(', $._expression, ')', $._statement,
      optional(seq('else', $._statement)),
    )),

    for_statement: $ => seq(
      'for', '(',
      choice($.variable_declaration, seq(optional($._expression), ';')),
      optional($._expression), ';',
      optional($._expression),
      ')', $._statement,
    ),

    while_statement: $ => seq('while', '(', $._expression, ')', $._statement),

    // do { body } while (condition);
    do_while_statement: $ => seq(
      'do',
      field('body', $._statement),
      'while',
      '(',
      field('condition', $._expression),
      ')',
      optional(';'),
    ),

    // switch (expr) { case value: ... default: ... }
    switch_statement: $ => seq(
      'switch',
      '(',
      field('discriminant', $._expression),
      ')',
      field('body', $.switch_body),
    ),

    switch_body: $ => seq(
      '{',
      repeat(choice($.switch_case, $.switch_default)),
      '}',
    ),

    switch_case: $ => seq(
      'case',
      field('test', $._expression),
      ':',
      repeat($._statement),
    ),

    switch_default: $ => seq(
      'default',
      ':',
      repeat($._statement),
    ),

    // for (const x of iterable) { ... }
    for_of_statement: $ => seq(
      'for',
      optional('await'),  // for await (const x of asyncIterable)
      '(',
      field('kind', choice('const', 'let', 'var')),
      field('name', $.identifier),
      'of',
      field('iterable', $._expression),
      ')',
      field('body', $._statement),
    ),

    // for (const k in obj) { ... }
    for_in_statement: $ => seq(
      'for',
      '(',
      field('kind', choice('const', 'let', 'var')),
      field('name', $.identifier),
      'in',
      field('object', $._expression),
      ')',
      field('body', $._statement),
    ),

    // break; or break label;
    break_statement: $ => seq(
      'break',
      optional(field('label', $.identifier)),
      ';',
    ),

    // continue; or continue label;
    continue_statement: $ => seq(
      'continue',
      optional(field('label', $.identifier)),
      ';',
    ),

    // label: statement
    labeled_statement: $ => seq(
      field('label', $.identifier),
      ':',
      field('body', $._statement),
    ),

    expression_statement: $ => seq($._expression, ';'),

    // =========================================================================
    // Expressions
    // =========================================================================

    _expression: $ => choice(
      $.identifier,
      $.number,
      $.string,
      $.boolean,
      $.null,
      $.undefined,
      $.this,
      $.assignment_expression,
      $.ternary_expression,
      $.binary_expression,
      $.unary_expression,
      $.await_expression,
      $.try_expression,
      $.call_expression,
      $.member_expression,
      $.subscript_expression,
      $.new_expression,
      $.array,
      $.object,
      $.arrow_function,
      $.parenthesized_expression,
      $.macro_comptime,
      $.macro_emit_expr,
      $.match_expression,
      $.type_assertion_expression,
      $.update_expression,
      // JSX expressions
      $.jsx_element,
      $.jsx_fragment,
    ),

    update_expression: $ => choice(
      prec.left(15, seq($._expression, '++')),
      prec.left(15, seq($._expression, '--')),
      prec.right(15, seq('++', $._expression)),
      prec.right(15, seq('--', $._expression)),
    ),

    macro_comptime: $ => seq('@comptime', $.block),

    // @emit<T>("code") as expression (for use in return statements)
    macro_emit_expr: $ => seq(
      '@emit',
      optional($.type_parameters),
      '(',
      $.string,
      ')',
    ),

    assignment_expression: $ => prec.right(1, seq(
      field('left', choice($.identifier, $.member_expression, $.subscript_expression)),
      choice('=', '+=', '-=', '*=', '/='),
      field('right', $._expression),
    )),

    ternary_expression: $ => prec.right(2, seq(
      $._expression, '?', $._expression, ':', $._expression,
    )),

    // =========================================================================
    // Match Expression (Pattern Matching)
    // =========================================================================
    // match (discriminant) {
    //     pattern => expression,
    //     [x, y] => x + y,
    //     _ => default,
    // }

    match_expression: $ => seq(
      'match',
      '(',
      field('discriminant', $._expression),
      ')',
      field('body', $.match_body),
    ),

    match_body: $ => seq(
      '{',
      optional(seq(
        $.match_arm,
        repeat(seq(',', $.match_arm)),
        optional(','),
      )),
      '}',
    ),

    match_arm: $ => seq(
      field('pattern', $._match_pattern),
      optional(seq('when', field('guard', $._expression))),
      '=>',
      field('value', choice($.block, $._expression)),
    ),

    _match_pattern: $ => choice(
      $.match_or_pattern,
      $._match_primary_pattern,
    ),

    // Or-patterns: "debug" | "info" => ...
    match_or_pattern: $ => prec.left(seq(
      $._match_primary_pattern,
      repeat1(seq('|', $._match_primary_pattern)),
    )),

    _match_primary_pattern: $ => choice(
      $.match_wildcard,
      $.match_array_pattern,
      $.match_literal_pattern,
      $.match_binding_pattern,
    ),

    // Wildcard: _
    match_wildcard: $ => '_',

    // Array destructuring: [0, 0], [x, 0], [x, y]
    match_array_pattern: $ => seq(
      '[',
      optional(seq(
        $._match_array_element,
        repeat(seq(',', $._match_array_element)),
        optional(','),
      )),
      ']',
    ),

    _match_array_element: $ => choice(
      $._match_primary_pattern,
    ),

    // Literal patterns: "string", 123, true, false, Status.Pending
    match_literal_pattern: $ => choice(
      $.number,
      $.string,
      $.boolean,
      $.null,
      $.undefined,
      $.member_expression,  // For enum members: Status.Pending
    ),

    // Variable binding: x, myVar (captures the value)
    match_binding_pattern: $ => $.identifier,

    binary_expression: $ => choice(
      prec.left(12, seq($._expression, '*', $._expression)),
      prec.left(12, seq($._expression, '/', $._expression)),
      prec.left(12, seq($._expression, '%', $._expression)),
      prec.left(11, seq($._expression, '+', $._expression)),
      prec.left(11, seq($._expression, '-', $._expression)),
      prec.left(10, seq($._expression, '<<', $._expression)),
      prec.left(10, seq($._expression, '>>', $._expression)),
      prec.left(10, seq($._expression, '>>>', $._expression)),
      prec.left(9, seq($._expression, '<', $._expression)),
      prec.left(9, seq($._expression, '>', $._expression)),
      prec.left(9, seq($._expression, '<=', $._expression)),
      prec.left(9, seq($._expression, '>=', $._expression)),
      prec.left(8, seq($._expression, '===', $._expression)),
      prec.left(8, seq($._expression, '!==', $._expression)),
      prec.left(8, seq($._expression, '==', $._expression)),
      prec.left(8, seq($._expression, '!=', $._expression)),
      prec.left(7, seq($._expression, '&', $._expression)),
      prec.left(6, seq($._expression, '^', $._expression)),
      prec.left(5, seq($._expression, '|', $._expression)),
      prec.left(4, seq($._expression, '&&', $._expression)),
      prec.left(3, seq($._expression, '||', $._expression)),
      prec.left(3, seq($._expression, '??', $._expression)),
      prec.left(2, seq($._expression, '..', $._expression)),
      prec.left(2, seq($._expression, '...', $._expression)),
      prec.left(1, seq($._expression, '|>', $._expression)),
      prec.right(13, seq($._expression, '**', $._expression)),
    ),

    unary_expression: $ => choice(
      prec(14, seq('!', $._expression)),
      prec(14, seq('-', $._expression)),
      prec(14, seq('+', $._expression)),
      prec(14, seq('~', $._expression)),
      prec(14, seq('move', $._expression)),
      prec(14, seq('out', $._expression)),
      prec(14, seq('borrow', $._expression)),
    ),

    // await expression for async/await
    await_expression: $ => prec(14, seq('await', $._expression)),

    // try expression for Result unwrapping: try expr or try expr catch default
    try_expression: $ => prec.right(14, seq(
      'try',
      $._expression,
      optional(seq('catch', $._expression)),
    )),

    // Type assertion: expr as Type (TypeScript-style)
    type_assertion_expression: $ => prec.left(1, seq(
      $._expression,
      'as',
      $.type,
    )),

    call_expression: $ => prec(18, seq(
      field('function', $._expression),
      field('arguments', $.arguments),
    )),

    arguments: $ => seq('(', optional(commaSep1($._expression)), ')'),

    member_expression: $ => prec(18, seq(
      field('object', $._expression),
      '.',
      field('property', $._identifier_or_keyword),
    )),

    // Subscript/index expression: obj[key], arr[0]
    subscript_expression: $ => prec(18, seq(
      field('object', $._expression),
      '[',
      field('index', $._expression),
      ']',
    )),

    new_expression: $ => prec.right(17, seq(
      'new', $._expression, optional(seq('(', optional(commaSep1($._expression)), ')')),
    )),

    array: $ => seq('[', optional(commaSep1($._expression)), ']'),

    object: $ => seq('{', optional(commaSep1(choice($.pair, $.shorthand_property))), '}'),

    pair: $ => seq(
      field('key', choice($.identifier, $.string)),
      ':',
      field('value', $._expression),
    ),

    // Shorthand property: { name } instead of { name: name }
    shorthand_property: $ => $.identifier,

    // Destructuring patterns for arrow function parameters
    // [a, b] or [a, b, ...rest]
    array_pattern: $ => seq(
      '[',
      optional(commaSep1(choice(
        $.pattern_element,
        $.rest_pattern,
      ))),
      ']',
    ),

    // {x, y} or {x: a, y: b} or {x, ...rest}
    object_pattern: $ => seq(
      '{',
      optional(commaSep1(choice(
        $.pattern_property,
        $.rest_pattern,
      ))),
      '}',
    ),

    // Element in array pattern: identifier, nested pattern, or with default
    // NOTE: Type annotations go on the whole pattern, not individual elements
    pattern_element: $ => seq(
      field('name', choice($.identifier, $.array_pattern, $.object_pattern)),
      optional(seq('=', field('default', $._expression))),
    ),

    // Property in object pattern: x or x: alias or x = default
    // NOTE: Type annotations go on the whole pattern, not individual properties
    pattern_property: $ => choice(
      // With alias: { x: alias } or { x: alias = default } (must come first for precedence)
      seq(
        field('key', $.identifier),
        ':',
        field('value', choice($.identifier, $.array_pattern, $.object_pattern)),
        optional(seq('=', field('default', $._expression))),
      ),
      // Shorthand: { x } or { x = default }
      seq(
        field('name', $.identifier),
        optional(seq('=', field('default', $._expression))),
      ),
    ),

    // Rest pattern in destructuring: ...rest
    rest_pattern: $ => seq(
      '...',
      field('name', $.identifier),
    ),

    // Arrow function (closure) with full TypeScript syntax support:
    // - x => x + 1                          (single param, no parens)
    // - (x) => x + 1                        (single param with parens)
    // - (x, y) => x + y                     (multiple params)
    // - (x: number) => x + 1                (typed param)
    // - (x: number): string => x.toString() (with return type)
    // - async (x) => await fetch(x)         (async arrow)
    // - <T>(x: T) => x                      (generic arrow)
    // Use prec.dynamic to prefer arrow function when => is seen
    arrow_function: $ => prec.dynamic(1, prec.right(seq(
      optional('async'),
      optional(field('type_parameters', $.type_parameters)),
      field('parameters', choice(
        $.identifier,                         // x => ...
        $.arrow_function_parameters,          // (x, y) => ... or () => ...
      )),
      optional(field('return_type', $.type_annotation)),  // : ReturnType
      '=>',
      field('body', choice($.block, $._expression)),
    ))),

    // Arrow function parameters - like regular parameters but in parens
    arrow_function_parameters: $ => seq(
      '(',
      optional(commaSep1($.arrow_function_parameter)),
      ')',
    ),

    // Arrow function parameter with full TypeScript support including destructuring
    // Use prec.dynamic to prefer this over assignment_expression when followed by => or ,
    arrow_function_parameter: $ => prec.dynamic(2, choice(
      // Rest parameter: ...args or ...args: string[]
      $.rest_parameter,
      // Destructuring patterns: ([a, b]) => ... or ({x, y}) => ...
      seq(
        field('pattern', choice($.array_pattern, $.object_pattern)),
        optional($.type_annotation),
        optional(seq('=', field('default', $._expression))),
      ),
      // Regular parameter: x or x: number or x = default or x: number = default
      seq(
        field('name', $.identifier),
        optional($.type_annotation),
        optional(seq('=', field('default', $._expression))),
      ),
    )),

    // Rest/spread parameter for functions and arrow functions
    rest_parameter: $ => seq(
      '...',
      field('name', $.identifier),
      optional($.type_annotation),
    ),

    // Lower precedence so arrow_function wins for (x = y) => ...
    parenthesized_expression: $ => prec(-1, seq('(', $._expression, ')')),

    // =========================================================================
    // JSX (TypeScript/React-style)
    // =========================================================================

    // JSX element: <div>...</div> or <Component prop={val} />
    jsx_element: $ => choice(
      $.jsx_self_closing_element,
      seq(
        $.jsx_opening_element,
        repeat($._jsx_child),
        $.jsx_closing_element,
      ),
    ),

    jsx_self_closing_element: $ => seq(
      '<',
      field('name', $._jsx_element_name),
      repeat($.jsx_attribute),
      '/',
      '>',
    ),

    jsx_opening_element: $ => seq(
      '<',
      field('name', $._jsx_element_name),
      repeat($.jsx_attribute),
      '>',
    ),

    jsx_closing_element: $ => seq(
      '<',
      '/',
      field('name', $._jsx_element_name),
      '>',
    ),

    // JSX fragment: <>...</>
    jsx_fragment: $ => seq(
      '<', '>',
      repeat($._jsx_child),
      '<', '/', '>',
    ),

    // JSX element name: div, Component, Foo.Bar, svg:rect
    _jsx_element_name: $ => choice(
      $.identifier,
      $.jsx_member_expression,
      $.jsx_namespaced_name,
    ),

    jsx_member_expression: $ => seq(
      field('object', choice($.identifier, $.jsx_member_expression)),
      '.',
      field('property', $.identifier),
    ),

    jsx_namespaced_name: $ => seq(
      $.identifier, ':', $.identifier,
    ),

    // JSX attributes
    jsx_attribute: $ => choice(
      // name="value" or name={expr} or name (boolean)
      seq(
        field('name', $.identifier),
        optional(seq('=', field('value', $._jsx_attribute_value))),
      ),
      // {...spread}
      $.jsx_spread_attribute,
    ),

    _jsx_attribute_value: $ => choice(
      $.string,
      $.jsx_expression_container,
    ),

    jsx_spread_attribute: $ => seq(
      '{', '...', $._expression, '}',
    ),

    // JSX children
    _jsx_child: $ => choice(
      $.jsx_element,
      $.jsx_fragment,
      $.jsx_text,
      $.jsx_expression_container,
    ),

    // JSX text - plain text between tags (includes whitespace)
    // Must match entire text content as a single node to avoid keyword highlighting
    jsx_text: $ => token(prec(-1, /[^<>{}]+/)),

    // JSX expression container: {expr}
    jsx_expression_container: $ => seq(
      '{', $._expression, '}',
    ),

    // =========================================================================
    // Literals
    // =========================================================================

    identifier: $ => choice(
      /[a-zA-Z_$][a-zA-Z0-9_$]*/,
      seq('`', repeat(choice(/[^`\\]/, /\\./)), '`'),
    ),

    number: $ => choice(
      /0[xX][0-9a-fA-F_]+[n]?/,
      /0[bB][01_]+[n]?/,
      /0[oO][0-7_]+[n]?/,
      /\d[0-9_]*(\.[0-9_]+)?([eE][+-]?\d+)?/,
      /\d[0-9_]*n/,
    ),

    string: $ => choice(
      // Use token() to make strings atomic - prevents // inside strings from being parsed as comments
      token(seq('"', repeat(choice(/[^"\\]/, /\\./)), '"')),
      token(seq("'", repeat(choice(/[^'\\]/, /\\./)), "'")),
      $.template_string,
    ),

    template_string: $ => seq(
      '`',
      repeat(choice(/[^`$\\]/, /\\./, seq('${', $._expression, '}'))),
      '`',
    ),

    // Contextual keywords - can be used as identifiers in certain contexts
    // (function names, parameter names, property names)
    // TypeScript allows these in contexts where they're unambiguous
    // Use alias() to make keyword tokens appear as identifiers in the AST
    _contextual_keyword: $ => choice(
      alias('get', $.identifier),
      alias('set', $.identifier),
      alias('delete', $.identifier),
      alias('catch', $.identifier),
      alias('finally', $.identifier),
      alias('from', $.identifier),
      alias('as', $.identifier),
      alias('async', $.identifier),
      alias('await', $.identifier),
    ),

    // Identifier or contextual keyword - used for names that can be keywords
    _identifier_or_keyword: $ => choice(
      $.identifier,
      $._contextual_keyword,
    ),

    boolean: $ => choice('true', 'false'),
    null: $ => 'null',
    undefined: $ => 'undefined',
    this: $ => 'this',

    comment: $ => token(choice(
      seq('//', /.*/),
      seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/'),
    )),
  },
});

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
