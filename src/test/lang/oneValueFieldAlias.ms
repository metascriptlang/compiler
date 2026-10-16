// Language tests: an object with a one-value field is aliased by reference, so it stores that
// field; only a by-value union arm leaves its discriminator to the union tag.

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
type Key = match (kind: K) { K.A => { id: int32 }, K.B => { name: string } };

function setV(x: Wide): void { x.v = "p"; }
function showWide(x: Wide): string { return `${x.ok}:${x.v}`; }
function mkTagged(good: boolean): Tagged {
	return good ? { ok: true, v: "lib" } : { ok: false, e: "no" };
}
function pairOk(x: Pair): boolean { return x.ok; }
function shapeIsA(x: Shape): boolean { return x.kind == K.A; }

test "an object read as the wide type shows its one-value field" {
	const a: Narrow = { ok: true, v: "lib" };
	const b: Wide = a;
	assert b.ok;
	assert b.v == "lib";
}

test "a write through the wide view is read back through the narrow one" {
	const a: Narrow = { ok: true, v: "lib" };
	const b: Wide = a;
	b.v = "z";
	b.ok = false;
	assert a.v == "z";
	assert !a.ok;
}

test "a parameter of the wide type writes the narrow object" {
	const a: Narrow = { ok: true, v: "lib" };
	setV(a);
	assert a.v == "p";
}

test "a nested one-value field is aliased" {
	const a: { inner: Narrow } = { inner: { ok: true, v: "lib" } };
	const b: { inner: Wide } = a;
	assert b.inner.ok;
	assert b.inner.v == "lib";
}

test "a TS-written union narrowed by its discriminant passes as the wide type" {
	const t = mkTagged(true);
	assert t.ok;
	if (t.ok) assert showWide(t) == "true:lib";
}

test "an array of the wide type takes the narrow object" {
	const a: Narrow = { ok: true, v: "lib" };
	const xs: Wide[] = [];
	xs.push(a);
	assert xs.length == 1;
	assert xs[0].ok;
	assert xs[0].v == "lib";
}

test "a false field is stored too" {
	const a: NarrowNo = { ok: false, e: "no" };
	const b: WideNo = a;
	assert !b.ok;
	assert b.e == "no";
}

test "an enum-literal field is aliased" {
	const a: NarrowEnum = { kind: K.A, r: "lib" };
	const b: WideEnum = a;
	b.kind = K.B;
	assert a.kind == K.B;
	assert b.r == "lib";
}

test "an object becomes an arm by its stored fields" {
	const kinded: NarrowEnum = { kind: K.A, r: "lib" };
	const asShape: Shape = kinded;
	assert shapeIsA(asShape);
	const written: Narrow = { ok: true, v: "lib" };
	const asPair: Pair = { ok: true, value: written.v };
	assert pairOk(asPair);
}

test "an arm stores no discriminator, an object stores it" {
	assert sizeof(Pair) == 24;
	assert sizeof(Result<int32, string>) == 24;
	assert sizeof(Shape) == 24;
}

test "the arms of a union keep their payload at the tag" {
	const k: Key = { kind: K.B, name: "lib" };
	assert sizeof(Key) == 24;
	if (k.kind == K.B) assert k.name == "lib";
}
