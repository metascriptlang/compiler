// @stdout: t7:1,t7:in,t7:true,t7:false 5.. w. 4|q|4 true|q|true 33zz a2
// note: a generic function declared inside a body is instantiated per call beside its declaration:
// it captures, recurses, shadows an outer type parameter, and works in a method and a nested block.
function capture(base: int32): string {
	const tag = "t" + String(base);
	function wrap<T>(y: T): string { return `${tag}:${y}`; }
	let out = wrap(1);
	if (base > 0) {
		out = out + "," + wrap("in");
	}
	for (const k of [true, false]) out = out + "," + wrap(k);
	return out;
}

function countDown<T>(v: T, n: int32): string {
	function again<U>(u: U, k: int32): string { return k == 0 ? `${u}` : again(u, k - 1) + "."; }
	return again(v, n);
}

function shadow<T>(x: T): string {
	function inner<T>(y: T): string { return `${y}`; }
	return `${x}|${inner("q")}|${inner(x)}`;
}

class Holder {
	n: int32 = 3;
	show(): string {
		function twice<T>(v: T): string { return `${v}${v}`; }
		return twice(this.n) + twice("z");
	}
}

function nested(): string {
	let s = "";
	{
		function id<T>(v: T): T { return v; }
		s = id("a") + String(id(2));
	}
	return s;
}

console.log(capture(7), countDown(5, 2), countDown("w", 1), shadow<int32>(4), shadow<boolean>(true), new Holder().show(), nested());
