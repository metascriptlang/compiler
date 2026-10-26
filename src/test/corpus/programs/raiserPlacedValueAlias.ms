// @stdout: union Bold A7 | struct 1 x 2 y | let x mut | nested 1 5 | nested let 50 5 | holder Bkeep A3 | plain I1 J2 | value ok old err new | value let ok old ok mut
// note: a copy of a union or struct held in a field keeps its own value when the field is assigned afterwards, and an in-place change of the copy leaves the field alone: a union of struct arms, a declared value union, a struct, and one nested.

struct A { kind: "a"; n: int32; }
struct B { kind: "b"; s: string; }
type U = A | B;
struct I { kind: "i"; n: int32; }
struct J { kind: "j"; m: int32; }
type IJ = I | J;
struct V = match (ok: boolean) { true => { value: string }, false => { error: string } };
struct P { a: A; s: string; }
struct H { u: U; tag: string; }
class Owner {
	u: U = { kind: "b", s: "old" };
	p: P = { a: { kind: "a", n: 1 }, s: "x" };
	ij: IJ = { kind: "i", n: 1 };
	v: V = { ok: true, value: "old" };
	h: H = { u: { kind: "b", s: "keep" }, tag: "t" };
}

function show(u: U): string {
	if (u.kind == "a") return "A" + u.n.toString();
	return "B" + u.s;
}
function showIJ(u: IJ): string {
	if (u.kind == "i") return "I" + u.n.toString();
	return "J" + u.m.toString();
}
function showV(v: V): string {
	if (v.ok) return "ok " + v.value;
	return "err " + v.error;
}

function main(): void {
	const out: string[] = [];
	const o = new Owner();
	const u: U = o.u;
	o.u = { kind: "a", n: 7 };
	out.push("union " + show(u) + " " + show(o.u));

	const p: P = o.p;
	o.p = { a: { kind: "a", n: 2 }, s: "y" };
	out.push("struct " + p.a.n.toString() + " " + p.s + " " + o.p.a.n.toString() + " " + o.p.s);

	const o2 = new Owner();
	let p2: P = o2.p;
	p2.s = "mut";
	out.push("let " + o2.p.s + " " + p2.s);

	const o3 = new Owner();
	const a3: A = o3.p.a;
	o3.p.a = { kind: "a", n: 5 };
	let a4: A = o3.p.a;
	out.push("nested " + a3.n.toString() + " " + o3.p.a.n.toString());
	a4.n = 50;
	out.push("nested let " + a4.n.toString() + " " + o3.p.a.n.toString());

	const o4 = new Owner();
	const h: H = o4.h;
	o4.h = { u: { kind: "a", n: 3 }, tag: "z" };
	out.push("holder " + show(h.u) + " " + show(o4.h.u));

	const o5 = new Owner();
	const ij: IJ = o5.ij;
	o5.ij = { kind: "j", m: 2 };
	out.push("plain " + showIJ(ij) + " " + showIJ(o5.ij));

	const o6 = new Owner();
	const v: V = o6.v;
	o6.v = { ok: false, error: "new" };
	out.push("value " + showV(v) + " " + showV(o6.v));

	const o7 = new Owner();
	let v7: V = o7.v;
	if (v7.ok) v7.value = "mut";
	out.push("value let " + showV(o7.v) + " " + showV(v7));
	console.log(out.join(" | "));
}
main();
