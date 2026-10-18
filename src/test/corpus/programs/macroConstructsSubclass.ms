// @stdout: d3 deep7! range 2.5 | d3 deep7!
// note: a macro body constructs a subclass whose constructor calls super, one and two levels deep and for the std RangeError, as the same code does at runtime. The compile-time engine compiled the subclass on demand but not its parent, so super(...) found no parent init and the build stopped.

import { Node, NodeKind } from "std/meta";

class Base {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
class Derived extends Base {
	extra: int32;
	constructor(t: string, e: int32) { super(t); this.extra = e; }
}
class Deeper extends Derived {
	more: string;
	constructor() { super("deep", 7); this.more = "!"; }
}

macro built(v: Node): Node {
	const d = new Derived("d", 3);
	const e = new Deeper();
	const r = new RangeError("range");
	const n: float64 = 2.5;
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column,
		value: d.tag + d.extra.toString() + " " + e.tag + e.extra.toString() + e.more + " " + r.message + " " + n.toString() };
}

const d = new Derived("d", 3);
const e = new Deeper();
console.log(built(0) + " | " + d.tag + d.extra.toString() + " " + e.tag + e.extra.toString() + e.more);
