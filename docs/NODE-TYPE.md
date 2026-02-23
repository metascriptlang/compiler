# AST Node Types by Pipeline Phase

Reference compiler (`~/projects/metascript`) has **103** node kinds.
Self-hosted compiler (`src/ast/node.ms`) has **58** node kinds.

Organized by the 6 real compilation phases from `compile.zig:295`:

```
Phase 1         Phase 2              Phase 3          Phase 4       Phase 5      Phase 6
Load+Parse  →  Macros+TypeCheck  →  Transforms  →  DRC (C only)  →  Codegen  →  (stats)
```

---

## Phase 1: Load + Parse (58/58 kinds) -- DONE

Lex source, parse to AST, load module dependencies, load std macros.

### Literals (6/6)

| # | Self-Hosted          | Reference             | Status |
|---|----------------------|-----------------------|--------|
| 1 | `NumberLiteral`      | `number_literal`      | Done   |
| 2 | `StringLiteral`      | `string_literal`      | Done   |
| 3 | `BooleanLiteral`     | `boolean_literal`     | Done   |
| 4 | `NullLiteral`        | `null_literal`        | Done   |
| 5 | `BigIntLiteral`      | `bigint_literal`      | Done   |
| 6 | `RegexLiteral`       | `regex_literal`       | Done   |

### Identifiers (1/1)

| # | Self-Hosted          | Reference             | Status |
|---|----------------------|-----------------------|--------|
| 7 | `Identifier`         | `identifier`          | Done   |

### Expressions (19/19)

| #  | Self-Hosted          | Reference                | Status |
|----|----------------------|--------------------------|--------|
|  8 | `BinaryExpr`         | `binary_expr`            | Done   |
|  9 | `UnaryExpr`          | `unary_expr`             | Done   |
| 10 | `UpdateExpr`         | `update_expr`            | Done   |
| 11 | `CallExpr`           | `call_expr`              | Done   |
| 12 | `MemberExpr`         | `member_expr`            | Done   |
| 13 | `ArrayAccess`        | `member_expr` (computed) | Done   |
| 14 | `ObjectLiteral`      | `object_expr`            | Done   |
| 15 | `ArrayLiteral`       | `array_expr`             | Done   |
| 16 | `ArrowFunction`      | (arrow = function_expr)  | Done   |
| 17 | `FunctionExpr`       | `function_expr`          | Done   |
| 18 | `TypeAssertion`      | `type_assertion_expr`    | Done   |
| 19 | `ConditionalExpr`    | `conditional_expr`       | Done   |
| 20 | `SpreadExpr`         | `spread_element`         | Done   |
| 21 | `NewExpr`            | `new_expr`               | Done   |
| 22 | `TryExpr`            | `try_expr`               | Done   |
| 23 | `MatchExpr`          | (match in expr position) | Done   |
| 24 | `MatchCase`          | (part of match)          | Done   |
| 25 | `AwaitExpr`          | `await_expr`             | Done   |
| 26 | `YieldExpr`          | `yield_expr`             | Done   |
| 27 | `MoveExpr`           | `move_expr`              | Done   |
| 28 | `OutExpr`            | `out_expr`               | Done   |

### Type Annotations (1/1)

| #  | Self-Hosted          | Reference             | Status |
|----|----------------------|-----------------------|--------|
| 29 | `TypeAnnotation`     | `type_annotation`     | Done   |

### Statements (16/16)

| #  | Self-Hosted          | Reference             | Status |
|----|----------------------|-----------------------|--------|
| 30 | `VariableDecl`       | `variable_stmt`       | Done   |
| 31 | `IfStmt`             | `if_stmt`             | Done   |
| 32 | `WhileStmt`          | `while_stmt`          | Done   |
| 33 | `ForStmt`            | `for_stmt`            | Done   |
| 34 | `ForOfStmt`          | `for_of_stmt`         | Done   |
| 35 | `BlockStmt`          | `block_stmt`          | Done   |
| 36 | `ExprStmt`           | `expression_stmt`     | Done   |
| 37 | `ReturnStmt`         | `return_stmt`         | Done   |
| 38 | `BreakStmt`          | `break_stmt`          | Done   |
| 39 | `ContinueStmt`       | `continue_stmt`       | Done   |
| 40 | `FunctionDecl`       | `function_decl`       | Done   |
| 41 | `DoWhileStmt`        | `while_stmt` (do)     | Done   |
| 42 | `SwitchStmt`         | `switch_stmt`         | Done   |
| 43 | `SwitchCase`         | (part of switch)      | Done   |
| 44 | `UnreachableStmt`    | `unreachable_stmt`    | Done   |
| 45 | `MatchStmt`          | `match_stmt`          | Done   |

### Declarations (9/9)

| #  | Self-Hosted          | Reference             | Status |
|----|----------------------|-----------------------|--------|
| 46 | `ImportDecl`         | `import_decl`         | Done   |
| 47 | `ExportDecl`         | `export_decl`         | Done   |
| 48 | `TypeAliasDecl`      | `type_alias_decl`     | Done   |
| 49 | `EnumDecl`           | `enum_decl`           | Done   |
| 50 | `InterfaceDecl`      | `interface_decl`      | Done   |
| 51 | `ClassDecl`          | `class_decl`          | Done   |
| 52 | `PropertyDecl`       | `property_decl`       | Done   |
| 53 | `MethodDecl`         | `method_decl`         | Done   |
| 54 | `ConstructorDecl`    | `constructor_decl`    | Done   |

### Error Handling (2/2)

| #  | Self-Hosted          | Reference             | Status |
|----|----------------------|-----------------------|--------|
| 55 | `ThrowStmt`          | `throw_stmt`          | Done   |
| 56 | `TryCatchStmt`       | `try_stmt`            | Done   |

### Other (2/2)

| #  | Self-Hosted          | Reference             | Status |
|----|----------------------|-----------------------|--------|
| 57 | `DeferStmt`          | `defer_stmt`          | Done   |
| 58 | `Program`            | `program`             | Done   |

---

## Phase 2: Macro Expansion + Type Checking (~16 kinds) -- TODO

Single phase, two sub-steps: macros expand first, then 3-pass type checking runs.

### 2a: Macro Expansion (~12 kinds)

Hermes VM expands `@derive`, `@comptime`, custom macros. Replaces
`macro_invocation` nodes with generated AST subtrees.

| Reference                | Purpose                                    |
|--------------------------|--------------------------------------------|
| `macro_decl`             | `macro name { ... }` definition            |
| `macro_invocation`       | `name!(args)` usage site                   |
| `comptime_block`         | `comptime { ... }` compile-time execution  |
| `compile_error`          | `@compileError("msg")`                     |
| `quote_expr`             | `quote { ... }` AST quotation in macros    |
| `extern_function_decl`   | `extern function ...`                      |
| `extern_var_decl`        | `extern let ...`                           |
| `extern_const_decl`      | `extern const ...`                         |
| `extern_class_decl`      | `extern class ...`                         |
| `extern_enum_decl`       | `extern enum ...`                          |
| `extern_type_decl`       | `extern type ...`                          |
| `extern_macro_decl`      | `extern macro ...`                         |

### 2b: Type Checking (~4 kinds)

3-pass architecture (Nim-aligned):
- Pass 0: Type canonicalization (assign MsAnon* names)
- Pass 1: Collect declarations (populate symbol table)
- Pass 2: Propagate exports (cross-module type flow)
- Pass 2.5: Discriminant analysis (union narrowing)
- Pass 3: Full type resolution + inference (fills `.type` on every node)

Inserts new nodes during inference:

| Reference                | Purpose                                    |
|--------------------------|--------------------------------------------|
| `optional_wrap`          | Wrap value into `T?`                       |
| `optional_none`          | Create `none` for optional type            |
| `optional_unwrap`        | Narrow `T?` → `T` after null check        |
| `implicit_conv`          | Auto type coercion (e.g. int → float)      |

---

## Phase 3: Transforms (~8 kinds) -- TODO

Three sub-steps that all modify the AST:

### 3a: Transform Pipeline (12+ builtin transforms)

type_coercion, optional_chain (`a?.b`), nullish_coalesce (`a ?? b`),
result_desugar, spread_expand, for_of_lower, liftdestructors, etc.

### 3b: Normalization (lambda lifting + extensions)

- Lambda lifting: closures → `struct Env { captures } + function pointer`
- Extension methods: `arr.map(f)` → `Array_map(arr, f)` (UFCS)
- Generator transformation

### 3c: Lowering

- Match expression → switch/if chains
- Defer → try/finally
- Constant folding
- DCE analysis (no new nodes, just marks alive symbols)

| Reference                | Purpose                                    |
|--------------------------|--------------------------------------------|
| `stmt_expr`              | Statement-as-expression (match lowering)   |
| `string_concat_expr`     | Flatten `a + b + c` for strings            |
| `string_append_expr`     | Optimize `a += b` for strings              |
| `string_assign_expr`     | Optimize string assignment                 |
| `string_sink_expr`       | Sink semantics for string temporaries      |
| `range_check_expr`       | Runtime bounds check on narrowing          |
| `custom_infix_expr`      | User-defined binary operator               |
| `custom_prefix_expr`     | User-defined unary operator                |

---

## Phase 4: DRC Analysis + Injection (C backend only, ~0 new kinds) -- TODO

Sub-steps: string concat flattening → DRC analysis → range check injection →
DRC cleanup injection (`ms_decref`, `ms_incref`, `was_moved`) →
pointer param transform → loc flag resolution.

No new NodeKinds. Transforms existing AST by wrapping scopes with
try/finally cleanup blocks using existing node types.

---

## Phase 5: Codegen (0 new kinds)

Read-only AST traversal. Emits C / JS / Erlang / Raiser code.
No new node types. Backend selected by build config.

---

## Phase ?: JSX (~4 kinds) -- TODO

Only if JSX frontend support is added. These are parser-level nodes.

| Reference                    | Purpose                                |
|------------------------------|----------------------------------------|
| `jsx_element`                | `<Component prop={val}>...</Component>`|
| `jsx_fragment`               | `<>...</>`                             |
| `jsx_text`                   | Text content inside JSX                |
| `jsx_expression_container`   | `{expr}` inside JSX                    |

---

## Summary

```
Phase 1: Load + Parse .......... 58/58  DONE
Phase 2: Macros + TypeCheck ..... 0/16   TODO  (2a: ~12 macro, 2b: ~4 type)
Phase 3: Transforms ............. 0/8    TODO  (3a: pipeline, 3b: normalize, 3c: lower)
Phase 4: DRC .................... --     TODO  (no new node kinds)
Phase 5: Codegen ................ --     (read-only)
Phase ?: JSX .................... 0/4    TODO  (if needed)
                                  ------
Total:                            57/86+ (+ regex_literal skipped)
Reference total:                  103
```
