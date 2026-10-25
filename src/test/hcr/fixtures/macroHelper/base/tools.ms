import { Node, NodeKind, childCount } from "std/meta";

export function arity(n: Node): number {
	return childCount(n);
}

export macro countArgs(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: `${arity(n)}` };
}
