// bug598 — a tuple index that is not an in-range constant compiled and printed <object>
//
// Symptom:    `const t: [int32, string] = [1, "a"]; console.log(t[5]);` built and
//             printed `<object>`; so did `t[-1]` and a variable index `t[i]`, on C
//             in every mode.
// Root cause: the ArrayAccess check typed a tuple element only for a plain
//             in-range literal and fell back to an inferred type for anything else.
// Fix:        tupleIndexType (checker/fit.ms) folds the index with constantLiteralOf,
//             refuses a non-constant or out-of-range one, and replaces the index
//             with the folded literal so nativeLower turns it into the field.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug598: an in-range literal tuple index is accepted" {
	assert accepts("function f(): string { const t: [int32, string] = [1, \"a\"]; return t[1]; }");
}

test "bug598: a literal tuple index past the end is rejected" {
	assert hasError("function f(): int32 { const t: [int32, string] = [1, \"a\"]; t[5]; return 0; }", "index 5 out of bounds for a tuple of length 2");
}

test "bug598: a negative tuple index is rejected" {
	assert hasError("function f(): int32 { const t: [int32, string] = [1, \"a\"]; t[-1]; return 0; }", "index -1 out of bounds for a tuple of length 2");
}

test "bug598: a variable tuple index is rejected" {
	assert hasError("function f(i: int32): int32 { const t: [int32, int32] = [1, 2]; return t[i]; }", "a tuple index must be a constant");
}

test "bug598: a named constant tuple index is folded and accepted" {
	assert accepts("const K = 1;\nfunction f(): string { const t: [int32, string] = [1, \"a\"]; return t[K]; }");
}

test "bug598: a constant expression tuple index is folded and accepted" {
	assert accepts("function f(): string { const t: [int32, string] = [1, \"a\"]; return t[0 + 1]; }");
}
