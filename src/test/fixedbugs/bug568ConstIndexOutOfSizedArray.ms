// bug568 — a constant index past the end of a T[N] compiled and failed only at run time
//
// Symptom:    `let fixed: int32[4] = [1, 2, 3, 4]; console.log(fixed[5]);` built
//             clean and stopped at run time with "index 5 out of bounds
//             (length 4)"; under --danger, where the run-time check is gone,
//             it read past the array.
// Root cause: the checker typed `arr[i]` on a sized array from the element type
//             alone and never compared a literal index with N.
// Fix:        reportConstIndexBound (checker/fit.ms) rejects an integer literal,
//             negated or not, outside 0..N-1 on a sized array, in every build mode.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug568: the last slot of a sized array is accepted" {
	assert accepts("function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[3]; }");
}

test "bug568: an index equal to the size is rejected" {
	assert hasError("function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[4]; }", "index 4 out of bounds for 'int32[4]' (0..3)");
}

test "bug568: an index far past the size is rejected" {
	assert hasError("function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[5]; }", "index 5 out of bounds");
}

test "bug568: a negative literal index is rejected" {
	assert hasError("function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[-1]; }", "index -1 out of bounds");
}

test "bug568: a write past the end is rejected" {
	assert hasError("function f(): void { let a: int32[4] = [1, 2, 3, 4]; a[4] = 9; }", "index 4 out of bounds");
}

test "bug568: another element type is checked the same way" {
	assert hasError("function f(): string { let a: string[2] = [\"x\", \"y\"]; return a[2]; }", "index 2 out of bounds for 'string[2]'");
}

test "bug568: a variable index stays a run-time check" {
	assert accepts("function f(i: int32): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[i]; }");
}

test "bug568: a dynamic array is not checked at compile time" {
	assert accepts("function f(): int32 { const a: int32[] = [1, 2, 3]; return a[5]; }");
}
