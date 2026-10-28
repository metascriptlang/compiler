// @stdout: A int
// @stdout: B int 3
// @stdout: B both int 2
// @stdout: B both str y
// @stdout: A both
// @stdout: int 4
// @stdout: int 7
function label(x: int32 | string): string {
	if (typeof x == "string") return "str " + x;
	return "int " + x.toString();
}

class A {
	tag(x: int32): string { return "A int"; }
	both(x: int32 | string): string { return "A both"; }
	pick(n: int32): int32 | string { return n; }
}
class B extends A {
	tag(x: int32 | string): string { return "B " + label(x); }
	both(x: int32 | string): string { return "B both " + label(x); }
	pick(n: int32): int32 { return n + 1; }
}

const a: A = new A();
const b: A = new B();
console.log(a.tag(3));
console.log(b.tag(3));
console.log(b.both(2));
console.log(b.both("y"));
console.log(a.both("x"));
console.log(label(b.pick(3)));
console.log(label(a.pick(7)));
