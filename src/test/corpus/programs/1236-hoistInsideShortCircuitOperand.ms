// @stdout: and:t f f|1
// @stdout: or:t t t|1
// @stdout: not:f t f|1
// @stdout: deep:t f f|2
// @stdout: tern:t f f|1
// @stdout: if:y n n|1
// @stdout: assign:t f f|1
// @stdout: and2:f f t|4
// @stdout: or2:t t t|4
// @stdout: if2:f f t|4
// @stdout: tern2:f f t|4
class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
	get(): int32 { return this.v; }
}
let calls: int32 = 0;
function lenOf(s: string): int32 { calls++; return s.length; }
function tick(b: Box): int32 { calls++; return b.get(); }
function yes(s: string): boolean { return s == "1"; }
function tf(b: boolean): string { return b ? "t" : "f"; }
function report(name: string, a: boolean, b: boolean, c: boolean): void {
	console.log(`${name}:${tf(a)} ${tf(b)} ${tf(c)}|${calls}`);
	calls = 0;
}

function andOp(a: boolean, c: int32): boolean {
	const r = yes(String(c)) && a && lenOf(String(c)) == 1;
	return r;
}
function orOp(a: boolean, c: int32): boolean {
	const r = a || yes(String(c)) || lenOf(String(c)) == 1;
	return r;
}
function notOp(a: boolean, c: int32): boolean {
	const r = a && !(c == 1 && lenOf(String(c)) == 1);
	return r;
}
function deepOp(a: boolean, c: int32): boolean {
	const r = a && (c > 0 && (c < 5 && lenOf(String(c)) == 1 && tick(new Box(c)) == 1));
	return r;
}
function ternOp(a: boolean, c: int32): boolean {
	const r = a ? !(c == 1 && lenOf(String(c)) == 1) : false;
	return r;
}
function ifOp(a: boolean, c: int32): string {
	if (a && !(c == 1 && lenOf(String(c)) == 1)) return "y";
	return "n";
}
function assignOp(a: boolean, c: int32): boolean {
	let r = false;
	r = a && !(c == 1 && tick(new Box(c)) == 1);
	return r;
}

report("and", andOp(true, 1), andOp(true, 2), andOp(false, 1));
report("or", orOp(false, 1), orOp(true, 2), orOp(false, 3));
report("not", notOp(true, 1), notOp(true, 2), notOp(false, 1));
report("deep", deepOp(true, 1), deepOp(false, 1), deepOp(true, 7));
report("tern", ternOp(true, 2), ternOp(true, 1), ternOp(false, 1));
console.log(`if:${ifOp(true, 2)} ${ifOp(true, 1)} ${ifOp(false, 1)}|${calls}`);
calls = 0;
report("assign", assignOp(true, 2), assignOp(true, 1), assignOp(false, 1));

class Ty { n: int32; constructor(n: int32) { this.n = n; } }
function getP(t: Ty, k: string): Ty { calls++; return new Ty(t.n + k.length); }
function unwrap(t: Ty): Ty { calls++; return new Ty(t.n); }
function unres(t: Ty): boolean { return t.n > 100; }
function carries(t: Ty): boolean { return t.n == 4; }
function and2(t: Ty, x: Ty | null, k: string): boolean {
	const missing = unres(getP(t, k)) && !(k == "length" && carries(unwrap(x!)));
	return missing;
}
function or2(t: Ty, x: Ty | null, k: string): boolean {
	const missing = unres(getP(t, k)) || !(k == "length" && carries(unwrap(x!)));
	return missing;
}
function if2(t: Ty, x: Ty | null, k: string): boolean {
	if (unres(getP(t, k)) && !(k == "length" && carries(unwrap(x!)))) return true;
	return false;
}
function tern2(t: Ty, x: Ty | null, k: string): boolean {
	const missing = unres(getP(t, k)) ? !(k == "length" && carries(unwrap(x!))) : false;
	return missing;
}
function three(name: string, f: (t: Ty, x: Ty | null, k: string) => boolean): void {
	const a = f(new Ty(1), new Ty(3), "abc");
	const b = f(new Ty(1), new Ty(3), "length");
	const c = f(new Ty(500), new Ty(3), "length");
	report(name, a, b, c);
}
three("and2", and2);
three("or2", or2);
three("if2", if2);
three("tern2", tern2);
