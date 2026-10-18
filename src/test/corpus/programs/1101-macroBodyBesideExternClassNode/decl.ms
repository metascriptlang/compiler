import { Node, NodeKind } from "std/meta";

export macro kindNumber(value: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: value.kind as number };
}

export const numberKind: number = NodeKind.NumberLiteral as number;
