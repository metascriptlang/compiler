// bug597 — a local const was not a constant, and a named constant index escaped the T[N] check
//
// Symptom:    `const I = 5; fixed[I]` and a local `const k = 2 + 3; fixed[k]` on an
//             int32[4] compiled; a local `const k = 100; const b: int8 = k` was
//             refused although a module-level one with the same value was accepted.
// Root cause: the constant evaluator (checker/constFold.ms) took only module-level
//             const bindings, and the T[N] index check read literals only.
// Fix:        constInitializer takes any const binding with a foldable initializer;
//             reportConstIndexBound folds the index with constantLiteralOf.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug597: a module constant index past a sized array is rejected" {
	assert hasError("const I = 5;\nfunction f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[I]; }", "index 5 out of bounds");
}

test "bug597: a local constant expression index past a sized array is rejected" {
	assert hasError("function f(): int32 { const k = 2 + 3; let a: int32[4] = [1, 2, 3, 4]; return a[k]; }", "index 5 out of bounds");
}

test "bug597: a constant index inside the bounds is accepted" {
	assert accepts("const I = 3;\nfunction f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[I]; }");
}

test "bug597: a let index stays a run-time check" {
	assert accepts("function f(): int32 { let k = 5; let a: int32[4] = [1, 2, 3, 4]; return a[k]; }");
}

test "bug597: a local constant that fits a narrower slot is accepted" {
	assert accepts("function f(): int8 { const k = 100; const b: int8 = k; return b; }");
}

test "bug597: a local constant that does not fit is still refused" {
	assert hasError("function f(): int8 { const k = 300; const b: int8 = k; return b; }", "int8");
}
