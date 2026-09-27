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

const CLASSES562 = "class A562 { a: int32 = 1; }\nclass B562 { b: int32 = 2; }\nclass H562<T> { v: T; constructor(v: T) { this.v = v; } }\n";

test "bug562: a refused class, generic instance, anonymous literal or null is reported once at a declaration, an assignment and an element" {
	assert errorCount(CLASSES562 + "const x: B562 = new A562();\n") == 1;
	assert errorCount(CLASSES562 + "const w: H562<int32> = new H562<string>(\"x\");\n") == 1;
	assert errorCount("struct P562 { x: int32; y: int32; }\nconst lit = { y: 1, x: 2 };\nconst p: P562 = lit;\n") == 1;
	assert errorCount("const n: int32 = null;\n") == 1;
	assert errorCount(CLASSES562 + "function g(): void { let y: B562 = new B562(); y = new A562(); }\n") == 1;
	assert errorCount(CLASSES562 + "function g(): void { let y: H562<int32> = new H562<int32>(1); y = new H562<string>(\"x\"); }\n") == 1;
	assert errorCount(CLASSES562 + "const xs: B562[] = [new B562(), new A562()];\n") == 1;
}
