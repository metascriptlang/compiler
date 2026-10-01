import { Node, NodeKind } from "std/meta";

export macro pick(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 2 };
}
