import { Node, NodeKind } from "std/meta";

export macro readAbsent(node: Node): Node {
	const absent = node.object;
	const k = absent.kind;
	return { kind: NodeKind.SpliceMany, line: node.line, column: node.column, spliceNodes: [] };
}
