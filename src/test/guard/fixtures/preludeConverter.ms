import { Node, NodeKind } from "std/meta";

export class VNodeFix {
	tag: string = "";
}

export converter fixJsxToVNodeFix(n: Node): VNodeFix {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
