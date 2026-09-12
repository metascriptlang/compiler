// bug149 — a BitSet expression inside a macro or @comptime body evaluated on the enum ordinals
// Symptom: `const s: BitSet<E> = E.A | E.C; ${s as uint32 as int32}` in a macro body expanded to 2 (0 | 2),
//          the runtime value is 5 (1 << 0 | 1 << 2); `s.has(E.C)` in a macro body failed with
//          "no host bridge for 'has'".
// Root cause: the Raiser pipeline (transformForRaiser) never ran lowerBitSet, so the VM saw the raw `|` on
//             the member ordinals and a call to the bodiless `has` extern.
// Fix: lowerBitSet runs at the tail of transformForRaiser, after lowerExtensionMethod, the way it trails the
//      backend pipelines in transformProgram.

import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserValueKind } from "../../raiser/value";

test "bug149: a union of two members is the or of their bits" {
	const r = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s as uint32 as int32;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 5;
}

test "bug149: has reads the member bit" {
	const r = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.has(E.C);");
	assert r.lastError == "";
	assert r.lastResult.kind == RaiserValueKind.Bool;
	assert r.lastResult.intVal == 1;
}

test "bug149: has is false for an absent member" {
	const r = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.has(E.B);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 0;
}

test "bug149: incl and excl rewrite the word" {
	const r = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; const t = s.incl(E.B).excl(E.A); return t as uint32 as int32;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 6;
}

test "bug149: intersection keeps the shared bit" {
	const r = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; const u = s & (E.C | E.B); return u as uint32 as int32;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 4;
}

test "bug149: isEmpty on the zero set and on a populated set" {
	const z = evalSourceFull("enum E { A, B, C } const z = 0 as BitSet<E>; return z.isEmpty();");
	assert z.lastError == "";
	assert z.lastResult.intVal == 1;
	const s = evalSourceFull("enum E { A, B, C } const s: BitSet<E> = E.A | E.C; return s.isEmpty();");
	assert s.lastError == "";
	assert s.lastResult.intVal == 0;
}

test "bug149: the 16-bit band shifts by the ordinal" {
	const r = evalSourceFull("enum E { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11 } const s: BitSet<E> = E.M11 | E.M1; return (s as uint32 as int32) + (s.has(E.M11) ? 100000 : 0) + (s.has(E.M0) ? 200000 : 0);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 102050;
}

const arrayEnum = "enum E { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39,M40,M41,M42,M43,M44,M45,M46,M47,M48,M49,M50,M51,M52,M53,M54,M55,M56,M57,M58,M59,M60,M61,M62,M63,M64,M65,M66,M67,M68,M69,M70,M71,M72,M73,M74,M75,M76,M77,M78,M79,M80,M81,M82,M83,M84,M85,M86,M87,M88,M89,M90,M91,M92,M93,M94,M95,M96,M97,M98,M99 }";

test "bug149: the array band reads and rewrites the member bits" {
	const r = evalSourceFull(arrayEnum + " const s: BitSet<E> = E.M99 | E.M1; return (s.has(E.M99) ? 1 : 0) + (s.has(E.M1) ? 2 : 0) + (s.has(E.M0) ? 4 : 0) + (s.incl(E.M70).has(E.M70) ? 8 : 0) + (s.excl(E.M99).has(E.M99) ? 16 : 0);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 11;
}

test "bug149: isEmpty on the zero array set and on a populated one" {
	const z = evalSourceFull(arrayEnum + " const z = 0 as BitSet<E>; return z.isEmpty();");
	assert z.lastError == "";
	assert z.lastResult.intVal == 1;
	const s = evalSourceFull(arrayEnum + " const s: BitSet<E> = E.M99 | E.M1; return s.isEmpty();");
	assert s.lastError == "";
	assert s.lastResult.intVal == 0;
}

test "bug149: equality on the array band compares every word" {
	const r = evalSourceFull(arrayEnum + " const a: BitSet<E> = E.M99 | E.M1; const b: BitSet<E> = E.M1 | E.M99; const c: BitSet<E> = E.M98 | E.M1; return (a == b ? 1 : 0) + (a != b ? 2 : 0) + (a == c ? 4 : 0) + (a != c ? 8 : 0);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 9;
}

test "bug149: intersection, union and symmetric difference on the array band" {
	const r = evalSourceFull(arrayEnum + " const a: BitSet<E> = E.M99 | E.M1; const b: BitSet<E> = E.M1 | E.M99; const c: BitSet<E> = E.M98 | E.M1; const d = a & c; const u = a | c; return (d.has(E.M1) ? 1 : 0) + (d.has(E.M99) ? 2 : 0) + (u.has(E.M98) ? 4 : 0) + (u.has(E.M99) ? 8 : 0) + ((a ^ b).isEmpty() ? 16 : 0);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 29;
}
test "bug149: the 64-bit band shifts past bit 31" {
	const r = evalSourceFull("enum E { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39 } const s: BitSet<E> = E.M39 | E.M1; const t: BitSet<E> = E.M7 | E.M1; return (s.has(E.M7) ? 1 : 0) + (s.has(E.M39) ? 2 : 0) + ((E.M33 | E.M0).has(E.M1) ? 4 : 0) + (s == t ? 8 : 0);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 2;
}
