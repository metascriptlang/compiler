import { Node, NodeKind, bindSym } from "std/meta";

export macro emitBoundIface(node: Node): Node {
	return {
		kind: NodeKind.SpliceMany, line: node.line, column: node.column,
		spliceNodes: [
			{
				kind: NodeKind.InterfaceDecl, line: node.line, column: node.column,
				interfaceName: "BoundEmitted",
				interfaceFields: ["b"],
				interfaceFieldTypes: ["float64"],
				interfaceExtends: [],
				nameLocation: { line: node.line, column: node.column },
			},
		],
	};
}

export macro emitViaBound(node: Node): Node {
	return {
		kind: NodeKind.SpliceMany, line: node.line, column: node.column,
		spliceNodes: [
			{
				kind: NodeKind.ExprStmt, line: node.line, column: node.column,
				expr: { kind: NodeKind.CallExpr, line: node.line, column: node.column, callee: bindSym("emitBoundIface"), arguments: [node] },
			},
		],
	};
}
