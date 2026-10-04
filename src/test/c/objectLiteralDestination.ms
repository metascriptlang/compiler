// An object literal is built straight into the place it initializes: a declared local, or the
// caller's result slot on a return, with a nested literal in its field and a union literal in
// its variant. Only an assignment, whose literal may read the destination, still goes through a
// temporary. Runtime behaviour: corpus `objectLiteralIntoDestination`; SBF frame: guard
// `solanaObjectLiteralFrame`.

import { compileToC } from "../helpers";

test "a struct literal that initializes a local is built in the local" {
	const c = compileToC(`
struct Inner { a: int32; b: int32; }
struct Outer { inner: Inner; n: int32; }
function main(): void {
	const o: Outer = { inner: { a: 1, b: 2 }, n: 3 };
	console.log(o.inner.b + o.n);
}
`);
	assert c.ok;
	assert c.value.contains(".inner.a = 1;");
	assert c.value.contains(".n = 3;");
	assert !c.value.contains("_lit");
}

test "a returned struct literal is built in the result slot, a nested literal in its field" {
	const c = compileToC(`
struct Inner { a: int32; b: int32; }
struct Outer { inner: Inner; n: int32; }
function outer(a: int32, b: int32): Outer { return { inner: { a: a, b: b }, n: a + b }; }
function main(): void { console.log(outer(1, 2).n); }
`);
	assert c.ok;
	assert c.value.contains("(*__result).inner.a = a;");
	assert c.value.contains("(*__result).n = (a + b);");
	assert !c.value.contains("_lit");
}

test "a returned union literal is built in its variant of the result slot" {
	const c = compileToC(`
struct Pair { x: int32; y: int32; }
enum Fault { Poor }
function settle(p: Pair, ok: boolean): Result<Pair, Fault> {
	if (!ok) return Result.err(Fault.Poor);
	return Result.ok({ x: p.x, y: p.y });
}
function main(): void { const r = settle({ x: 1, y: 2 }, true); console.log(r.ok); }
`);
	assert c.ok;
	assert c.value.contains("(*__result)._tag = 0;");
	assert c.value.contains("(*__result).v0.value.x = ");
	assert c.value.contains("(*__result)._tag = 1;");
	assert !c.value.contains("_uw");
}

test "an assignment whose literal reads its destination keeps a temporary" {
	const c = compileToC(`
struct Pair { x: int32; y: int32; }
function main(): void {
	let p: Pair = { x: 1, y: 2 };
	p = { x: p.y, y: p.x };
	console.log(p.x);
}
`);
	assert c.ok;
	assert c.value.contains("_lit");
}
