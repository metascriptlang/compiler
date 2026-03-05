; MetaScript indentation queries for nvim-treesitter.

; ---------------------------------------------------------------------------
; Indent: opening braces increase indentation
; ---------------------------------------------------------------------------

; Block statements
(block "{" @indent.begin)

; Function bodies (both regular and macro)
(function_body "{" @indent.begin)
(macro_body "{" @indent.begin)

; Class / interface / enum bodies
(class_body "{" @indent.begin)
(interface_body "{" @indent.begin)
(enum_body "{" @indent.begin)

; Test declaration body
(test_declaration (block "{" @indent.begin))

; Match expression body
(match_body "{" @indent.begin)

; Switch statement body
(switch_body "{" @indent.begin)

; Object literals
(object "{" @indent.begin)
(object_type "{" @indent.begin)

; Array literals
(array "[" @indent.begin)

; Parenthesized expressions / arguments / parameters (multi-line)
(arguments "(" @indent.begin)
(parameters "(" @indent.begin)
(arrow_function_parameters "(" @indent.begin)
(parenthesized_expression "(" @indent.begin)

; Macro target blocks
(macro_target_body "{" @indent.begin)

; Extern class bodies
(extern_class_body "{" @indent.begin)

; JSX elements (indent children)
(jsx_opening_element ">" @indent.begin)
(jsx_self_closing_element) @indent.begin

; ---------------------------------------------------------------------------
; Outdent: closing delimiters decrease indentation
; ---------------------------------------------------------------------------

"}" @indent.end
"]" @indent.end
")" @indent.end

; ---------------------------------------------------------------------------
; Branch: tokens that should be at the same level as the block opener
; ---------------------------------------------------------------------------

; else keyword aligns with if
(if_statement "else" @indent.branch)

; switch case / default aligns with switch body
(switch_case "case" @indent.branch)
(switch_default "default" @indent.branch)

; Macro target else aligns with @target
(macro_target_else "else" @indent.branch)

; Closing delimiters align with their openers
"}" @indent.branch
"]" @indent.branch
")" @indent.branch

; ---------------------------------------------------------------------------
; Aligned: match arm bodies align with the pattern
; ---------------------------------------------------------------------------

; Match arms: the => arrow should not cause extra indent
(match_arm "=>" @indent.dedent)

; ---------------------------------------------------------------------------
; Ignore: nodes where automatic indentation should not apply
; ---------------------------------------------------------------------------

(comment) @indent.ignore
(string) @indent.ignore
(template_string) @indent.ignore
