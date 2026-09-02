// @stdout: a+b=3
// Pins the checker-side splice (a macro returning SpliceMany at module top).
// The expansion happens in the checker, so it is backend-neutral: every lane,
// js included, must arrive at the same two constants.
import { Node, NodeKind, DeclKind } from "std/meta";

macro pair(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0, column: 0,
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

pair();
console.log("a+b=" + (a + b).toString());
