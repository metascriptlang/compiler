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
