// Parity program — a class decorator that hands its class back unchanged
// keeps the class's getters and setters, written by hand or generated from
// an `accessor` field: the class crosses the macro wire and the accessor flag
// the parser recorded crosses with it.
//
// @stdout: 5 7 hi
// @exit: 0

import { Node, ClassDecoratorContext } from "std/meta";

macro keep(value: Node, context: ClassDecoratorContext): Node {
	return value;
}

@keep
class C {
	private _n: int32 = 1;
	get n(): int32 { return this._n; }
	set n(v: int32) { this._n = v; }
	accessor m: int32 = 2;
	accessor s: string = "h";
}

const c = new C();
c.n = 5;
c.m += 5;
c.s += "i";
console.log(String(c.n) + " " + String(c.m) + " " + c.s);
