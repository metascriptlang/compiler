// cparse — Integer constant expression evaluator
// Port of: ~/projects/chibicc parse.c const_expr / eval path.
//
// STATUS: skeleton. Implementation lands in task #18.
//
// Needed in two places:
//   1. Preprocessor #if conditions
//   2. Enum values, array sizes, bitfield widths during declaration parsing

import { Token } from "./token";

export interface EvalResult {
	value: int64;
	ok: boolean;
	error: string;
}

// Evaluate a constant expression beginning at `tok`. Returns the integer
// result or ok=false with an error message. Macro identifiers are resolved
// through the caller-provided lookup.
//
// TODO(task #18): full port covering:
//   - integer literals (dec/hex/oct/bin, suffixes)
//   - unary: + - ~ ! (no sizeof in the minimal set needed for #if)
//   - binary: arithmetic, bitwise, shifts, comparisons, logical
//   - ternary ?:
//   - parenthesized subexpressions
//   - defined(X) in #if context
//   - identifier → macro lookup (unknown → 0)
export function evalConstExpr(tok: Token): EvalResult {
	return { value: 0 as int64, ok: false, error: "not implemented" };
}
