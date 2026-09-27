// bug562 — a value refused at a return reported the same mismatch twice
//
// Symptom:    `function f(v: int32 | string): int32 { return v; }` reported "Type 'int32 | string' is not
//             assignable to type 'int32'" and then "Return type mismatch in 'f'" at the same return; a float,
//             a changed signedness and an array of another layout did the same.
// Root cause: fitNode reported the refusal and handed the value back with its own type, so the return check
//             after it found the same mismatch again.
// Fix:        a value fitNode refuses is retyped to its slot (the reference's error correction in fitNode), so
//             the refusal is the one report.

import { errorCount, hasError } from "../handoff/helpers";

test "bug562: a refused return value is reported once" {
	assert errorCount("function f(v: int32 | string): int32 { return v; }\n") == 1;
	assert errorCount("function f(x: float64): int32 { return x; }\n") == 1;
	assert errorCount("function f(x: int32): uint32 { return x; }\n") == 1;
	assert errorCount("function f(x: int32[]): int64[] { return x; }\n") == 1;
}

test "bug562: the one report is the specific refusal" {
	assert hasError("function f(x: int32): uint32 { return x; }\n", "implicit int32 → uint32 conversion changes signedness");
	assert hasError("function f(v: int32 | string): int32 { return v; }\n", "Type 'int32 | string' is not assignable to type 'int32'");
}

test "bug562: declarations and assignments still report once" {
	assert errorCount("function g(v: int32 | string): void { const y: int32 = v; }\n") == 1;
	assert errorCount("function g(v: int32 | string): void { let y: int32 = 0; y = v; }\n") == 1;
}
