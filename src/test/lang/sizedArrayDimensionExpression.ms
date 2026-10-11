// A sized array's dimension folds as a compile-time integer expression
//
// Symptom:    `int32[N + 1]` and `int32[4 + 1]` were refused with "array size
//             'N + 1' must be a compile-time integer constant", and a
//             same-module const dimension in a struct field, a parameter type
//             or a module-scope binding was refused even as a bare `int32[N]`.
// Root cause: the dimension text was looked up as one name, and the const's
//             type was read from its declaration's checked type, which a
//             struct field or a signature resolves before the const is checked.
// Fix:        the dimension parses as an expression whose names bind to their
//             symbols and fold through constantLiteralOf; a const not yet
//             checked folds under its declared type.

import { hasError, strictErrorCount } from "../handoff/helpers";

test "a const plus a literal, two literals and a const times a literal fold" {
	assert strictErrorCount("const N: int32 = 4;\nfunction f(): int32 { let a: int32[N + 1] = []; let b: int32[4 + 1] = []; let c: int32[N * 2] = []; return a[4] + b[4] + c[7]; }") == 0;
}

test "a struct field and a parameter type fold a const declared below them" {
	assert strictErrorCount("struct S { cells: int32[N - 1] }\nfunction f(xs: int32[N + 1]): int32 { return xs[4]; }\nconst N: int32 = 4;") == 0;
}

test "a let in the dimension is still refused" {
	assert hasError("function f(): int32 { let k = 3; let a: int32[k] = []; return a[0]; }", "array size 'k' must be a compile-time integer constant");
	assert hasError("function f(): int32 { let k = 3; let a: int32[k + 1] = []; return a[0]; }", "array size 'k + 1' must be a compile-time integer constant");
}

test "a dimension that folds to a fraction or a negative is refused" {
	assert hasError("function f(): int32 { let a: int32[7 / 2] = []; return a[0]; }", "array size '7 / 2' must be a compile-time integer constant");
	assert hasError("function f(): int32 { let a: int32[1 - 2] = []; return a[0]; }", "array size '1 - 2' must be a compile-time integer constant");
}
