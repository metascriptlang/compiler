// @stdout: kind=box,box,4 sub=pair 5,s

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<U> extends Box<U> { w: U; constructor(v: U, w: U) { super(v); this.w = w; } }

function kind(x: Box<string> | Box<number> | int32): string {
	if (x instanceof Box) { return "box"; }
	return (x + 1).toString();
}

function sub(x: Pair<int32> | string): string {
	if (x instanceof Box) { return "pair " + x.w.toString(); }
	return x;
}

console.log("kind=" + kind(new Box<string>("a")) + "," + kind(new Box<number>(1)) + "," + kind(3)
	+ " sub=" + sub(new Pair<int32>(4, 5)) + "," + sub("s"));
