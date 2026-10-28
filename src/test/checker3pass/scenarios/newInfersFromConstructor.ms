// Scenario: `new C(args)` without type arguments binds C's type parameters from the
// constructor arguments, as a call to a generic routine does. A parameter no argument
// mentions stays unbound, and the `new` stays refused.

import { checkOnly } from "../helpers";

const PRELUDE = `
class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
class Bag<T> {
	items: T[] = [];
	constructor(items: T[] = []) { this.items = items; }
}
class Pair<K, V> {
	k: K;
	v: V;
	constructor(pairs: Array<[K, V]>) { this.k = pairs[0][0]; this.v = pairs[0][1]; }
}
class Two<A, B> {
	a: A;
	constructor(a: A) { this.a = a; }
}
`;

const NEEDS_ARGS = "requires explicit type arguments";

function refusals(body: string): number {
	let n = 0;
	for (const e of checkOnly(PRELUDE + body).errors) {
		if (e.indexOf(NEEDS_ARGS) >= 0) n += 1;
	}
	return n;
}

test "new-infers: an argument binds the type parameter it is written against" {
	const result = checkOnly(PRELUDE + "const a = new Box(5);\nconst b = new Box(\"s\");\nconst c = new Bag([1, 2]);\nconst d: int32 = a.v;\nconst e: string = b.v;\nconst f: int32[] = c.items;\n");
	assert result.errors.length == 0, result.errors.join("; ");
}

test "new-infers: a tuple literal under a tuple formal binds both parameters" {
	const result = checkOnly(PRELUDE + "const p = new Pair([[\"k\", 1]]);\nconst k: string = p.k;\nconst v: int32 = p.v;\n");
	assert result.errors.length == 0, result.errors.join("; ");
}

test "new-infers: nothing to infer from keeps the explicit type arguments required" {
	assert refusals("const a = new Bag();\n") == 1;
	assert refusals("const b = new Bag([]);\n") == 1;
	assert refusals("const c = new Two(1);\n") == 1;
}

test "new-infers: a context type or written type arguments still decide" {
	assert refusals("const a: Bag<int32> = new Bag();\nconst b = new Bag<string>();\n") == 0;
}
