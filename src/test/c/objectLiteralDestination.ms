// An object literal is built straight into the place it initializes: a declared local, the
// caller's result slot on a return, or an assigned local, its field or its element, with a nested
// literal in its field and a union literal in its variant. An assignment whose literal may read the
// destination, or whose destination is not the frame's own, still goes through a temporary.
// Runtime behaviour: corpus `objectLiteralIntoDestination`, `objectLiteralAssignedInPlace`; SBF
// frame: guard `solanaObjectLiteralFrame`.

import { compileToC } from "../helpers";

function bodyOf(c: string, fn: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`void ${fn}__`) && line.endsWith("{")) {
			const open = c.indexOf(line);
			return c.slice(open, c.indexOf("\n}", open));
		}
	}
	return "";
}

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

test "an assigned literal is built in the local, its field and its element" {
	const c = compileToC(`
struct Pair { x: int64; y: int64; }
struct Box { p: Pair; arr: Pair[3]; n: int64; }
function main(): void {
	let b: Box = { p: { x: 0, y: 0 }, arr: [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }], n: 0 };
	let q: Pair = { x: 0, y: 0 };
	let i: int32 = 2;
	q = { x: 5, y: 10 };
	b.p = { x: q.y, y: q.x };
	b.arr[i] = { x: 6, y: q.x };
	console.log(b.p.x + b.arr[i].y);
}
`);
	assert c.ok;
	assert c.value.contains("q_1_.x = 5LL;");
	assert c.value.contains("b_1_.p.x = q_1_.y;");
	assert c.value.contains("b_1_.arr[i_1_].x = 6LL;");
}

test "an assigned literal read through a view of its destination keeps a temporary" {
	const c = compileToC(`
struct Pair { x: int64; y: int64; }
function main(): void {
	let arr: Pair[2] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
	const s: Span<Pair> = arr;
	arr[1] = { x: s[1].y, y: s[1].x };
	console.log(arr[1].x);
}
`);
	assert c.ok;
	assert c.value.contains("[1] = _lit");
	assert !c.value.contains("[1].x = s_1_");
}

test "an assigned literal whose destination is a module variable keeps a temporary" {
	const c = compileToC(`
struct Pair { x: int64; y: int64; }
let G: Pair = { x: 1, y: 2 };
function flip(q: Pair): void { G = { x: q.y, y: q.x }; }
function main(): void { flip(G); console.log(G.x); }
`);
	assert c.ok;
	assert bodyOf(c.value, "flip").contains(" = _lit");
}
