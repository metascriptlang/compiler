// Implicit float → integer narrowing must be refused at every fit position.
//
// The conversion itself is fine — `as int32` spells it — but it must be the
// programmer's word, not the compiler's guess: a float64 reaching an intN slot
// silently drops its fractional part, and at the field / element / return
// positions there is no annotation next to the value to warn the reader.
// Reference behaviour, measured: zig and rust and go all reject it outright,
// clang warns by default (-Wliteral-conversion). Only the call-argument
// position was covered here, and only by a warning.
//
// Integral values keep flowing implicitly (nothing is lost), which is the same
// line zig draws with "fractional component prevents float value from
// coercion".

import { compileToC } from "../helpers";

function refused(source: string): boolean {
	const r = compileToC(source);
	if (r.ok) return false;
	return r.error.contains("narrowing");
}

function accepted(source: string): boolean {
	const r = compileToC(source);
	return r.ok;
}

test "narrowing: a fractional literal is refused in a variable initializer" {
	assert refused("const x: int32 = 3.5;");
}

test "narrowing: a float64 value is refused in an assignment" {
	assert refused("let x: int32 = 0; const f: float64 = 3.5; x = f;");
}

test "narrowing: a fractional literal is refused as a call argument" {
	assert refused("function take(n: int32): int32 { return n; } take(3.5);");
}

test "narrowing: a fractional literal is refused in a return" {
	assert refused("function f(): int32 { return 3.5; }");
}

test "narrowing: a fractional literal is refused in an object field" {
	assert refused("interface P { n: int32; } const p: P = { n: 3.5 };");
}

test "narrowing: a fractional literal is refused in an array element" {
	assert refused("const a: int32[] = [1.5];");
}

test "narrowing: an integral literal still flows implicitly" {
	assert accepted("const x: int32 = 3;");
}

test "narrowing: an integral float literal still flows implicitly" {
	assert accepted("const x: int32 = 3.0;");
}

test "narrowing: an explicit cast is the way through" {
	assert accepted("const x: int32 = 3.5 as int32;");
}

test "narrowing: integer arithmetic is untouched" {
	assert accepted("const a: int32 = 7; const b: int32 = 2; const q: int32 = a / b;");
}

test "narrowing: widening an integer to float64 stays implicit" {
	assert accepted("const i: int32 = 3; const f: float64 = i;");
}
