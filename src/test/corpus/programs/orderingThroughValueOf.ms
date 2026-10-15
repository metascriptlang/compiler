// Parity program — `<` `<=` `>` `>=` between two references read each side
// through `valueOf`, as JavaScript does, and never by address: a class method,
// a class extension, an interface extension, a struct extension, a string
// `valueOf`, mixed kinds and a number, and a generic body instantiated with the
// class. Allocation order is the reverse of value order, so an address
// comparison prints the opposite.
//
// @stdout: method false true false|classExt false true|iface false true true|struct false true|text false true|mixed false true true|generic false true|left true false true|right true false false|both true false true false|classes false false true|ext true true false|utext true false true|kinds true false|field false true|usub true false true true|ustruct true false false true false|uenum false true false true true false true false
// @exit: 0

class M { c: int32; constructor(c: int32) { this.c = c; } valueOf(): int32 { return this.c; } }
class K { c: int32; constructor(c: int32) { this.c = c; } }
function valueOf(this k: K): int32 { return k.c; }
interface R { c: int32; }
function valueOf(this r: R): int32 { return r.c; }
struct S { c: int32 }
function valueOf(this s: S): int32 { return s.c; }
class N { s: string; constructor(s: string) { this.s = s; } valueOf(): string { return this.s; } }
class D extends M { constructor(c: int32) { super(c); } valueOf(): int32 { return this.c * 10; } }
class P { c: int32; constructor(c: int32) { this.c = c; } valueOf(): int32 { return this.c; } }
class H { u: M | int32; constructor(u: M | int32) { this.u = u; } }
enum E { A, B, C }

function lt<T>(a: T, b: T): boolean { return a < b; }
function left(a: M | int32, b: M): boolean { return a < b; }
function right(a: M, b: M | int32): boolean { return a < b; }
function both(a: M | int32, b: M | int32): boolean { return a < b; }
function classes(a: M | P, b: M | P): boolean { return a < b; }
function classesLe(a: M | P, b: M | P): boolean { return a <= b; }
function extLt(a: K | int32, b: int32): boolean { return a < b; }
function extGt(a: K | int32, b: int32): boolean { return a > b; }
function extGe(a: int32, b: K | int32): boolean { return a >= b; }
function textLt(a: N | string, b: string): boolean { return a < b; }
function textLe(a: N | string, b: string): boolean { return a <= b; }
function kinds(a: int32 | float64, b: int32): boolean { return a < b; }
function field(h: H, b: int32): boolean { return h.u < b; }
function usub(a: M | D | int32, b: int32): boolean { return a < b; }
function ustruct(a: S | int32, b: int32): boolean { return a < b; }
function ustructBoth(a: S | int32, b: S | int32): boolean { return a >= b; }
function enumLt(a: E | int32, b: int32): boolean { return a < b; }
function enumGe(a: int32, b: E | int32): boolean { return a >= b; }
function enumFloat(a: E | float64, b: E): boolean { return a <= b; }
function enumBoth(a: E | int32, b: E | int32): boolean { return a < b; }

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
const p1 = new P(4);

const rows: string[] = [
	`method ${m1 < m2} ${m2 < m1} ${m1 <= m2}`,
	`classExt ${k1 < k2} ${k2 < k1}`,
	`iface ${r1 < r2} ${r2 < r1} ${r1 >= r2}`,
	`struct ${s1 < s2} ${s2 < s1}`,
	`text ${n1 < n2} ${n2 < n1}`,
	`mixed ${k1 < s1} ${s1 < k1} ${k2 < 2}`,
	`generic ${lt(m1, m2)} ${lt(m2, m1)}`,
	`left ${left(3, m1)} ${left(m1, m2)} ${left(m2, m1)}`,
	`right ${right(m1, 7)} ${right(m1, m2)} ${right(m2, 0)}`,
	`both ${both(3, m1)} ${both(m1, 3)} ${both(m2, m1)} ${both(7, 1)}`,
	`classes ${classes(m1, p1)} ${classes(p1, m2)} ${classesLe(m2, p1)}`,
	`ext ${extLt(k2, 7)} ${extGt(k1, 3)} ${extGe(2, k1)}`,
	`utext ${textLt(n2, "b")} ${textLt("c", "b")} ${textLe(n1, "b")}`,
	`kinds ${kinds(3, 4)} ${kinds(4.5, 4)}`,
	`field ${field(new H(m1), 3)} ${field(new H(2), 3)}`,
	`usub ${usub(m2, 5)} ${usub(new D(1), 5)} ${usub(new D(1), 15)} ${usub(2, 5)}`,
	`ustruct ${ustruct(s1, 5)} ${ustruct(s1, 3)} ${ustruct(7, 5)} ${ustructBoth(s1, 3)} ${ustructBoth(2, s1)}`,
	`uenum ${enumLt(E.C, 1)} ${enumLt(0, 1)} ${enumGe(1, E.C)} ${enumGe(5, E.C)} ${enumFloat(1.5, E.C)} ${enumFloat(E.C, E.B)} ${enumBoth(E.A, 1)} ${enumBoth(2, E.A)}`,
];
console.log(rows.join("|"));
