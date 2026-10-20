// @stdout: boolean: z z
// @stdout: enum: 7 7
// @stdout: generic: 5 5
// @stdout: parameter: w
// @stdout: narrowed argument: p
// @stdout: held by a struct: z
// @stdout: array element: q
// @stdout: written form: viaTs viaAlias
// @stdout: sizes: 16 16 16 24
// note: `type X = match (...)` declares the union of objects a TypeScript author writes by hand: each arm is an object held by reference, so a store aliases (`let b = a` then a write through `b` shows through `a`), a write through a parameter reaches the caller, and a narrowed arm passed where `{ ok: true; v: string }` is expected is the same object. The written form `{ ok: true; v } | { ok: false; e }` is the same type, so the two pass for each other. Covered: boolean disc, enum disc, the generic form, a parameter, a narrowed argument, a struct field one level down, an array element, the written form and the sizes against `Result`, which keeps its by-value layout.

enum K { A, B }

type Pair = match (ok: boolean) { true => { v: string }, false => { e: string } };
type PairWritten = { ok: true; v: string } | { ok: false; e: string };
type Shape = match (kind: K) { K.A => { x: int32 }, K.B => { y: string } };
type Either<T, E> = match (ok: boolean) { true => { value: T }, false => { error: E } };
struct Holder { pair: Pair; n: int32 }

function show(p: Pair): string { return p.ok ? p.v : p.e; }
function setV(p: Pair): void { if (p.ok) p.v = "w"; }
function setNarrowed(t: { ok: true; v: string }): void { t.v = "p"; }
function setWritten(p: PairWritten): void { if (p.ok) p.v = "viaTs"; }
function showWritten(p: PairWritten): string { return p.ok ? p.v : p.e; }
function shapeText(s: Shape): string { return s.kind == K.A ? `${s.x}` : s.y; }
function eitherText(e: Either<int32, string>): string { return e.ok ? `${e.value}` : e.error; }

function boolean(): string {
	const a: Pair = { ok: true, v: "lib" };
	const b = a;
	if (b.ok) b.v = "z";
	return show(a) + " " + show(b);
}

function enumDisc(): string {
	const a: Shape = { kind: K.A, x: 1 };
	const b = a;
	if (b.kind == K.A) b.x = 7;
	return shapeText(a) + " " + shapeText(b);
}

function generic(): string {
	const a: Either<int32, string> = { ok: true, value: 1 };
	const b = a;
	if (b.ok) b.value = 5;
	return eitherText(a) + " " + eitherText(b);
}

function parameter(): string {
	const a: Pair = { ok: true, v: "lib" };
	setV(a);
	return show(a);
}

function narrowedArgument(): string {
	const a: Pair = { ok: true, v: "lib" };
	if (a.ok) setNarrowed(a);
	return show(a);
}

function heldByStruct(): string {
	const h: Holder = { pair: { ok: true, v: "lib" }, n: 1 };
	const g = h;
	if (g.pair.ok) g.pair.v = "z";
	return show(h.pair);
}

function arrayElement(): string {
	const a: Pair = { ok: true, v: "lib" };
	const xs: Pair[] = [a];
	const c = xs[0];
	if (c.ok) c.v = "q";
	return show(a);
}

function writtenForm(): string {
	const a: Pair = { ok: true, v: "lib" };
	setWritten(a);
	const t: PairWritten = a;
	const first = showWritten(a);
	if (t.ok) t.v = "viaAlias";
	return first + " " + showWritten(a);
}

console.log("boolean: " + boolean());
console.log("enum: " + enumDisc());
console.log("generic: " + generic());
console.log("parameter: " + parameter());
console.log("narrowed argument: " + narrowedArgument());
console.log("held by a struct: " + heldByStruct());
console.log("array element: " + arrayElement());
console.log("written form: " + writtenForm());
console.log(`sizes: ${sizeof(Pair)} ${sizeof(PairWritten)} ${sizeof(Shape)} ${sizeof(Result<int32, string>)}`);
