import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

export macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [{
			kind: NodeKind.VariableDecl, line: 0, column: 0,
			flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
			declName: "tpl", declType: "string",
			initializer: {
				kind: NodeKind.CallExpr, line: 0, column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
				arguments: [],
			},
			declKind: DeclKind.Const,
			nameLocation: { line: 0, column: 0 },
		}, { kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" }],
	};
}

export macro memoShow(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [{
			kind: NodeKind.VariableDecl, line: 0, column: 0,
			flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
			declName: "tpl", declType: "string",
			initializer: {
				kind: NodeKind.CallExpr, line: 0, column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
				arguments: [],
			},
			declKind: DeclKind.Const,
			nameLocation: { line: 0, column: 0 },
		}, {
			kind: NodeKind.CallExpr, line: 0, column: 0,
			callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "show" },
			arguments: [{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" }],
		}],
	};
}

export macro pair(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [
			{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "a", declType: "int32",
			  initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false },
			  declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } },
			{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "b", declType: "int32",
			  initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 2, isFloat: false },
			  declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } },
		],
	};
}
