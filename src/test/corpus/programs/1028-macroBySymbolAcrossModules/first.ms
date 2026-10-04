import { Node, NodeKind } from "std/meta";

export macro pick(n: Node): Node {
	const generated: Node = { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 1 };
	return generated;
}
