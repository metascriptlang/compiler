// @stdout: generic true false true false true true true unknown true anon 4,6 -96
// note: an operator over a generic parameter calls, in each instance, the routine declared for that instance's operand type, or the built-in operator when none is; an `unknown` operand, written or a generic instance's, compares as itself even where a routine is declared for some class; a routine declared for a tuple or an object type is called. Same output on every backend.

class D {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

function `==`(a: D, b: D): boolean { return a.n != b.n; }
function `<`(a: D, b: D): boolean { return a.n > b.n; }
function `+`(a: [int32, int32], b: [int32, int32]): [int32, int32] { return [a[0] + b[0], a[1] + b[1]]; }
function `-`(a: { x: int32 }, b: { x: int32 }): int32 { return a.x - b.x - 100; }

function eq<T>(a: T, b: T): boolean { return a == b; }
function lt<T>(a: T, b: T): boolean { return a < b; }

const d = new D(1);
const u: unknown = d as unknown;
const t1: [int32, int32] = [1, 2];
const t2: [int32, int32] = [3, 4];
const sum = t1 + t2;
const p1: { x: int32 } = { x: 5 };
const p2: { x: int32 } = { x: 1 };
console.log(`generic ${eq(1, 1)} ${eq("a", "b")} ${eq(new D(1), new D(2))} ${eq(d, d)} ${eq(u, u)} ${lt(1, 2)} ${lt(new D(2), new D(1))} unknown ${u == u} anon ${sum[0]},${sum[1]} ${p1 - p2}`);
