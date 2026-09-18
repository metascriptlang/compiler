import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

export macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: NodeFlag.StaticStorage,
				declName: "tpl",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "buildTemplate" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" },
		],
	};
}

export macro memoInList(): Node {
	return {
		kind: NodeKind.CallExpr,
		line: 0,
		column: 0,
		callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "firstOf" },
		arguments: [{
			kind: NodeKind.ArrayLiteral,
			line: 0,
			column: 0,
			elements: [{ kind: NodeKind.MacroInvocation, line: 0, column: 0, macroName: "memo", macroArgs: [] }],
		}],
	};
}
