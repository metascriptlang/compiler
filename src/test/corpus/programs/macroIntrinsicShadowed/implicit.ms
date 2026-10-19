import { Node, NodeKind } from "std/meta";

export macro kindOf(): Node {
	const t = getTypeArg();
	if (t.kind == NodeKind.StringLiteral) error("kindOf wants a type", t);
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: t.kind == NodeKind.TypeObject ? "object" : "named" };
}

export macro plusOne(x: Node): Node {
	return quote { splice(x) + 1 };
}
