// Parity program — a method under an intrinsic decorator is the same routine
// as the undecorated one: a generic one is instantiated per call (instance and
// static, inferred and explicit type arguments, on a generic class, beside a
// user decorator), and a plain one stays a method call on JS.
//
// @stdout: x 2 x 2 y 3 z
// @exit: 0

import { Node, ClassMethodDecoratorContext } from "std/meta";

macro keepIt(value: Node, context: ClassMethodDecoratorContext): Node {
	return value;
}

class Holder {
	@noinline
	keep<T>(v: T): T { return v; }
	@noinline
	static skeep<T>(v: T): T { return v; }
	@keepIt @noinline
	both<T>(v: T): T { return v; }
	@noinline
	plain(v: string): string { return v; }
}

class Box<U> {
	u: U;
	constructor(u: U) { this.u = u; }
	@noinline
	pair<T>(v: T): T { return v; }
}

const h = new Holder();
const inferred = `${h.keep("x")} ${Holder.skeep([1, 2]).length}`;
const explicit = `${h.keep<string>("x")} ${Holder.skeep<string>("ab").length}`;
const b = new Box<int32>(3);
console.log(`${inferred} ${explicit} ${h.both("y")} ${b.pair(b.u)} ${h.plain("z")}`);
