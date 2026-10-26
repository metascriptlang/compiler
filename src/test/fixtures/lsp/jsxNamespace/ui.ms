export * as JSX from "./html";
import { Node, NodeKind } from "std/meta";
export converter view(n: Node): number {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
export macro ui(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
