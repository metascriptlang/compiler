// @stdout: call /0/null/4 8 | new /null 5 | stmt 0 | element null 1
// note: an explicit move of a field or element empties it where the value is only read, as where it is handed on: an argument of a plain parameter, an argument of a constructor that keeps nothing, a statement of its own, an element passed to a plain parameter. The moved value is destroyed in the scope that moved it.
class Leaf { v: int32; constructor(v: int32) { this.v = v; } }
class H {
	s: string = "s" + String(1);
	kids: Vec<int32> = [1, 2];
	leaf: Leaf | null = new Leaf(3);
	n: int32 = 4;
}
class Reads {
	n: int32;
	constructor(s: string, l: Leaf | null) { this.n = s.length + (l == null ? 0 : l.v); }
}

function show(h: H): string {
	return `${h.s}/${h.kids.length}/${h.leaf == null ? "null" : "leaf"}/${h.n}`;
}
function borrow(s: string, k: Vec<int32>, l: Leaf | null, n: int32): int32 { return s.length + k.length + n; }

function call(): string {
	const h = new H();
	const r = borrow(move h.s, move h.kids, move h.leaf, move h.n);
	return "call " + show(h) + " " + r.toString();
}
function ctor(): string {
	const h = new H();
	const r = new Reads(move h.s, move h.leaf);
	return `new ${h.s}/${h.leaf == null ? "null" : "leaf"} ${r.n}`;
}
function stmt(): string {
	const h = new H();
	move h.kids;
	return `stmt ${h.kids.length}`;
}
function element(): string {
	let ls: (Leaf | null)[] = [new Leaf(1), new Leaf(2)];
	const n = borrow("", [], move ls[0], 1);
	return `element ${ls[0] == null ? "null" : "leaf"} ${n}`;
}

console.log(`${call()} | ${ctor()} | ${stmt()} | ${element()}`);
