import { Node, NodeKind } from "std/meta";

export macro keepNumber(value: Node): Node {
	function makeNumber(): Node | null {
		return { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 5 };
	}
	return makeNumber() as Node;
}

export macro nodeKindNumber(value: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: value.kind as number };
}

export const numberKind: number = NodeKind.NumberLiteral as number;
