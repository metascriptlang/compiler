// @stdout: assign: z true
// @stdout: write through the wide view: false false
// @stdout: parameter: p
// @stdout: nested: true lib
// @stdout: ts union: true:lib
// @stdout: array: 1 true lib
// @stdout: false arm: false:no
// @stdout: enum field: true true lib
// @stdout: arm from object: true true true
// @stdout: sizes: 24 24 24
// note: an object type with a one-value field is a reference, and a reference is read as every object type it is assignable to, so the object stores that field: `{ ok: true; v }` seen as `{ ok: boolean; v }` reads and writes the same memory. Only the arm of a by-value `match` union or of `Result` stores no discriminator, because the union tag holds it, so an object reaches an arm by its stored fields and is never aliased. Covered: assignment, a write through the wide view, a parameter, a nested field, a TS-written union narrowed into the wide type, an array element, a `false` field, an enum-literal field, an object converted into a boolean and an enum arm, and the sizes of the arms.

enum K { A, B }

type Narrow = { ok: true; v: string };
type Wide = { ok: boolean; v: string };
type NarrowNo = { ok: false; e: string };
type WideNo = { ok: boolean; e: string };
type NarrowEnum = { kind: K.A; r: string };
type WideEnum = { kind: K; r: string };
type Tagged = { ok: true; v: string } | { ok: false; e: string };
type Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };
type Shape = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };

function setV(x: Wide): void { x.v = "p"; }
function showWide(x: Wide): string { return `${x.ok}:${x.v}`; }
function mkTagged(good: boolean): Tagged {
	return good ? { ok: true, v: "lib" } : { ok: false, e: "no" };
}
function pairOk(x: Pair): boolean { return x.ok; }
function shapeIsA(x: Shape): boolean { return x.kind == K.A; }

function assign(): string {
	const a: Narrow = { ok: true, v: "lib" };
	const b: Wide = a;
	b.v = "z";
	return `${a.v} ${b.ok}`;
}

function writeThroughWide(): string {
	const a: Narrow = { ok: true, v: "lib" };
	const b: Wide = a;
	b.ok = false;
	return `${a.ok} ${b.ok}`;
}

function parameter(): string {
	const a: Narrow = { ok: true, v: "lib" };
	setV(a);
	return a.v;
}

function nested(): string {
	const a: { inner: Narrow } = { inner: { ok: true, v: "lib" } };
	const b: { inner: Wide } = a;
	return `${b.inner.ok} ${b.inner.v}`;
}

function tsUnion(): string {
	const t = mkTagged(true);
	if (t.ok) return showWide(t);
	return "none";
}

function arrayPush(): string {
	const a: Narrow = { ok: true, v: "lib" };
	const xs: Wide[] = [];
	xs.push(a);
	return `${xs.length} ${xs[0].ok} ${xs[0].v}`;
}

function falseArm(): string {
	const a: NarrowNo = { ok: false, e: "no" };
	const b: WideNo = a;
	return `${b.ok}:${b.e}`;
}

function enumField(): string {
	const a: NarrowEnum = { kind: K.A, r: "lib" };
	const b: WideEnum = a;
	b.kind = K.B;
	return `${a.kind == K.B} ${b.kind == K.B} ${b.r}`;
}

function armFromObject(): string {
	const written: Narrow = { ok: true, v: "lib" };
	const asPair: Pair = { ok: true, value: written.v };
	const kinded: NarrowEnum = { kind: K.A, r: "lib" };
	const asShape: Shape = kinded;
	return `${pairOk(asPair)} ${shapeIsA(asShape)} ${shapeIsA(kinded)}`;
}

console.log("assign:", assign());
console.log("write through the wide view:", writeThroughWide());
console.log("parameter:", parameter());
console.log("nested:", nested());
console.log("ts union:", tsUnion());
console.log("array:", arrayPush());
console.log("false arm:", falseArm());
console.log("enum field:", enumField());
console.log("arm from object:", armFromObject());
console.log("sizes:", sizeof(Pair), sizeof(Result<int32, string>), sizeof(Shape));
