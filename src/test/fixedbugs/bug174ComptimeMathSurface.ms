// bug174 — the comptime engine had no float `%`, no `**`, no numeric `as`, no Math
// Symptom: in a macro body `7.5 % 2.0` died with "integer modulo by zero", `2.0 ** 3.0` and
//          `-8 >>> 1` folded to 0 without a diagnostic, `7.9 as int32` stayed 7.9, `300 as uint8`
//          stayed 300, `Math.sqrt(9.0)` raised "Unknown host function: sqrt" and `Math.PI` was
//          "cannot evaluate 'Math' at comptime"; the same expressions were right at runtime.
// Root cause: the float opcode table routed `%` to the integer opcode, the binary-expression tail
//             loaded 0 for every operator it did not know, `as` and the checker's hidden
//             conversions were passthroughs, no bridge registered the std math externs, and a
//             static field symbol was always minted mutable so the const-inline arm skipped it.
// Fix: float `%` and `**` lower to the fmod / pow host calls (the C backend's own shape), an
//      unknown operator is a queued compile error plus a trap, a Conv opcode mirrors the numeric
//      conversion rules (float truncates, unsigned wraps, signed range-checks), the 27 math externs
//      plus fmod are bridged, and a readonly static inlines its initializer like a module const.

import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserValueKind } from "../../raiser/value";

test "bug174: float modulo calls fmod" {
	const r = evalSourceFull("const a: float64 = 7.5; const b: float64 = 2.0; return a % b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Float;
	assert r.lastResult.floatVal == 1.5;
}

test "bug174: integer modulo keeps the integer opcode" {
	const r = evalSourceFull("const a: int32 = 7; const b: int32 = 2; return a % b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Int;
	assert r.lastResult.intVal == 1;
}

test "bug174: float exponent calls pow" {
	const r = evalSourceFull("const a: float64 = 2.0; const b: float64 = 3.0; return a ** b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Float;
	assert r.lastResult.floatVal == 8.0;
}

test "bug174: integer exponent converts the pow result back to an integer" {
	const r = evalSourceFull("const a: int32 = 2; const b: int32 = 10; return a ** b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Int;
	assert r.lastResult.intVal == 1024;
}

test "bug174: an operator the engine cannot evaluate is a compile error, not a silent 0" {
	const r = evalSourceFull("const a: int32 = -8; return a >>> 1;");
	assert r.lastError.contains("cannot evaluate operator '>>>' at comptime");
}

test "bug174: float to int truncates toward zero" {
	const r = evalSourceFull("const f: float64 = 7.9; return f as int32;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Int;
	assert r.lastResult.intVal == 7;
	const n = evalSourceFull("const f: float64 = -7.9; return f as int32;");
	assert n.lastError == "";
	assert n.lastResult.intVal == -7;
}

test "bug174: int to float carries the float kind" {
	const r = evalSourceFull("const i: int32 = 7; const b: float64 = 2.0; return (i as float64) / b;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Float;
	assert r.lastResult.floatVal == 3.5;
}

test "bug174: unsigned narrowing wraps" {
	const r = evalSourceFull("const i: int32 = 300; return i as uint8;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 44;
}

test "bug174: signed narrowing out of range is an error, as at runtime" {
	const r = evalSourceFull("const i: int32 = 300; return i as int8;");
	assert r.lastError.contains("value 300 not in range -128 .. 127");
}

test "bug174: the std math externs reach the engine" {
	const s = evalSourceFull("return Math.sqrt(9.0);");
	assert s.lastError == "";
	assert s.lastResult.floatVal == 3.0;
	const a = evalSourceFull("return Math.abs(-2.5);");
	assert a.lastError == "";
	assert a.lastResult.floatVal == 2.5;
	const p = evalSourceFull("return Math.pow(2.0, 10.0);");
	assert p.lastError == "";
	assert p.lastResult.floatVal == 1024.0;
	const t = evalSourceFull("return Math.atan2(1.0, 1.0) * 4.0;");
	assert t.lastError == "";
	assert t.lastResult.floatVal > 3.14159 && t.lastResult.floatVal < 3.1416;
}

test "bug174: a readonly static inlines its initializer" {
	const r = evalSourceFull("return Math.PI;");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Float;
	assert r.lastResult.floatVal > 3.14159 && r.lastResult.floatVal < 3.1416;
}
