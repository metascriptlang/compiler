import { Node, NodeKind, createNodeAt } from "std/meta";

export class Scale {
	static twice(n: int32): int32 { return n * 2; }
	static quad(n: int32): int32 { return Scale.twice(Scale.twice(n)); }
}

export macro quadOf(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: Scale.quad(3).toString() }, at.location);
}
