// bug176 — the checker spelled the T → T | null wrap as a user-shaped object literal
// Symptom: a template calling a function with an `int32 | null` parameter failed with
//          `got __anon2__valuei__presentb, expected Maybe_p10` on both backends; in a macro body a
//          helper returning `int32 | null` compared unequal to its own value (`h == 42` was false).
// Root cause: `synthMaybeWrap` built `{ value, present }` as an ObjectLiteral, so a cloned,
//             re-checked tree saw it as source and wrapped (or rejected) it a second time.
// Fix: the wrap is a HiddenStdConv, re-checked as the conversion it is; the carrier literal is
//      materialized once, at the head of every transform pipeline. The function → closure thunk
//      `{ fn, env }` had the same shape and takes the same route.

enum Tone176 { Low, High }

function eqMaybe176(m: int32 | null, v: int32): boolean { return m == v; }
function eqTone176(m: Tone176 | null, v: Tone176): boolean { return m == v; }
function eqText176(m: string | null, v: string): boolean { return m == v; }
function idMaybe176<T>(x: T): T | null { return x; }
function withDefault176(x: int32 | null = 5, y: int32 = 5): boolean { return x == y; }
function seven176(): int32 { return 7; }
function callOr176(f: (() => int32) | null): int32 { return f != null ? f() : -1; }
function callIt176(f: () => int32): int32 { return f(); }

template viaMaybe176(x: int32): boolean { return eqMaybe176(x, x); }
template viaTone176(t: Tone176): boolean { return eqTone176(t, t); }
template viaText176(s: string): boolean { return eqText176(s, s); }
template viaThunk176(): int32 { return callOr176(seven176) + callIt176(seven176); }

test "bug176: a template argument meeting an int32 | null formal wraps once" {
	assert viaMaybe176(3);
	assert viaMaybe176(4);
}

test "bug176: enum and string payloads through a template" {
	assert viaTone176(Tone176.High);
	assert viaTone176(Tone176.Low);
	assert viaText176("ok");
}

test "bug176: neighbours stay green — direct call, generic instantiation, default parameter" {
	assert eqMaybe176(3, 3);
	assert !eqMaybe176(null, 3);
	const g = idMaybe176<int32>(9);
	assert g == 9;
	assert withDefault176();
	assert withDefault176(6, 6);
	assert !withDefault176(null, 6);
}

test "bug176: a named function meeting a closure slot through a template wraps once" {
	assert viaThunk176() == 14;
	assert viaThunk176() == 14;
	assert callOr176(null) == -1;
}

test "bug176: module-level nullable consts keep their values" {
	assert module176 == 11;
	assert module176 != null;
	assert moduleFn176 != null;
	assert callOr176(moduleFn176) == 7;
}

const module176: int32 | null = 11;
const moduleFn176: (() => int32) | null = seven176;
