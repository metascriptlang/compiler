// @stdout: local 102 3000 false true false text false outer 3 -3 true false true true
// note: an operator calls the routine declared in the scope it is written in, the way a call does: a function's own `+`, unary `-`, `==` (and `===` through it), `<`, the `+` of a `+=` and a `==` between text and a `V` shadow the module's, which the code outside keeps calling.

class V {
	x: int32;
	constructor(x: int32) { this.x = x; }
}

function `+`(a: V, b: V): V { return new V(a.x + b.x); }
function `-`(a: V): V { return new V(0 - a.x); }
function `==`(a: V, b: V): boolean { return a.x == b.x; }
function `<`(a: V, b: V): boolean { return a.x < b.x; }
function `==`(a: string, b: V): boolean { return a.length == b.x; }

function local(): string {
	function `+`(a: V, b: V): V { return new V(a.x * 100 + b.x); }
	function `-`(a: V): V { return new V(a.x * 1000); }
	function `==`(a: V, b: V): boolean { return a.x != b.x; }
	function `<`(a: V, b: V): boolean { return a.x > b.x; }
	let s = new V(1);
	s += new V(2);
	const n = -new V(3);
	return `${s.x} ${n.x} ${new V(1) == new V(1)} ${new V(1) === new V(2)} ${new V(1) < new V(2)}`;
}

function localText(): boolean {
	function `==`(a: string, b: V): boolean { return a.length != b.x; }
	return "a" == new V(1);
}

function outer(): string {
	let s = new V(1);
	s += new V(2);
	const n = -new V(3);
	return `${s.x} ${n.x} ${new V(1) == new V(1)} ${new V(1) === new V(2)} ${new V(1) < new V(2)} ${"a" == new V(1)}`;
}

console.log(`local ${local()} text ${localText()} outer ${outer()}`);
