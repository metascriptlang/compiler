// @stdout: pair=1 triple=3 base=6 fixed=s words=a member=box,int

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<U> extends Box<U> { w: U; constructor(v: U, w: U) { super(v); this.w = w; } }
class Triple<U> extends Pair<U> { z: U; constructor(v: U, w: U, z: U) { super(v, w); this.z = z; } }
class Fixed<U> extends Box<string> { q: U; constructor(q: U) { super("s"); this.q = q; } }
class Words extends Box<string> { constructor(v: string) { super(v); } }
class Base { k: number = 4; }
class Sub<T> extends Base { v: T; constructor(v: T) { super(); this.v = v; } }
class Sub2<T> extends Sub<T> { constructor(v: T) { super(v); } }

function boxNumber(u: unknown): number { return (u as Box<number>).v; }
function boxString(u: unknown): string { return (u as Box<string>).v; }
function triple(u: unknown): number { return (u as Box<number>).v + (u as Pair<number>).w; }
function base(u: unknown): number { return (u as Base).k + (u as Sub<string>).v.length; }
function kind(x: Box<string> | Box<number> | int32): string { return x instanceof Box ? "box" : "int"; }

const held: Box<number> = new Pair<number>(1, 2);
console.log("pair=" + boxNumber(new Pair<number>(1, 2)).toString()
	+ " triple=" + triple(new Triple<number>(1, 2, 3)).toString()
	+ " base=" + base(new Sub2<string>("ab")).toString()
	+ " fixed=" + boxString(new Fixed<number>(5))
	+ " words=" + boxString(new Words("a"))
	+ " member=" + kind(held) + "," + kind(3));
