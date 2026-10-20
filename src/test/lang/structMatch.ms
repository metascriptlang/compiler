// `struct X = match (...) { ... }` declares a discriminated union as a value: arms held by value
// and a copy where `type X = match` shares the union.

enum Kind { Lib, App }

struct Pair = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
}

struct Shape = match (kind: Kind) {
	Kind.Lib => { name: string },
	Kind.App => { count: int32 },
}

struct Either<T, E> = match (ok: boolean) {
	true => { value: T },
	false => { error: E },
}

type SharedPair = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
}

type SharedShape = match (kind: Kind) {
	Kind.Lib => { name: string },
	Kind.App => { count: int32 },
}

struct Holder { pair: Pair; n: int32 }

function mkPair(): Pair {
	return { ok: true, value: "lib" };
}

function mkShape(): Shape {
	return { kind: Kind.Lib, name: "lib" };
}

function mkEither(): Either<string, int32> {
	return { ok: true, value: "lib" };
}

function describe(s: Shape): int32 {
	return match (s.kind) {
		Kind.Lib => 1,
		Kind.App => 2,
	};
}

test "a boolean struct match is copied on assignment" {
	const a = mkPair();
	const b = a;
	if (b.ok) b.value = "z";
	if (a.ok) assert a.value == "lib";
	if (b.ok) assert b.value == "z";
}

test "an enum struct match is copied on assignment" {
	const a = mkShape();
	const b = a;
	if (b.kind == Kind.Lib) b.name = "z";
	if (a.kind == Kind.Lib) assert a.name == "lib";
	if (b.kind == Kind.Lib) assert b.name == "z";
}

test "a generic struct match is copied on assignment" {
	const a = mkEither();
	const b = a;
	if (b.ok) b.value = "z";
	if (a.ok) assert a.value == "lib";
	if (b.ok) assert b.value == "z";
}

test "a struct match written over another keeps the two apart" {
	const a = mkPair();
	let b: Pair = { ok: false, error: "no" };
	b = a;
	if (b.ok) b.value = "z";
	if (a.ok) assert a.value == "lib";
}

test "a struct match written over another may change its arm" {
	let b: Shape = { kind: Kind.App, count: 3 };
	b = mkShape();
	assert describe(b) == 1;
	if (b.kind == Kind.Lib) assert b.name == "lib";
}

test "a struct match held by a struct is copied with it" {
	const h: Holder = { pair: mkPair(), n: 1 };
	const g = h;
	if (g.pair.ok) g.pair.value = "z";
	if (h.pair.ok) assert h.pair.value == "lib";
}

test "a struct match holds its arms by value, the type form by reference" {
	assert sizeof(Pair) == 24;
	assert sizeof(Shape) == 24;
	assert sizeof(SharedPair) == 16;
	assert sizeof(SharedShape) == 16;
}

test "a struct match narrows by its discriminant" {
	const s = mkShape();
	assert s.kind == Kind.Lib;
	if (s.kind == Kind.Lib) assert s.name == "lib";
	const p: Pair = { ok: false, error: "no" };
	if (!p.ok) assert p.error == "no";
}

test "a struct match is matched exhaustively" {
	assert describe(mkShape()) == 1;
	assert describe({ kind: Kind.App, count: 3 }) == 2;
}

test "the type form declares the same arms and narrowing" {
	const a: SharedPair = { ok: true, value: "lib" };
	if (a.ok) assert a.value == "lib";
	const s: SharedShape = { kind: Kind.App, count: 3 };
	if (s.kind == Kind.App) assert s.count == 3;
}
