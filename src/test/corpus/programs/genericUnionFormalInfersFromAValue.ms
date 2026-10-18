// @stdout: 5 3 7 q 4 3 1 1 false
// note: a value passed into a union formal infers the union's one bare type parameter (`T | null` from a number, a struct, a tuple, a string, a class, an array; `T | T[]` from an element or an array), and a value that is already a member binds nothing. Same output on every backend.

struct Cell { a: int32; s: string; }
class K {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

function g<T>(a: T | null): T | null { return a; }
function flat<T>(a: T | T[]): int32 { return 1; }
function pick<T>(a: T | string, b: T): T { return b; }

const n: int32 = 5;
const lit: Cell = { a: 3, s: "z" };
const tp: [int32, string] = [7, "t"];
const s: string = "q";
const xs: int32[] = [1, 2, 3];
const zn = g(n);
const zc = g(lit);
const zt = g(tp);
const zs = g(s);
const zk = g(new K(4));
const za = g(xs);
console.log(`${zn != null ? String(zn) : "-"} ${zc != null ? String(zc.a) : "-"} ${zt != null ? String(zt[0]) : "-"} ${zs != null ? zs : "-"} ${zk != null ? String(zk.n) : "-"} ${za != null ? String(za.length) : "-"} ${flat(xs)} ${flat(n)} ${pick("s", false)}`);
