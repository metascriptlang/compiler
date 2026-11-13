// @stdout: a b c d e f g h i j
// note: a local that is a tuple, a value struct or a closure keeps the objects it holds while a read through an Unowned edge that can reach one may still run in its scope, as a class or array local does. Each function hands the local to a holder that dies in an inner scope or to a sink parameter, then reads the object back through the edge; before, C and the Raiser stopped with "edge was read after its target was destroyed" while JS printed.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; }
struct S { p: P; n: int32; }
struct SArr { ps: P[]; n: int32; }
class TupBag { t: [P, int32] | null = null; }
class NestBag { t: [[P, int32], int32] | null = null; }
class SBag { s: S | null = null; }
class SArrBag { s: SArr | null = null; }
class FnBag { f: (() => string) | null = null; }
function firstOfTuple(sink t: [P, int32]): int32 { return t[1]; }
function firstOfStruct(sink s: S): int32 { return s.n; }
function callIt(sink f: () => string): int32 { return f().length; }
function makeReader(h: H, name: string): () => string { const p = new P(name); h.up = p; return (): string => p.name; }

function tupleToHolder(): string {
	const h = new H();
	const t: [P, int32] = [new P("a"), 1];
	h.up = t[0];
	{ const b = new TupBag(); b.t = t; }
	return h.up!.name;
}

function tupleToSink(): string {
	const h = new H();
	const t: [P, int32] = [new P("b"), 1];
	h.up = t[0];
	const n = firstOfTuple(t);
	return h.up!.name;
}

function nestedTuple(): string {
	const h = new H();
	const t: [[P, int32], int32] = [[new P("c"), 1], 2];
	h.up = t[0][0];
	{ const b = new NestBag(); b.t = t; }
	return h.up!.name;
}

function structToHolder(): string {
	const h = new H();
	const s: S = { p: new P("d"), n: 1 };
	h.up = s.p;
	{ const b = new SBag(); b.s = s; }
	return h.up!.name;
}

function structToSink(): string {
	const h = new H();
	const s: S = { p: new P("e"), n: 1 };
	h.up = s.p;
	const n = firstOfStruct(s);
	return h.up!.name;
}

function structWithArray(): string {
	const h = new H();
	const s: SArr = { ps: [new P("f")], n: 1 };
	h.up = s.ps[0];
	{ const b = new SArrBag(); b.s = s; }
	return h.up!.name;
}

function closureToHolder(): string {
	const h = new H();
	const p = new P("g");
	h.up = p;
	const f = (): string => p.name;
	{ const b = new FnBag(); b.f = f; }
	return h.up!.name;
}

function closureToSink(): string {
	const h = new H();
	const p = new P("h");
	h.up = p;
	const f = (): string => p.name;
	const n = callIt(f);
	return h.up!.name;
}

function closureOnlyOwner(): string {
	const h = new H();
	const f = makeReader(h, "i");
	{ const b = new FnBag(); b.f = f; }
	return h.up!.name;
}

function closureCapturesTwo(): string {
	const h = new H();
	const p = new P("x");
	const q = new P("j");
	h.up = q;
	const f = (): string => p.name + q.name;
	{ const b = new FnBag(); b.f = f; }
	return h.up!.name;
}

console.log([tupleToHolder(), tupleToSink(), nestedTuple(), structToHolder(), structToSink(), structWithArray(), closureToHolder(), closureToSink(), closureOnlyOwner(), closureCapturesTwo()].join(" "));
