// bug529 — a member read on a value narrowed to nothing passed the checker and reached codegen
//
// Symptom:    `function run(v: int32) { if (typeof v === "string") { return v.length; } }` passed
//             the checker; clang refused `v.length` on an int32_t, JS returned 0. With a let
//             narrowed by assignment first, codegen stopped on an unresolved type.
//
// Root cause: a typeof test that ruled out every type of a concrete reference narrowed it to an
//             unresolved placeholder (and a union to itself) instead of never, and member access had
//             no rule for never.
//
// Fix:        the typeof test narrows a concrete reference with no type left to never; reading a
//             member of never is an error. A generic or unknown reference keeps the placeholder, so
//             a generic body is still judged per instance.

import { hasError, errorCount } from "../handoff/helpers";

const NEVER529 = "does not exist on type 'never'";

test "bug529: a member read on a parameter narrowed to never is refused" {
	assert hasError("function f(v: int32): int32 {\n"
		+ "\tif (typeof v === \"string\") { return v.length; }\n"
		+ "\treturn 0;\n}\n", NEVER529);
}

test "bug529: a member read on a union or a let narrowed to never is refused" {
	assert hasError("function f(v: int32 | boolean): int32 {\n"
		+ "\tif (typeof v === \"string\") { return v.length; }\n"
		+ "\treturn 0;\n}\n", NEVER529);
	assert hasError("function f(): int32 {\n"
		+ "\tlet v: int32 | string = 12345;\n"
		+ "\tif (typeof v === \"string\") { const n: int32 = v.length + 1; return n; }\n"
		+ "\treturn 0;\n}\n", NEVER529);
}

test "bug529: passing never along and a generic typeof arm stay accepted" {
	assert errorCount("function f(v: int32): int32 {\n"
		+ "\tif (typeof v === \"string\") { console.log(v); return 1; }\n"
		+ "\treturn 0;\n}\n"
		+ "function g<T>(x: T): int32 {\n"
		+ "\tif (typeof x === \"number\") { return 1; }\n"
		+ "\treturn 0;\n}\n") == 0;
}
