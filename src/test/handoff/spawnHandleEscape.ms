import { compileToCWithStd } from "../helpers";

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
