import { Node, NodeKind } from "std/meta";

export macro nameOf(t: Node): Node {
	return { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: t, property: "name", isOptional: false };
}

export macro describe(t: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: t.line, column: t.column,
		callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "nameOf" },
		arguments: [t], isDirectCall: true, resolvedOverloadIdx: 0,
	};
}
