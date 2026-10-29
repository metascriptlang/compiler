// Parity program — two values of one union are equal when both hold the same member and those
// members are equal by that member's own equality: a struct by its fields, a tuple by its
// elements, a declared `==` through itself, a nullable union through its payload. A member of
// the union compares with the union it joins, either side, for == != === !==. Two different
// unions compare the members they share, a number with a number of another width. Each operand
// is read once, on every backend.
//
// @stdout: structs=true,false,false,false|true,false,true,false
// @stdout: member=true,true,false,false,true,true,false
// @stdout: tuple=true,false,true,false
// @stdout: declared=true,false,true,true
// @stdout: fixed=true,false,true
// @stdout: enum=true,false,true,false
// @stdout: field=true,false,true,true
// @stdout: generic=true,true,false
// @stdout: nullable=true,false,true,false,true,true
// @stdout: differ=true,false,false,false,true,false|true,false,false,true
// @stdout: differNullable=true,false,true,false,true
// @stdout: once=true calls=2
// @exit: 0

enum Color { Red, Blue }
struct P { x: int32 }
struct Q { w: int32 }
struct Pt { x: int32, y: int32 }
struct Named { name: string }
struct Box { p: Pt | int32, n: int32 }

export function `==`(this a: Named, b: Named): boolean { return a.name.length == b.name.length; }

function pq(k: int32, v: int32): P | Q { return k == 0 ? { x: v } : { w: v }; }
function pi(k: int32, v: int32): P | int32 { return k == 0 ? { x: v } : v; }
function named(k: int32, s: string): Named | int32 { return k == 0 ? { name: s } : k; }
function tuple(k: int32, v: int32): [int32, string] | int32 {
	const t: [int32, string] = [v, "t"];
	return k == 0 ? t : v;
}
function fixed(k: int32, v: int32): Pt[2] | string { return k == 0 ? [{ x: v, y: 1 }, { x: 2, y: 2 }] : "s"; }
function color(k: int32): Color | Pt { return k == 0 ? Color.Red : k == 1 ? Color.Blue : { x: 1, y: 2 }; }
function box(k: int32, v: int32): Box { return { p: k == 0 ? { x: v, y: 1 } : 3, n: k }; }
function same<T>(a: T, b: T): boolean { return a == b; }
function pick(k: int32): Pt | int32 { return k == 0 ? { x: 1, y: 2 } : 3; }
function nul(k: int32): Pt | int32 | null { return k == 0 ? { x: 1, y: 2 } : k == 1 ? 3 : null; }

const p1: P = { x: 1 };
console.log(`structs=${pq(0, 1) == pq(0, 1)},${pq(0, 1) == pq(0, 2)},${pq(0, 1) == pq(1, 1)},${pq(1, 1) != pq(1, 1)}|${pi(0, 1) == pi(0, 1)},${pi(0, 1) == pi(1, 1)},${pi(1, 7) == pi(1, 7)},${pi(1, 7) == pi(1, 8)}`);
console.log(`member=${pi(0, 1) == p1},${p1 == pi(0, 1)},${pi(0, 2) == p1},${pi(1, 1) == p1},${pi(1, 7) == 7},${7 == pi(1, 7)},${pi(0, 7) == 7}`);
console.log(`tuple=${tuple(0, 1) == tuple(0, 1)},${tuple(0, 1) == tuple(0, 2)},${tuple(1, 5) == tuple(1, 5)},${tuple(0, 1) == tuple(1, 1)}`);
console.log(`declared=${named(0, "ab") == named(0, "cd")},${named(0, "ab") == named(0, "c")},${named(1, "") == named(1, "")},${named(0, "ab") != named(1, "")}`);
console.log(`fixed=${fixed(0, 1) == fixed(0, 1)},${fixed(0, 1) == fixed(0, 2)},${fixed(1, 5) == fixed(1, 5)}`);
console.log(`enum=${color(0) == color(0)},${color(0) == color(1)},${color(2) == color(2)},${color(0) == color(2)}`);
console.log(`field=${box(0, 1) == box(0, 1)},${box(0, 1) == box(0, 2)},${box(1, 1) == box(1, 1)},${box(1, 1) != box(0, 1)}`);
console.log(`generic=${same<Pt | int32>(pick(0), pick(0))},${same<Pt | int32>(pick(1), pick(1))},${same<Pt | int32>(pick(0), pick(1))}`);
console.log(`nullable=${nul(0) == nul(0)},${nul(0) == nul(1)},${nul(2) == nul(2)},${nul(0) == nul(2)},${nul(1) == 3},${nul(2) == null}`);

function iu(k: int32): int32 | string { return k == 0 ? 1 : "x"; }
function ib(k: int32): int32 | boolean { return k == 0 ? 1 : true; }
function fb(k: int32): float64 | boolean { return k == 0 ? 1 : true; }
function ps(k: int32, v: int32): P | string { return k == 0 ? { x: v } : "s"; }
console.log(`differ=${iu(0) == ib(0)},${iu(1) == ib(0)},${iu(0) === ib(1)},${iu(0) != ib(0)},${iu(0) == fb(0)},${iu(1) == fb(1)}|${pi(0, 1) == ps(0, 1)},${pi(0, 1) == ps(0, 2)},${pi(1, 1) == ps(1, 1)},${pi(0, 1) != ps(1, 1)}`);
function nus(k: int32): Pt | string | null { return k == 0 ? { x: 1, y: 2 } : k == 1 ? "s" : null; }
console.log(`differNullable=${nul(0) == nus(0)},${nul(1) == nus(1)},${nul(2) == nus(2)},${nul(0) == nus(2)},${nul(2) != nus(1)}`);

let calls = 0;
function once(k: int32): Pt | int32 { calls += 1; return k == 0 ? { x: 1, y: 1 } : k; }
const r = once(0) == once(0);
console.log(`once=${r} calls=${calls}`);
