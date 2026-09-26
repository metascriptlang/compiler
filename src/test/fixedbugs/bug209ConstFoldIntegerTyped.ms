// bug209 — constant folding computes an integer-typed expression in its own type
//
// Symptom:    `const t: int32 = 9 / 2` held 4.5 on JS and `(7 / 2) * 2` was 7 on C and JS.
// Root cause: lowerConstFold evaluated every pair of number literals as doubles and ignored the checked type.
// Fix:        an integer-typed node folds in its own width, and a result its type cannot hold is left to the runtime.

import { compileToC, compileToJS } from "../helpers";

test "bug209: int32 literal division folds to the truncated quotient on JS" {
	const js = compileToJS("function f(): int32 { return 9 / 2; }");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("return 4;") && !js.value.contains("4.5"), js.value;
}

test "bug209: a negative int32 quotient truncates toward zero" {
	const js = compileToJS("function f(): int32 { return -7 / 2; }");
	assert js.ok, js.ok ? "" : js.error;
	assert (js.value.contains("return (-3);") || js.value.contains("return -3;")) && !js.value.contains("3.5"), js.value;
}

test "bug209: a nested fold multiplies the truncated quotient on C" {
	const c = compileToC("function f(): int32 { return (7 / 2) * 2; }");
	assert c.ok, c.ok ? "" : c.error;
	assert c.value.contains("return 6;"), c.value;
}

test "bug209: int64 literal division folds to the truncated quotient" {
	const js = compileToJS("function f(): int64 { return 9 / 2; }");
	assert js.ok, js.ok ? "" : js.error;
	assert !js.value.contains("4.5"), js.value;
}

test "bug209: an int32 sum past the type's range is left to the runtime" {
	const js = compileToJS("function f(): int32 { return 2147483647 + 1; }");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("2147483647 + 1"), js.value;
}

test "bug209: the lowest int32 modulo -1 is left to the runtime" {
	const js = compileToJS("function f(): int32 { return (-2147483647 - 1) % -1; }");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("% (-1)") || js.value.contains("% -1"), js.value;
}

test "bug209: float division still keeps the fraction" {
	const js = compileToJS("function f(): float64 { return 7.0 / 2; }");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("return 3.5;"), js.value;
}
