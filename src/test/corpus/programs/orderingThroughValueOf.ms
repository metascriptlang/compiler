// Parity program — `<` `<=` `>` `>=` between two references read each side
// through `valueOf`, as JavaScript does, and never by address: a class method,
// a class extension, an interface extension, a struct extension, a string
// `valueOf`, mixed kinds and a number, and a generic body instantiated with the
// class. Allocation order is the reverse of value order, so an address
// comparison prints the opposite.
//
// @stdout: method false true false|classExt false true|iface false true true|struct false true|text false true|mixed false true true|generic false true
// @exit: 0

class M { c: int32; constructor(c: int32) { this.c = c; } valueOf(): int32 { return this.c; } }
class K { c: int32; constructor(c: int32) { this.c = c; } }
function valueOf(this k: K): int32 { return k.c; }
interface R { c: int32; }
function valueOf(this r: R): int32 { return r.c; }
struct S { c: int32 }
function valueOf(this s: S): int32 { return s.c; }
class N { s: string; constructor(s: string) { this.s = s; } valueOf(): string { return this.s; } }

function lt<T>(a: T, b: T): boolean { return a < b; }

const m1 = new M(5);
const m2 = new M(1);
const k1 = new K(5);
const k2 = new K(1);
const r1: R = { c: 5 };
const r2: R = { c: 1 };
const s1: S = { c: 3 };
const s2: S = { c: 1 };
const n1 = new N("b");
const n2 = new N("a");

const rows: string[] = [
	`method ${m1 < m2} ${m2 < m1} ${m1 <= m2}`,
	`classExt ${k1 < k2} ${k2 < k1}`,
	`iface ${r1 < r2} ${r2 < r1} ${r1 >= r2}`,
	`struct ${s1 < s2} ${s2 < s1}`,
	`text ${n1 < n2} ${n2 < n1}`,
	`mixed ${k1 < s1} ${s1 < k1} ${k2 < 2}`,
	`generic ${lt(m1, m2)} ${lt(m2, m1)}`,
];
console.log(rows.join("|"));
