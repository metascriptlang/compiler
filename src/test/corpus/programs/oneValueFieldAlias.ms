// @stdout: assign: z true
// @stdout: nested: true lib
// @stdout: ts union: true:lib
// @stdout: array: 1 true lib
// @stdout: false arm: false:no
// @stdout: enum field: true lib
// @stdout: arm from object: true true true
// @stdout: sizes: 24 24 24
// note: an object type with a one-value field is a reference, and a reference is read as every object type it is assignable to, so the object stores that field: `{ ok: true; v }` seen as `Readonly<{ ok: boolean; v }>` reads the same memory; a view that could write the field back is refused. Only the arm of a by-value `match` union or of `Result` stores no discriminator, because the union tag holds it, so an object reaches an arm by its stored fields and is never aliased. Covered: assignment, a nested field, a TS-written union narrowed into the wide type, an array element, a `false` field, an enum-literal field, an object converted into a boolean and an enum arm, and the sizes of the arms.

enum K { A, B }

type Narrow = { ok: true; v: string };
type Wide = { ok: boolean; v: string };
type NarrowNo = { ok: false; e: string };
type WideNo = { ok: boolean; e: string };
type NarrowEnum = { kind: K.A; r: string };
type WideEnum = { kind: K; r: string };
type Tagged = { ok: true; v: string } | { ok: false; e: string };
struct Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };
struct Shape = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };

function showWide(x: Readonly<Wide>): string { return `${x.ok}:${x.v}`; }
function mkTagged(good: boolean): Tagged {
	return good ? { ok: true, v: "lib" } : { ok: false, e: "no" };
}
function pairOk(x: Pair): boolean { return x.ok; }
function shapeIsA(x: Shape): boolean { return x.kind == K.A; }

function assign(): string {
	const a: Narrow = { ok: true, v: "lib" };
	const b: Readonly<Wide> = a;
	a.v = "z";
	return `${b.v} ${b.ok}`;
}

function nested(): string {
	const a: { inner: Narrow } = { inner: { ok: true, v: "lib" } };
	const b: Readonly<{ inner: Readonly<Wide> }> = a;
	return `${b.inner.ok} ${b.inner.v}`;
}

function tsUnion(): string {
	const t = mkTagged(true);
	if (t.ok) return showWide(t);
	return "none";
}

function arrayPush(): string {
	const a: Narrow = { ok: true, v: "lib" };
	const xs: Readonly<Wide>[] = [];
	xs.push(a);
	return `${xs.length} ${xs[0].ok} ${xs[0].v}`;
}

function falseArm(): string {
	const a: NarrowNo = { ok: false, e: "no" };
	const b: Readonly<WideNo> = a;
	return `${b.ok}:${b.e}`;
}

function enumField(): string {
	const a: NarrowEnum = { kind: K.A, r: "lib" };
	const b: Readonly<WideEnum> = a;
	return `${b.kind == K.A} ${b.r}`;
}

function armFromObject(): string {
	const written: Narrow = { ok: true, v: "lib" };
	const asPair: Pair = { ok: true, value: written.v };
	const kinded: NarrowEnum = { kind: K.A, r: "lib" };
	const asShape: Shape = kinded;
	return `${pairOk(asPair)} ${shapeIsA(asShape)} ${shapeIsA(kinded)}`;
}

console.log("assign:", assign());
console.log("nested:", nested());
console.log("ts union:", tsUnion());
console.log("array:", arrayPush());
console.log("false arm:", falseArm());
console.log("enum field:", enumField());
console.log("arm from object:", armFromObject());
console.log("sizes:", sizeof(Pair), sizeof(Result<int32, string>), sizeof(Shape));
