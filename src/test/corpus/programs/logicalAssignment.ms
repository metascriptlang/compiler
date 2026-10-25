// @stdout: 7 101
// @stdout: 7 102
// @stdout: 7 203
// @stdout: 2 204
// @stdout: 11 1 2
// @stdout: first 2
// @stdout: 5 0 0
// @stdout: 7 3 4 9 4 2
// @stdout: 1 2 0 0
// @stdout: 50 50 50 3
// @stdout: 1 1 9
// @stdout: 1 3
// Logical assignment keeps its TS meaning on C and JS: the place (object and index
// included) is evaluated once, read once, the right side runs only when the test
// passes, and the expression's value is the place afterwards.

let calls = 0;
class Box { x: int32 | null = null; y: int32 = 0; s: string | null = null; }
const box = new Box();
function get(): Box { calls = calls + 1; return box; }
function f(): int32 { calls = calls + 100; return 7; }

let a: int32 | null = null;
a ??= 3;
console.log(a);
a ??= 9;
console.log(a);

let o: int32 = 0;
o ||= 5;
console.log(o);
o ||= 8;
console.log(o);

let n: int32 = 4;
n &&= 6;
console.log(n);
let z: int32 = 0;
z &&= 6;
console.log(z);

get().x ??= f();
console.log(box.x, calls);
get().x ??= f();
console.log(box.x, calls);

get().y ||= f();
console.log(box.y, calls);
get().y &&= 2;
console.log(box.y, calls);

const arr: int32[] = [0, 1];
let k = 0;
function idx(): int32 { k = k + 1; return 0; }
arr[idx()] ||= 11;
arr[idx()] ||= 22;
console.log(arr[0], arr[1], k);

// A nested field: the object chain a.b is reached once.
class Inner { c: string | null = null; }
class Outer { b: Inner = new Inner(); }
let hops = 0;
const outer = new Outer();
function reach(): Outer { hops = hops + 1; return outer; }
reach().b.c ??= "first";
reach().b.c ??= "second";
console.log(outer.b.c, hops);

// The object of a nested field is the one reached before the right side runs, even when
// that right side points the path elsewhere.
class Hop { c: int32 = 0; }
class Ring { b: Hop = new Hop(); }
const ring = new Ring();
const spare = new Hop();
const reached = ring.b;
function moveAway(): int32 { ring.b = spare; return 5; }
ring.b.c ||= moveAway();
console.log(reached.c, spare.c, ring.b.c);

// A field and an element of a value struct are written in place, not in a copy.
struct Pt { x: int32; y: int32 }
class Cell { pt: Pt = { x: 0, y: 3 }; pts: Pt[] = [{ x: 0, y: 1 }]; }
const cell = new Cell();
let cellCalls = 0;
let pointCalls = 0;
function cellOf(): Cell { cellCalls = cellCalls + 1; return cell; }
function first0(): int32 { pointCalls = pointCalls + 1; return 0; }
cellOf().pt.x ||= 7;
cellOf().pt.y ||= 8;
cellOf().pts[first0()].x ||= 4;
cellOf().pts[first0()].y &&= 9;
console.log(cell.pt.x, cell.pt.y, cell.pts[0].x, cell.pts[0].y, cellCalls, pointCalls);

// Each type: string | null, boolean.
let s: string | null = null;
s ??= "set";
s ??= "again";
console.log(s);
let flag = false;
flag ||= true;
console.log(flag);
flag &&= false;
console.log(flag);

// The right side must not run when the test fails.
let ran = 0;
function rhs(): int32 { ran = ran + 1; return 50; }
let kept: int32 | null = 1;
kept ??= rhs();
let truthy: int32 = 2;
truthy ||= rhs();
let falsy: int32 = 0;
falsy &&= rhs();
console.log(kept, truthy, falsy, ran);
kept = null;
kept ??= rhs();
falsy ||= rhs();
truthy &&= rhs();
console.log(kept, falsy, truthy, ran);

// Afterwards a reference place holds no null: it reads as the class without a check.
class Item { n: int32 = 1; }
function lazy(given: Item | null): int32 {
	let held: Item | null = given;
	held ??= new Item();
	return held.n;
}
let zero: int32 = 0;
zero ||= 9;
console.log(lazy(null), lazy(new Item()), zero);

// A struct stored by a logical assignment is a copy, as with `=`.
let source: Pt = { x: 1, y: 0 };
let slot: Pt | null = null;
slot ??= source;
if (slot != null) slot.x = 5;
let other: Pt = { x: 3, y: 0 };
let full: Pt | null = { x: 4, y: 0 };
full &&= other;
if (full != null) full.x = 8;
console.log(source.x, other.x);
