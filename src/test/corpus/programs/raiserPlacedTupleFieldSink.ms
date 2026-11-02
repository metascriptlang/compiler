// @stdout: x w2 p1
// note: a tuple literal stored into a heap class's field moves its cell in and releases the cell it replaces, so nothing stays live at exit. Second axis: a tuple field with a default initializer, and a tuple of a struct and a string.
struct W { id: int32; name: string; }

class Box {
	inner: [string, string];
	constructor() { this.inner = ["p", "q"]; }
}

class Defaulted {
	inner: [string, string] = ["p1", "q1"];
}

class Holder {
	pair: [W, string];
	constructor() { this.pair = [{ id: 1, name: "w1" }, "s"]; }
}

function reassign(b: Box): void {
	b.inner = ["x", "y"];
}

function rewrite(h: Holder): void {
	h.pair = [{ id: 2, name: "w2" }, "t"];
}

const b = new Box();
reassign(b);
const d = new Defaulted();
const h = new Holder();
rewrite(h);
console.log(b.inner[0] + " " + h.pair[0].name + " " + d.inner[0]);
