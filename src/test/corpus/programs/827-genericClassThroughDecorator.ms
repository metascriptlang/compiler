// Parity program — a generic class handed back by a decorator macro keeps its
// type parameters: the macro bridge carries a declaration's generic params.
//
// @stdout: hi 7
// @exit: 0

import { Node, ClassDecoratorContext } from "std/meta";

macro keep(value: Node, context: ClassDecoratorContext): Node {
	return value;
}

@keep
class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

const a = new Box<string>("hi");
const b = new Box<int32>(7);
console.log(a.v, b.v);
