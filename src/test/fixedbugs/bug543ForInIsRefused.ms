// bug543 — a for...in loop passed the checker and both backends deleted it
//
// Symptom:    `for (const k in obj) { kept.push(b); }` compiled; C emitted `/* unsupported stmt:
//             ForInStmt */` and JS `/* unsupported: ForInStmt */` where the loop was, so the body
//             never ran and the program printed 0.
//
// Root cause: checkForInStmt typed the binding and checked the body, and no transform lowers
//             ForInStmt, so the statement reached both codegen default arms.
//
// Fix:        the checker refuses for...in with a named diagnostic until a lowering exists (Nim has
//             no loop over an object's keys; the fail-loud rule forbids a silent drop).

import { errorCount, hasError } from "../handoff/helpers";

const FORIN543 = "'for...in' is not supported";

test "bug543: a for...in over an object literal is refused" {
	assert hasError("function f(): int32 {\n\tconst obj = { x: 1, y: 2 };\n\tlet n: int32 = 0;\n\tfor (const k in obj) { n = n + 1; }\n\treturn n;\n}\n", FORIN543);
}

test "bug543: a for...in with a let binding over an array is refused too" {
	assert hasError("function g(xs: int32[]): int32 {\n\tlet n: int32 = 0;\n\tfor (let i in xs) { n = n + 1; }\n\treturn n;\n}\n", FORIN543);
}

test "bug543: a for...of over the same array stays accepted" {
	assert errorCount("function h(xs: int32[]): int32 {\n\tlet n: int32 = 0;\n\tfor (const x of xs) { n = n + x; }\n\treturn n;\n}\n") == 0;
}
