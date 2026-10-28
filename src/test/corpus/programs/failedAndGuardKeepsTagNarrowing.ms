// @stdout: pair true false true false
// @stdout: single one s other
// @stdout: match nan 3 2.5 label
// @stdout: residual s n
enum K { A, B, C, E }
struct D = match (kind: K) {
	K.A => { s: string },
	K.B => { n: int64 },
	K.C => { t: int64 },
	K.E => { u: boolean },
};
function pair(a: D, b: D): boolean {
	if (a.kind == K.A && b.kind == K.A) return a.s == b.s;
	if (a.kind == K.B && b.kind == K.B) return a.n == b.n;
	return false;
}
function single(a: D): string {
	if (a.kind == K.B && a.n == 1) return "one";
	if (a.kind == K.A) return a.s;
	return "other";
}
function describe(value: D): string {
	if (value.kind == K.C && value.t == 0) return "nan";
	return match (value.kind) {
		K.A => value.s,
		K.B => value.n.toString(),
		K.C => (value.t as float64 / 2).toString(),
		K.E => "label",
	};
}
function residual(a: D): string {
	if (a.kind == K.E) return "e";
	if (a.kind == K.B && a.n == 1) return "n";
	if (a.kind == K.A) return a.s;
	return "c";
}
const sa: D = { kind: K.A, s: "s" };
const sb: D = { kind: K.B, n: 1 };
const sb2: D = { kind: K.B, n: 2 };
const sc: D = { kind: K.C, t: 5 };
const sc0: D = { kind: K.C, t: 0 };
const se: D = { kind: K.E, u: true };
console.log("pair", pair(sb, sb).toString(), pair(sb, sb2).toString(), pair(sa, sa).toString(), pair(sa, sb).toString());
console.log("single", single(sb), single(sa), single(sc));
console.log("match", describe(sc0), describe({ kind: K.B, n: 3 }), describe(sc), describe(se));
console.log("residual", residual(sa), residual(sb));
