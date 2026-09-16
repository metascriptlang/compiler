import { Node, NodeKind } from "std/meta";

export macro emitHelper(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.FunctionDecl, line: L, column: C,
			fnName: "__preludeMacroCycleGen", params: [], fnParamTypes: [],
			fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [
				{ kind: NodeKind.ReturnStmt, line: L, column: C,
				  argument: { kind: NodeKind.NumberLiteral, line: L, column: C, value: 42, isFloat: false, intVal: 42 as int64 } },
			] },
			fnFlags: "", fnReturnType: "int32", fnDefaults: [], nativeName: "",
			nameLocation: { line: L, column: C },
		}],
	};
}
