// @stdout: a1 b1 | x9 y8 | n7 n7
// note: a tuple holding a heap value is copied and destroyed through its lifted hooks on the Raiser, where a tuple is an array: the copy is independent of its source and nothing stays live at exit. Second axis: the tuple is a field of a heap class and a nested tuple.
struct W { id: int32; name: string; }

function pair(i: int32): [W, string] {
	return [{ id: i, name: "a" + i.toString() }, "b" + i.toString()];
}

class Box {
	inner: [[W, string], string];
	constructor(w: [W, string]) { this.inner = [w, "t"]; }
}

function copies(): string {
	const p = pair(1);
	let q = p;
	q[1] = "x9";
	q[0].name = "y8";
	return p[0].name + " " + p[1] + " | " + q[1] + " " + q[0].name;
}

function boxed(): string {
	const b = new Box(pair(7));
	const c = new Box(b.inner[0]);
	c.inner[0][0].name = "n7";
	return "n" + b.inner[0][0].id.toString() + " " + c.inner[0][0].name;
}

console.log(copies() + " | " + boxed());
