import { Node, NodeKind } from "std/meta";

export macro create(node: Node): Node {
	return node;
}

export macro twice(n: Node): Node {
	return { kind: NodeKind.BinaryExpr, line: n.line, column: n.column, operator: "+", left: n, right: n };
}

export const hairlineWidth = 0.5;
