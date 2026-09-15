import { Node, NodeKind, DeclKind } from "std/meta";

export macro emitJsxSeen(node: Node): Node {
	const L = node.line;
	const C = node.column;
	const seen = node.kind == NodeKind.JSXElement ? 1 : 0;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl, line: L, column: C,
				declName: "jsxSeen",
				declType: "int32",
				declKind: DeclKind.Const,
				initializer: { kind: NodeKind.NumberLiteral, line: L, column: C, value: seen, isFloat: false, intVal: seen },
				nameLocation: { line: L, column: C },
			},
		],
	};
}
