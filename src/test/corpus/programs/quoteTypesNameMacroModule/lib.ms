import { Node } from "std/meta";

export class Box { v: int32 = 100; }
export struct Pair { a: int64; b: int64; }

export macro sizes(x: Node): Node {
	return quote { (() => {
		class Holder { b: Box = new Box(); pass(b: Box): Box { return b; } }
		function isBox(x: Box | string): x is Box { return typeof x != "string"; }
		const u: Box | string = new Box();
		const h = new Holder();
		const n: int32 = sizeof Pair;
		return `${n} ${h.pass(h.b).v} ${isBox(u) ? u.v : 0}`;
	})() };
}
