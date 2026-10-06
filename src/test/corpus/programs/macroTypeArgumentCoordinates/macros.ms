import { Node, NodeKind } from "std/meta";

export macro position(): Node {
	const shape = getTypeArg();
	return { kind: NodeKind.StringLiteral, line: shape.line, column: shape.column,
		value: shape.line.toString() };
}

export macro unchanged(value: Node): Node { return value; }
