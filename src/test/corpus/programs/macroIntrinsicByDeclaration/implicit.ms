import { Node, NodeKind } from "std/meta";

function triple(n: int32): int32 { return n * 3; }

export macro implicitBind(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bindSym("triple"), arguments: [x] };
}
