// A struct call assigned to a frame local, its field or its sized-array element gets that
// location as its result slot when no argument reaches it and no handler in the function can see
// a store the call leaves half done; a struct call result passed by address is passed as its own
// result slot, not copied into another temporary first.
// Runtime behaviour: corpus `callAssignedInPlace`.

import { compileToC } from "../helpers";

function bodyOf(c: string, fn: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(` ${fn}__`) && line.endsWith("{")) {
			const open = c.indexOf(line);
			return c.slice(open, c.indexOf("\n}", open));
		}
	}
	return "";
}

const QUAD = `
struct Quad { a: int64; b: int64; c: int64; d: int64; }
struct Box { q: Quad; arr: Quad[3]; n: int64; }
function quad(x: int64, y: int64): Quad { return { a: x, b: y, c: 0, d: 0 }; }
function swap(q: Quad): Quad { return { a: q.b, b: q.a, c: q.d, d: q.c }; }
function digits(q: Quad): int64 { return q.a * 10 + q.b; }
function checked(x: int64): Quad {
	if (x < 0) { throw new Error("negative"); }
	return { a: x, b: x, c: x, d: x };
}
`;

test "a struct call assigned to a local, a field or an element writes that location" {
	const c = compileToC(`${QUAD}
function plain(x: int64): int64 {
	const src = quad(x, 2);
	let q = quad(0, 0);
	q = swap(src);
	return digits(q);
}
function target(i: int32, x: int64): int64 {
	let b: Box = { q: quad(0, 0), arr: [quad(0, 0), quad(0, 0), quad(0, 0)], n: 7 };
	b.q = quad(x, 1);
	b.arr[i] = checked(x);
	return digits(b.q) + digits(b.arr[i]);
}
function main(): void { console.log(plain(3) + target(1, 4)); }
`);
	assert c.ok;
	const plain = bodyOf(c.value, "plain");
	assert plain.contains("(&q_1_, &(src_1_));");
	assert !plain.contains("q_1_ = T");
	const target = bodyOf(c.value, "target");
	assert target.contains("(&b_1_.q, x, 1LL);");
	assert target.contains("(&b_1_.arr[i], x);");
}

test "a struct call whose argument reads the destination keeps its temporary" {
	const c = compileToC(`${QUAD}
function again(): int64 {
	let q = quad(3, 1);
	q = swap(q);
	return digits(q);
}
function main(): void { console.log(again()); }
`);
	assert c.ok;
	assert bodyOf(c.value, "again").contains("(q_1_ = T");
}

test "a raising struct call assigned inside a try keeps its temporary" {
	const c = compileToC(`${QUAD}
function kept(n: int64): int64 {
	let q = quad(1, 1);
	try {
		q = checked(n);
	} catch (e) {
		return -1;
	}
	return q.a;
}
function main(): void { console.log(kept(2)); }
`);
	assert c.ok;
	assert bodyOf(c.value, "kept").contains("(q_1_ = T");
}

test "a struct call result passed by address is not copied first" {
	const c = compileToC(`${QUAD}
function receivers(): int64 { return digits(swap(quad(1, 2))) + digits(checked(0)); }
function main(): void { console.log(receivers()); }
`);
	assert c.ok;
	const body = bodyOf(c.value, "receivers");
	assert !body.contains("_clit");
	assert body.contains("digits_");
}
