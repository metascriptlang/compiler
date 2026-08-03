// bug076 — a lambda's `unknown` return type lost its UserUnknown stamp, so the
// value it produced was not seen as pointer-shaped and `shimCallArg` passed
// `&local` to a closure param that takes the value. Reference: lambdas and
// declared procs share one path (semexprs.nim:3525 nkLambdaKinds → semProcAux →
// semParamList → semProcTypeNode) and the return type is gated on the
// ANNOTATION BEING WRITTEN (semtypes.nim:1560 `n[0].kind != nkEmpty`), never on
// what it resolved to — `auto`/tyAnything is kept, not discarded (semtypes.nim:1593).
//
// Assert on a READ-BACK FIELD VALUE, never on a length: a wrong pointer still
// yields length 1 for a container that was pushed to, which is how the first
// version of this repro passed while being broken.

type Opaque = unknown;

interface Cell {
	id: number;
	fn: () => void;
}

interface Kit {
	make: (n: number) => Opaque;
	readId: (c: Opaque) => number;
}

function kit(): Kit {
	return {
		make: (n: number): Opaque => {
			const c: Cell = { id: n, fn: () => {} };
			return c as unknown as Opaque;
		},
		readId: (c: Opaque): number => (c as unknown as Cell).id,
	};
}

function buildDeclared(k: Kit): Opaque {
	return k.make(11);
}

test "declared function result reaches a closure param intact" {
	const k = kit();
	const d = buildDeclared(k);
	assert k.readId(d) === 11, "declared: got " + k.readId(d).toString();
}

test "lambda with an explicit unknown return reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit): unknown => {
		return kk.make(22);
	};
	const d = build(k);
	assert k.readId(d) === 22, "explicit unknown: got " + k.readId(d).toString();
}

test "lambda annotated with an alias of unknown reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit): Opaque => {
		return kk.make(33);
	};
	const d = build(k);
	assert k.readId(d) === 33, "alias annotation: got " + k.readId(d).toString();
}

test "lambda with an INFERRED unknown return reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit) => {
		return kk.make(44);
	};
	const d = build(k);
	assert k.readId(d) === 44, "inferred: got " + k.readId(d).toString();
}

test "function expression with an unknown return reaches a closure param intact" {
	const k = kit();
	const build = function (kk: Kit): Opaque {
		return kk.make(55);
	};
	const d = build(k);
	assert k.readId(d) === 55, "function expression: got " + k.readId(d).toString();
}

test "lambda result survives being stored and read twice" {
	const k = kit();
	const build = (kk: Kit): Opaque => kk.make(66);
	const d = build(k);
	assert k.readId(d) === 66, "first read: got " + k.readId(d).toString();
	assert k.readId(d) === 66, "second read: got " + k.readId(d).toString();
}

test "lambda typed by CONTEXT reaches a closure param intact" {
	const k = kit();
	const build: (kk: Kit) => Opaque = (kk) => kk.make(77);
	const d = build(k);
	assert k.readId(d) === 77, "contextual: got " + k.readId(d).toString();
}

test "unknown-annotated lambda PARAM relays to a closure param intact" {
	const k = kit();
	const relay = (kk: Kit, c: unknown): number => kk.readId(c);
	const d = k.make(88);
	assert relay(k, d) === 88, "param relay: got " + relay(k, d).toString();
}

test "nested lambda returning unknown reaches a closure param intact" {
	const k = kit();
	const outer = (kk: Kit): Opaque => {
		const inner = (n: number): Opaque => kk.make(n);
		return inner(99);
	};
	const d = outer(k);
	assert k.readId(d) === 99, "nested: got " + k.readId(d).toString();
}
