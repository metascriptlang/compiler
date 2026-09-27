// bug596 — an explicit signed cast of a constant that does not fit compiled and wrapped
//
// Symptom:    `const K = 300; console.log(K as int8);` printed 44 on C (debug and
//             --danger) and JS; no range check ever ran, because the transform
//             folded the cast into the wrapped literal first.
// Root cause: the checker only judged a literal operand of `as`; a named
//             constant reached the transform unjudged.
// Fix:        reportConstCast (checker/fit.ms) folds the operand of `as` with
//             constantLiteralOf and rejects a signed target it does not fit.
//             An unsigned target still wraps, as a conversion to one does.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug596: a module constant cast to a narrower signed type is rejected" {
	assert hasError("const K = 300;\nfunction f(): int8 { return K as int8; }", "cannot convert 300 to int8");
}

test "bug596: a constant expression cast is folded first" {
	assert hasError("const K = 30000;\nfunction f(): int16 { return (K + K) as int16; }", "cannot convert 60000 to int16");
}

test "bug596: a negative constant cast below the range is rejected" {
	assert hasError("const K = -200;\nfunction f(): int8 { return K as int8; }", "cannot convert -200 to int8");
}

test "bug596: a local constant cast is rejected" {
	assert hasError("function f(): int8 { const k = 300; return k as int8; }", "cannot convert 300 to int8");
}

test "bug596: a constant that fits is accepted" {
	assert accepts("const K = 127;\nfunction f(): int8 { return K as int8; }");
}

test "bug596: a cast to an unsigned type still wraps" {
	assert accepts("const K = 300;\nfunction f(): uint8 { return K as uint8; }");
}

test "bug596: a variable cast stays a run-time check" {
	assert accepts("function f(k: int32): int8 { return k as int8; }");
}
