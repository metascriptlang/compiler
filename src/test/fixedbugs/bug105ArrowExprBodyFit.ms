// bug105 — an expression-body arrow skipped fitNode on its implicit return
//
// Symptom:    `{ g: (x: int32) => x }` against a field typed
//             `(x: int32) => int32 | null` failed to build on the C backend
//             with `assigning to 'Maybe_pN' from incompatible type` — the body
//             value was never wrapped into the Maybe carrier. An explicit
//             `: int32 | null` annotation on the arrow failed identically, and
//             so did `=> null` (void* into Maybe) and `=> namedFn` into a
//             closure-returning slot (fn-ptr into msClosure). The same arrow
//             with a block body `{ return x; }` was green. JS was unaffected
//             (Maybe is de-materialized there).
// Root cause: fitNode is the single converging point for value-meets-formal
//             coercions ("no position can forget it"), reached from every
//             ReturnStmt via checkReturnStmt. The implicit return of an
//             expression-body arrow never went through it —
//             checkAnonymousFunction only passed the expected return type to
//             checkExpr as a contextual hint, which coerces nothing.
// Fix:        checkArrowExpr reseats a non-block arrowBody through fitNode
//             against the checked closure type's return (awaited-unwrapped for
//             async arrows), mirroring checkReturnStmt.

interface Ops105 {
	g: (x: int32) => int32 | null;
}

interface StrOps105 {
	s: (x: string) => string | null;
}

type NullFn105 = (x: int32) => int32 | null;

interface Holder105 {
	h: () => () => int32;
}

function inner105(): int32 {
	return 7;
}

test "expr-body arrow into a nullable-returning fn field wraps the Maybe" {
	const o: Ops105 = { g: (x: int32) => x };
	const r = o.g(5);
	assert r !== null;
	assert r! === 5;
}

test "annotated expr-body arrow wraps the Maybe" {
	const o: Ops105 = { g: (x: int32): int32 | null => x };
	const r = o.g(6);
	assert r !== null;
	assert r! === 6;
}

test "typed-const expr-body arrow wraps the Maybe" {
	const f: NullFn105 = (x: int32) => x;
	const r = f(4);
	assert r !== null;
	assert r! === 4;
}

test "expr-body null literal retypes to the Maybe carrier" {
	const o: Ops105 = { g: (x: int32) => null };
	assert o.g(1) === null;
}

test "string payload expr-body arrow wraps the Maybe" {
	const o: StrOps105 = { s: (x: string) => x };
	const r = o.s("hi");
	assert r !== null;
	assert r! === "hi";
}

test "named function expr-body auto-wraps into a closure" {
	const o: Holder105 = { h: () => inner105 };
	const f = o.h();
	assert f() === 7;
}

function use105(cb: (x: int32) => int32 | null): int32 | null {
	return cb(3);
}

test "ternary expr-body arrow wraps the Maybe" {
	const o: Ops105 = { g: (x: int32) => (x > 2 ? x : null) };
	assert o.g(5) !== null;
	assert o.g(1) === null;
}

test "call-arg expr-body arrow wraps the Maybe" {
	const r = use105((x: int32) => x);
	assert r !== null;
	assert r! === 3;
}

test "block-body arrow neighbour stays green" {
	const o: Ops105 = { g: (x: int32) => { return x; } };
	const r = o.g(2);
	assert r !== null;
	assert r! === 2;
}
