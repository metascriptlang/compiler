// @stdout: s:x n:7 s:y n:8 s:z n:9
// @stdout: 10 13 1
// @stdout: s:x0 s:y2 s:z3
// @stdout: s:x0 s:y2
// A super call forwards a union or a large struct to the base constructor the way any call
// passes them, from a written constructor and from one a derived class inherits, and a derived
// class answers to the base's constructor signatures.
class Base {
	v: string;
	constructor(value: string | int32) { this.v = typeof value == "string" ? "s:" + value : "n:" + value.toString(); }
}
class Written extends Base {
	constructor(value: string | int32) { super(value); }
}
class Implicit extends Base {}
class Grand extends Implicit {}
console.log(new Written("x").v, new Written(7).v, new Implicit("y").v, new Implicit(8).v, new Grand("z").v, new Grand(9).v);

struct Big { a: int64; b: int64; c: int64; d: int64; e: string; }
class Sum {
	total: int64;
	constructor(big: Big, scale: int64) { this.total = big.a * scale + big.b + big.c + big.d; }
}
class Scaled extends Sum {
	constructor(big: Big) { super(big, 1); }
}
class Plain extends Sum {}
const big: Big = { a: 1, b: 2, c: 3, d: 4, e: "k" };
console.log(new Scaled(big).total, new Plain({ a: 1, b: 2, c: 3, d: 4, e: "k" }, 4).total, big.a);

class Labeled {
	v: string;
	constructor(value: string);
	constructor(value: string, n: int32);
	constructor(value: string | int32, n: int32 = 0) { this.v = (typeof value == "string" ? "s:" + value : "n") + n.toString(); }
}
class Child extends Labeled {}
class Grandchild extends Child {}
console.log(new Child("x").v, new Child("y", 2).v, new Grandchild("z", 3).v);
class Holder<T> extends Labeled { extra: T | null = null; }
console.log(new Holder<int32>("x").v, new Holder<string>("y", 2).v);
