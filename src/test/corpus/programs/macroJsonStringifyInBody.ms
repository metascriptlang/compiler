// @stdout: flat={"kind":0,"name":""} nested={"id":7,"items":[{"kind":1,"name":"a"},{"kind":2,"name":"b"}],"tag":"High"} same=true,true
// note: jsonStringify called inside a macro body expands without the user importing jsonValueOf: a flat class, a class holding an array of another class and an enum field, and the text matches what the same call gives at run time.

import { Node, NodeKind } from "std/meta";
import { jsonStringify } from "std/serialize/json";

enum Tag { None, Low, High }

class Leaf { kind: int32 = 0; name: string = ""; }
class Holder { id: int32 = 7; items: Leaf[] = []; tag: Tag = Tag.High; }

function holder(): Holder {
	const h = new Holder();
	const a = new Leaf(); a.kind = 1; a.name = "a";
	const b = new Leaf(); b.kind = 2; b.name = "b";
	h.items.push(a);
	h.items.push(b);
	return h;
}

macro flat(): Node {
	const text = jsonStringify(new Leaf());
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: text };
}

macro nested(): Node {
	const text = jsonStringify(holder());
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: text };
}

const f = flat();
const n = nested();
console.log(`flat=${f} nested=${n} same=${f == jsonStringify(new Leaf())},${n == jsonStringify(holder())}`);
