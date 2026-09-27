// bug421 — an array pattern on the left of `=` was checked as an array value
//
// Symptom:    `[a, b] = [b, a]` compiled to C that assigned one fresh array to another, so a
//             swap did nothing; `[n, w] = [2, "y"]` and `[a, [b, c]] = ...` wrapped the targets
//             in conversions, and the JS output then dropped the assignment.
// Root cause: the checker typed the pattern like an array literal (joining and fitting its
//             elements) and no pass lowered an assignment whose target is a pattern.
// Fix:        the checker types each target as an assignment target (one element type gives
//             T[], mixed ones a tuple) and destructuringLower assigns every target from one
//             evaluation of the right side (Nim makeTupleAssignments).

import { compileToC } from "../helpers";

const header = `
let a: int32 = 1;
let b: int32 = 2;
let w: string = "x";
let r: int32[] = [];
const src: int32[] = [3, 4, 5];
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug421: a pattern of mixed targets takes a tuple" {
	assert errorOf("[a, w] = [2, \"y\"];\n") == "";
}

test "bug421: a nested pattern and a rest target are accepted" {
	assert errorOf("[a, [b]] = [1, [2]];\n[a, ...r] = src;\n") == "";
}

test "bug421: a literal is not an assignment target" {
	assert errorOf("[1, b] = src;\n").indexOf("a destructuring assignment target must be a variable, a field or an element") >= 0;
}

test "bug421: a rest target needs the other targets' element type" {
	assert errorOf("[w, ...r] = [\"s\", 1];\n").indexOf("a rest element in a destructuring assignment") >= 0;
}

test "bug421: a pattern takes only a plain assignment" {
	assert errorOf("[a, b] += src;\n").indexOf("a destructuring pattern can only be assigned with '='") >= 0;
}
