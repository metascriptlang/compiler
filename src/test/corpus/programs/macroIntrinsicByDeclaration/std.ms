import { Node, NodeKind, bindSym, getTypeImpl } from "std/meta";

interface Shape { w: int32; }
function helper(): int32 { return 1; }

export macro probe(e: Node): Node {
	const impl = getTypeImpl(Shape);
	const bound = bindSym("helper");
	return { kind: NodeKind.StringLiteral, line: e.line, column: e.column,
		value: (impl == null ? "std:null" : "std:expanded") + " " + (bound == null ? "std:unbound" : "std:bound") };
}
