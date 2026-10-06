// @stdout: 0 1 0 1 1 0 | 2 2
// note: a class whose constructor assigns its reference fields on every path (both branches, before a throw, through a generic field) reads them as assigned, beside a field with an initializer. Same output on C, JS and the Raiser.
class Node2 { v: int32 = 1; }

class Ok<T> {
	items: T[];
	both: int32[];
	thrown: int32[];
	inner: Node2;
	f: () => int32;
	init: int32[] = [];
	constructor(c: boolean) {
		this.items = [];
		if (c) { this.both = [1]; } else { this.both = []; }
		if (!c) throw new Error("x");
		this.thrown = [];
		this.inner = new Node2();
		this.f = (): int32 => 1;
	}
}

const o = new Ok<int32>(true);
console.log(`${o.items.length} ${o.both.length} ${o.thrown.length} ${o.inner.v} ${o.f()} ${o.init.length} | ${(() => { o.items.push(4); o.items.push(5); return o.items.length; })()} ${o.items[0] - o.items[1] + 3}`);
