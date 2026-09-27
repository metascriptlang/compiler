// bug332 — every lifted hook with an if and no else carried a NullLiteral statement
//
// Symptom:    the variant chain of a tagged union's Destroy/WasMoved, the tag guard of
//             a `float64 | string` field, and each field test of a lifted struct or
//             tuple Eq emitted `/* unsupported stmt: NullLiteral */`, so the C
//             statement fallback could not fail loud (99 hits in the self-host).
//
// Root cause: destructorLifting passed makeNull(loc) as the missing else of makeIf.
//
// Fix:        those sites pass null: the if has no else.

import { compileToC } from "../helpers";

test "bug332: lifted union, struct and tuple hooks carry no NullLiteral statement" {
	const src = `
enum K { A, B, C }
type D = match (kind: K) {
	K.A => { s: string },
	K.B => { n: int32, t: string },
	K.C => { x: float64 },
};
struct P {
	v: float64 | string;
	w: int32;
}
struct Q {
	a: int32;
	b: string;
}
function run(): void {
	const d: D = { kind: K.B, n: 1, t: "x" + "y" };
	let e: D = d;
	e = { kind: K.A, s: "a" + "b" };
	const p: P = { v: "q" + "r", w: 1 };
	let q: P = p;
	q = { v: 2.5, w: 2 };
	const qa: Q = { a: 1, b: "m" + "n" };
	const qb: Q = { a: 1, b: "m" + "n" };
	const t1: [int32, string] = [1, "a"];
	const t2: [int32, string] = [1, "b"];
	console.log((qa == qb).toString() + (t1 == t2).toString() + (e.kind == K.A).toString() + q.w.toString());
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("QEq(");
		assert c.value.contains("WasMoved(");
		assert !c.value.contains("unsupported stmt");
	}
}
