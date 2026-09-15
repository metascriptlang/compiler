// bug165 — float arithmetic in a comptime body ran on integer opcodes
// Symptom: `const f = floatValue(v); f * 2.0` folded to 0 in a macro body, `f > 0` to false, while
//          `f + 0.25` was right; a value reaching the expression through a copy, a return, an array
//          element or the host bridge lost its float-ness, and `2.0` did too because it prints as "2".
// Root cause: the engine picked the float opcode from a per-register mark seeded by a string scan of the
//             literal's decimal form, instead of the static type the checker had already assigned.
// Fix: the arithmetic and comparison arms read the operand type; the register mark is gone.

import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserValueKind } from "../../raiser/value";

test "bug165: a float literal spelled without a fraction still multiplies as a float" {
	const r = evalSourceFull("const f: float64 = 0.5; return f * 2.0;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Float;
	assert r.lastResult.floatVal == 1.0;
}

test "bug165: a float survives a copy" {
	const r = evalSourceFull("const a: float64 = 0.5; const b = a; return b * 2.0;");
	assert r.lastError == "";
	assert r.lastResult.floatVal == 1.0;
}

test "bug165: a float survives a return" {
	const r = evalSourceFull("function t(x: float64): float64 { return x * 2.0; } return t(0.5);");
	assert r.lastError == "";
	assert r.lastResult.floatVal == 1.0;
}

test "bug165: a float survives an array element read" {
	const r = evalSourceFull("const xs: float64[] = [0.5]; return xs[0] * 2.0;");
	assert r.lastError == "";
	assert r.lastResult.floatVal == 1.0;
}

test "bug165: comparing a float against an integer literal reads the fraction" {
	const r = evalSourceFull("const f: float64 = 0.5; return f > 0;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug165: negating a float keeps the fraction" {
	const r = evalSourceFull("const f: float64 = 0.5; return -f;");
	assert r.lastError == "";
	assert r.lastResult.floatVal == -0.5;
}

test "bug165: integer division stays integer" {
	const r = evalSourceFull("const a: int32 = 7; const b: int32 = 2; return a / b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Int;
	assert r.lastResult.intVal == 3;
}

test "bug165: integer multiplication stays integer" {
	const r = evalSourceFull("const a: int64 = 3; const b: int64 = 4; return a * b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Int;
	assert r.lastResult.intVal == 12;
}
