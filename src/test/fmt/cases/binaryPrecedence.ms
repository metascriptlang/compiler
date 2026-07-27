// Operator precedence in nested binary expressions.
//
// Symptom:    `(a + b) * c` formats to `a + b * c`. Different runtime
//             value: 1+2*3 = 7 vs (1+2)*3 = 9.
// Symptom 2:  `(a + b) - c` works in JS-like grammars only because both
//             sides have the same precedence and `-` is left-assoc:
//             dropping parens is OK there. But `a - (b - c)` MUST keep
//             parens — left-assoc subtraction makes the right child
//             require parens at equal precedence.
// Fix:        printBinaryExpr wraps left/right when child precedence is
//             lower than parent, OR equal-precedence on the right side
//             of a left-associative operator.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: (a + b) * c keeps parens (lower-prec child)" {
	assert assertFmtPreservesAst("const a: number = 1; const b: number = 2; const c: number = 3; const x: number = (a + b) * c;");
}

test "fmt: a - (b - c) keeps parens (right child, equal prec)" {
	assert assertFmtPreservesAst("const a: number = 1; const b: number = 2; const c: number = 3; const x: number = a - (b - c);");
}
