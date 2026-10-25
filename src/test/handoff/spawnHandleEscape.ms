import { compileToCWithStd, compileToJSWithStd } from "../helpers";

const PRELUDE = `
class Node { v: int32 = 1; }
function leaf(n: Readonly<Node>): int32 { return n.v; }
let parkedAll: Promise<int32>[] = [];
function keep(a: Promise<int32>[]): void { parkedAll = a; }
class Box { hs: Promise<int32>[]; constructor(hs: Promise<int32>[]) { this.hs = hs; } }
`;
const JOINED = "would let the handle outlive that join";

function outcome(source: string): string {
	const result = compileToCWithStd(PRELUDE + source + "\n");
	return result.ok ? "compiled" : result.error;
}

function outcomeJs(source: string): string {
	const result = compileToJSWithStd(PRELUDE + source + "\n");
	return result.ok ? "compiled" : result.error;
}

const BOTH = "async function both(xs: Readonly<Promise<int32>[]>): Promise<int32> { return (await xs[0]) + (await xs[1]); }\n";
const HANDLES = "const a: int32[] = [1, 2]; const xs = [spawn(() => a[0]), spawn(() => a[1])];";

test "spawnHandleEscape: a borrowing handle carried out of its frame by any value that leaves is refused" {
	const cases = [
		{ name: "array literal returned", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32>[] { return [spawn(() => leaf(n))]; }" },
		{ name: "local array returned", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32>[] { const a = [spawn(() => leaf(n))]; return a; }" },
		{ name: "pushed local returned", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32>[] { const a: Promise<int32>[] = []; a.push(spawn(() => leaf(n))); return a; }" },
		{ name: "tuple returned", how: "returning it", source: "function f(n: Readonly<Node>): [Promise<int32>, int32] { return [spawn(() => leaf(n)), 1]; }" },
		{ name: "conditional over local arrays", how: "returning it", source: "function f(n: Readonly<Node>, b: boolean): Promise<int32>[] { const a = [spawn(() => leaf(n))]; const c = [spawn(() => leaf(n))]; return b ? a : c; }" },
		{ name: "spread", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32>[] { const a = [spawn(() => leaf(n))]; return [...a]; }" },
		{ name: "nested literal", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32>[][] { return [[spawn(() => leaf(n))]]; }" },
		{ name: "element read", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32> { const a = [spawn(() => leaf(n))]; return a[0]; }" },
		{ name: "destructured element", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32> { const [x] = [spawn(() => leaf(n))]; return x; }" },
		{ name: "local array stored in a global", how: "storing it in 'parkedAll'", source: "function f(n: Readonly<Node>): void { const a: Promise<int32>[] = [spawn(() => leaf(n))]; parkedAll = a; }" },
		{ name: "local array passed on", how: "passing it to 'keep'", source: "function f(n: Readonly<Node>): void { const a = [spawn(() => leaf(n))]; keep(a); }" },
		{ name: "array literal to a constructor", how: "passing it to a constructor", source: "function f(n: Readonly<Node>): Box { return new Box([spawn(() => leaf(n))]); }" },
		{ name: "pushed into a parameter's array through a local", how: "an array this scope did not create", source: "function f(out: Promise<int32>[], n: Readonly<Node>): void { const a = out; a.push(spawn(() => leaf(n))); }" },
		{ name: "element of a for..of", how: "passing it to 'parkedAll.push'", source: "function f(n: Readonly<Node>): void { const a = [spawn(() => leaf(n))]; for (const h of a) parkedAll.push(h); }" },
		{ name: "captured by a closure", how: "capturing it in a closure", source: "function f(n: Readonly<Node>): () => int32 { const a = [spawn(() => leaf(n))]; return (): int32 => a.length; }" },
		{ name: "combinator over local handles returned", how: "returning it", source: "function f(n: Readonly<Node>): Promise<int32[]> { const a = [spawn(() => leaf(n)), spawn(() => leaf(n))]; return Promise.all(a); }" },
		{ name: "expression arrow body", how: "returning it", source: "function f(n: Readonly<Node>): int32 { const mk = (): Promise<int32> => spawn(() => leaf(n)); return await mk(); }" },
		{ name: "expression arrow body array", how: "returning it", source: "function f(n: Readonly<Node>): int32 { const mk = (): Promise<int32>[] => [spawn(() => leaf(n))]; const hs = mk(); return await hs[0]; }" },
		{ name: "yielded", how: "yielding it", source: "function* f(n: Readonly<Node>): Iterator<Promise<int32>> { yield spawn(() => leaf(n)); }" },
	];
	for (const c of cases) {
		const got = outcome(c.source);
		assert got.contains(JOINED) && got.contains(c.how), c.name + ": " + got;
	}
}

test "spawnHandleEscape: a borrowing handle awaited, joined or held in a frame-local array compiles, and an isolated one may leave" {
	const cases = [
		{ name: "awaited in place", source: "function f(n: Readonly<Node>): int32 { const h = spawn(() => leaf(n)); return await spawn(() => leaf(n)) + await h; }" },
		{ name: "Promise.all over a local array", source: "function f(n: Readonly<Node>): int32 { const a = [spawn(() => leaf(n)), spawn(() => leaf(n))]; const r = await Promise.all(a); return r[0] + r[1]; }" },
		{ name: "loop push then await each", source: "function f(n: Readonly<Node>): int32 { const a: Promise<int32>[] = []; for (let i = 0; i < 3; i++) a.push(spawn(() => leaf(n))); let t: int32 = 0; for (const h of a) t += await h; return t; }" },
		{ name: "elements awaited by index", source: "function f(n: Readonly<Node>): int32 { const bs = [spawn(() => leaf(n) * 2), spawn(() => leaf(n) * 3)]; return await bs[0] + await bs[1]; }" },
		{ name: "length read", source: "function f(n: Readonly<Node>): int32 { const a = [spawn(() => leaf(n))]; const k = a.length; let t: int32 = 0; for (const h of a) t += await h; return t + k; }" },
		{ name: "isolated spawn returned in an array", source: "function f(v: int32): Promise<int32>[] { return [spawn((): int32 => v * 2)]; }" },
	];
	for (const c of cases) {
		const got = outcome(c.source);
		assert got == "compiled", c.name + ": " + got;
	}
}

test "spawnHandleEscape: a borrowing handle lent to a Readonly parameter that only reads it compiles" {
	const cases = [
		{ name: "awaited in the callee", source: BOTH + "async function f(): Promise<int32> { " + HANDLES + " return await both(xs); }" },
		{ name: "length read", source: "function count(xs: Readonly<Promise<int32>[]>): int32 { return xs.length; }\nasync function f(): Promise<int32> { " + HANDLES + " const n = count(xs); return (await xs[0]) + n; }" },
		{ name: "forwarded to a second Readonly helper", source: BOTH + "async function mid(xs: Readonly<Promise<int32>[]>): Promise<int32> { return await both(xs); }\nasync function f(): Promise<int32> { " + HANDLES + " return await mid(xs); }" },
		{ name: "method", source: "class H { async both(xs: Readonly<Promise<int32>[]>): Promise<int32> { return (await xs[0]) + (await xs[1]); } }\nasync function f(): Promise<int32> { " + HANDLES + " return await new H().both(xs); }" },
		{ name: "const alias read", source: "async function mid(xs: Readonly<Promise<int32>[]>): Promise<int32> { const h = xs[0]; const h2 = h; return await h2; }\nasync function f(): Promise<int32> { " + HANDLES + " return await mid(xs); }" },
		{ name: "destructured read", source: "async function mid(xs: Readonly<Promise<int32>[]>): Promise<int32> { const [h, k] = xs; return (await h) + (await k); }\nasync function f(): Promise<int32> { " + HANDLES + " return await mid(xs); }" },
		{ name: "for-of read", source: "async function mid(xs: Readonly<Promise<int32>[]>): Promise<int32> { let t: int32 = 0; for (const h of xs) t += await h; return t; }\nasync function f(): Promise<int32> { " + HANDLES + " return await mid(xs); }" },
	];
	for (const c of cases) {
		const got = outcome(c.source);
		assert got == "compiled", c.name + ": " + got;
		const js = outcomeJs(c.source);
		assert js == "compiled", c.name + " (js): " + js;
	}
}

test "spawnHandleEscape: a borrowing handle lent to a callee that keeps it or cannot be checked is refused" {
	const cases = [
		{ name: "global store", how: "storing it in 'parkedAll'", source: "function keepOne(xs: Readonly<Promise<int32>[]>): void { parkedAll = [xs[0]]; }\nasync function f(): Promise<int32> { " + HANDLES + " keepOne(xs); return await xs[0]; }" },
		{ name: "element pushed into a global", how: "passing it to 'parkedAll.push'", source: "function pushOne(xs: Readonly<Promise<int32>[]>): void { parkedAll.push(xs[0]); }\nasync function f(): Promise<int32> { " + HANDLES + " pushOne(xs); return await xs[0]; }" },
		{ name: "returned", how: "returning it", source: "function first(xs: Readonly<Promise<int32>[]>): Promise<int32> { return xs[0]; }\nasync function f(): Promise<int32> { " + HANDLES + " const h = first(xs); return await h; }" },
		{ name: "closure capture", how: "capturing it in a closure", source: "function cap(xs: Readonly<Promise<int32>[]>): () => int32 { return (): int32 => xs.length; }\nasync function f(): Promise<int32> { " + HANDLES + " const g = cap(xs); return g() + (await xs[0]); }" },
		{ name: "forwarded to a plain parameter", how: "is not Readonly<...>", source: "function plain(xs: Promise<int32>[]): int32 { return xs.length; }\nfunction mid(xs: Readonly<Promise<int32>[]>): int32 { return plain(xs); }\nasync function f(): Promise<int32> { " + HANDLES + " return mid(xs) + (await xs[0]); }" },
		{ name: "plain parameter", how: "is not Readonly<...>", source: "function plain(xs: Promise<int32>[]): int32 { return xs.length; }\nasync function f(): Promise<int32> { " + HANDLES + " return plain(xs) + (await xs[0]); }" },
		{ name: "async call not awaited in place", how: "not awaited in place", source: BOTH + "async function f(): Promise<int32> { " + HANDLES + " const r = both(xs); return await r; }" },
		{ name: "bodiless callee", how: "has no body to check", source: "extern function ext(xs: Readonly<Promise<int32>[]>): int32 from \"msExt\";\nasync function f(): Promise<int32> { " + HANDLES + " return ext(xs) + (await xs[0]); }" },
		{ name: "const alias escapes", how: "passing it to 'parkedAll.push'", source: "function mid(xs: Readonly<Promise<int32>[]>): void { const h = xs[0]; const h2 = h; parkedAll.push(h2); }\nasync function f(): Promise<int32> { " + HANDLES + " mid(xs); return await xs[0]; }" },
		{ name: "destructured escapes", how: "passing it to 'parkedAll.push'", source: "function mid(xs: Readonly<Promise<int32>[]>): void { const [h] = xs; parkedAll.push(h); }\nasync function f(): Promise<int32> { " + HANDLES + " mid(xs); return await xs[0]; }" },
		{ name: "for-of escapes", how: "passing it to 'parkedAll.push'", source: "function mid(xs: Readonly<Promise<int32>[]>): void { for (const h of xs) parkedAll.push(h); }\nasync function f(): Promise<int32> { " + HANDLES + " mid(xs); return await xs[0]; }" },
	];
	for (const c of cases) {
		const got = outcome(c.source);
		assert got.contains(JOINED) && got.contains(c.how), c.name + ": " + got;
		const js = outcomeJs(c.source);
		assert js.contains(JOINED) && js.contains(c.how), c.name + " (js): " + js;
	}
}
