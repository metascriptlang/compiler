// @stdout: 3 3 3 7 7 4
// @stdout: 1 2 2 2
// @stdout: 7

@passC("-Werror=incompatible-pointer-types");

class Base<T> {
	u: T;
	constructor(u: T) { this.u = u; }
	get(): T { return this.u; }
}

class Sub extends Base<int32> {
	constructor(u: int32) { super(u + 1); }
}

class Pair<U> extends Base<U> {
	tag: string;
	constructor(u: U, tag: string) { super(u); this.tag = tag; }
}

function read(b: Base<int32>): int32 { return b.get(); }
function make(): Base<int32> { return new Sub(2); }

interface Cell<T> { v: T }
class Node { v: number = 1; back: Cell<number> | null = null; }
class Holder { v: number = 2; held: Cell<number> | null = null; }

function peek(c: Cell<number>): number { return c.v; }
function cellOf(h: Holder): Cell<number> { return h; }

const s = new Sub(2);
const b: Base<int32> = s;
console.log(read(s), b.get(), make().get(), read(new Pair<int32>(7, "p")), s.get() + 4 == 7 ? 7 : 0, new Pair<int32>(4, "q").get());

const n = new Node();
const h = new Holder();
n.back = h;
h.held = n;
const c: Cell<number> = h;
console.log(peek(n), c.v, cellOf(h).v, peek(h));
console.log(s.get() + read(new Sub(3)));
