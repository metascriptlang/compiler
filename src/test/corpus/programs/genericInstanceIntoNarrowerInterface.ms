// @stdout: 1 4
// @stdout: 4 2 42 13
// @stdout: 7 8
// note: an instance of a generic interface or class passes where a plain interface whose fields
// lead its layout is expected, and the narrow view reads the instance's own fields.
interface Wide<P> { x: int32; make: (n: int32) => P; }
interface Tagged<P> { x: int32; tag: P; }
interface Pair<P> { x: int32; y: int32; tag: P; }
interface Narrow { x: int32; }
interface Point { x: int32; y: int32; }

class Box<P> {
	x: int32;
	tag: P;
	constructor(x: int32, tag: P) { this.x = x; this.tag = tag; }
}

function read(n: Narrow): int32 { return n.x; }
function sum(p: Point): int32 { return p.x * 10 + p.y; }

const w: Wide<string> = { x: 1, make: (n: int32): string => "s" };
const n: Narrow = w;
const t: Tagged<string> = { x: 4, tag: "t" };
console.log(n.x.toString() + " " + read(t).toString());

const p: Pair<string> = { x: 4, y: 2, tag: "t" };
const pt: Point = p;
const ps: Pair<int32>[] = [{ x: 1, y: 3, tag: 9 }];
console.log(pt.x.toString() + " " + pt.y.toString() + " " + sum(p).toString() + " " + sum(ps[0]).toString());

const b = new Box<string>(7, "t");
const c = new Box<int32>(8, 0);
console.log(read(b).toString() + " " + read(c).toString());
