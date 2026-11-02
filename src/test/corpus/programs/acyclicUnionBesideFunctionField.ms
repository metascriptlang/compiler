// @stdout: _self a 0 x=4 | t 3 3 e | n1 r
// note: a function field makes a class traced; an anonymous union field beside it is walked by that trace only when the union can reach a cycle. A literal-and-string union, a two-literal-and-number union and a string-or-struct union never can; a union holding a self-referencing class can, and stays walked.
struct P { x: int32; }

class Node {
	name: string;
	next: Node | null = null;
	constructor(name: string) { this.name = name; }
}

interface Attrs {
	target: "_self" | string;
	mode: "a" | "b" | number;
	extra: string | P;
	ref: (el: string) => void;
}

interface Linked {
	head: Node | int32;
	ref: (el: string) => void;
}

function describe(a: Attrs): string {
	const extra = typeof a.extra === "string" ? a.extra : `x=${a.extra.x}`;
	return `${a.target} ${a.mode} ${typeof a.mode === "number" ? a.mode : 0} ${extra}`;
}

let seen = "";
const attrs: Attrs = { target: "_self", mode: "a", extra: { x: 4 }, ref: (el: string): void => { seen = el; } };
const numbered: Attrs = { target: "t", mode: 3, extra: "e", ref: (el: string): void => { seen = el; } };
attrs.ref("r");
const n1 = new Node("n1");
n1.next = n1;
const linked: Linked = { head: n1, ref: (el: string): void => { seen = el; } };
const head = linked.head;
console.log(`${describe(attrs)} | ${describe(numbered)} | ${typeof head === "number" ? "-" : head.name} ${seen}`);
n1.next = null;
