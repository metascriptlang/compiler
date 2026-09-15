import { Node, NodeKind, DeclKind } from "std/meta";

export macro emitValue(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl, line: L, column: C,
				declName: "macroEmittedValue",
				declType: "int32",
				declKind: DeclKind.Const,
				initializer: { kind: NodeKind.NumberLiteral, line: L, column: C, value: 41, isFloat: false, intVal: 41 },
				nameLocation: { line: L, column: C },
			},
		],
	};
}
