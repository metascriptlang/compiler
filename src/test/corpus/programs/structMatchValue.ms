// @stdout: boolean: lib z
// @stdout: enum: lib z
// @stdout: generic: lib z
// @stdout: assigned: lib z
// @stdout: arm changed: 1 lib
// @stdout: held: lib z
// @stdout: type form: true
// @stdout: sizes: 24 16 24 16
// note: `struct X = match (...)` declares a discriminated union as a value: a store copies it, where `type X = match (...)` shares it, so a write through the copy leaves the original, on C, on the Raiser (which copies by the arm the discriminant selects) and on JS (where the store runs the copy routine of the value union, one case per arm). Covered: a boolean disc, an enum disc, the generic form, assignment over a union of another arm, a union held by a struct, and the sizes against the type form, whose arms are references.

enum K { A, B }

struct Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };
struct Shape = match (kind: K) { K.A => { name: string }, K.B => { count: int32 } };
struct Either<T, E> = match (ok: boolean) { true => { value: T }, false => { error: E } };
type SharedPair = match (ok: boolean) { true => { value: string }, false => { error: string } };
type SharedShape = match (kind: K) { K.A => { name: string }, K.B => { count: int32 } };
struct Holder { pair: Pair; n: int32 }

function mkPair(): Pair { return { ok: true, value: "lib" }; }
function mkShape(): Shape { return { kind: K.A, name: "lib" }; }
function mkEither(): Either<string, int32> { return { ok: true, value: "lib" }; }

function valueOf(p: Pair): string { return p.ok ? p.value : p.error; }
function nameOf(s: Shape): string { return s.kind == K.A ? s.name : `${s.count}`; }
function eitherValue(e: Either<string, int32>): string { return e.ok ? e.value : `${e.error}`; }

function boolean(): string {
	const a = mkPair();
	const b = a;
	if (b.ok) b.value = "z";
	return valueOf(a) + " " + valueOf(b);
}

function enumDisc(): string {
	const a = mkShape();
	const b = a;
	if (b.kind == K.A) b.name = "z";
	return nameOf(a) + " " + nameOf(b);
}

function generic(): string {
	const a = mkEither();
	const b = a;
	if (b.ok) b.value = "z";
	return eitherValue(a) + " " + eitherValue(b);
}

function assigned(): string {
	const a = mkPair();
	let b: Pair = { ok: false, error: "no" };
	b = a;
	if (b.ok) b.value = "z";
	return valueOf(a) + " " + valueOf(b);
}

function armChanged(): string {
	let b: Shape = { kind: K.B, count: 3 };
	b = mkShape();
	return `${b.kind == K.A ? 1 : 2} ${nameOf(b)}`;
}

function held(): string {
	const h: Holder = { pair: mkPair(), n: 1 };
	const g = h;
	if (g.pair.ok) g.pair.value = "z";
	return valueOf(h.pair) + " " + valueOf(g.pair);
}

function typeForm(): boolean {
	const a: SharedPair = { ok: true, value: "lib" };
	const s: SharedShape = { kind: K.B, count: 3 };
	return a.ok && s.kind == K.B;
}

console.log("boolean: " + boolean());
console.log("enum: " + enumDisc());
console.log("generic: " + generic());
console.log("assigned: " + assigned());
console.log("arm changed: " + armChanged());
console.log("held: " + held());
console.log("type form: " + typeForm());
console.log(`sizes: ${sizeof(Pair)} ${sizeof(SharedPair)} ${sizeof(Shape)} ${sizeof(SharedShape)}`);
