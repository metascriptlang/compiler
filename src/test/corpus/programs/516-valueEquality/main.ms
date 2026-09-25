// @xfail(raiser): raiser runtime error: cannot compile node kind BigIntLiteral at comptime
// Parity program — `==` on value types compares field by field on every backend: a struct, a
// tuple, a struct nested in a struct, a generic struct instance, `!=`, and a struct declared
// in another module. Field kinds: string, bigint, array (by reference), primitive union,
// generic instance, tuple of struct.
//
// @stdout: struct=true,false tuple=true nested=true generic=true,false neq=true fields=true,false,false crossModule=true
// @exit: 0

import { Pt, Wrap } from "./lib/shapes";

struct P { x: int32; y: string; }

struct Q { p: P; w: float64; }

struct Box<E> { item: E; }

struct F { s: string; n: bigint; xs: int32[]; u: int32 | string; w: Wrap<Pt>; tp: [Pt, string]; }

function main(): void {
	const a: P = { x: 1, y: "a" };
	const b: P = { x: 1, y: "a" };
	const c: P = { x: 2, y: "a" };
	const t1: [int32, string] = [1, "a"];
	const t2: [int32, string] = [1, "a"];
	const q1: Q = { p: { x: 1, y: "a" }, w: 0.5 };
	const q2: Q = { p: { x: 1, y: "a" }, w: 0.5 };
	const b1: Box<int32> = { item: 3 };
	const b2: Box<int32> = { item: 3 };
	const b3: Box<int32> = { item: 4 };
	const xs: int32[] = [1];
	const f1: F = { s: "a", n: 10n, xs: xs, u: 3, w: { inner: { x: 1, y: 2 }, tag: "t" }, tp: [{ x: 5, y: 6 }, "q"] };
	const f2: F = { s: "a", n: 10n, xs: xs, u: 3, w: { inner: { x: 1, y: 2 }, tag: "t" }, tp: [{ x: 5, y: 6 }, "q"] };
	const f3: F = { s: "a", n: 10n, xs: [1], u: 3, w: { inner: { x: 1, y: 2 }, tag: "t" }, tp: [{ x: 5, y: 6 }, "q"] };
	const f4: F = { s: "a", n: 10n, xs: xs, u: "3", w: { inner: { x: 1, y: 9 }, tag: "t" }, tp: [{ x: 5, y: 6 }, "q"] };
	const p1: Pt = { x: 1, y: 1 };
	const p2: Pt = { x: 1, y: 1 };
	console.log(`struct=${a == b},${a == c} tuple=${t1 == t2} nested=${q1 == q2} generic=${b1 == b2},${b1 == b3} neq=${a != c} fields=${f1 == f2},${f1 == f3},${f1 == f4} crossModule=${p1 == p2}`);
}

main();
