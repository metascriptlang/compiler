import { Node, NodeKind, DeclKind } from "std/meta";

macro whenPresentDirect(value: Node, fn: Node): Node {
	const ln = value.line;
	const col = value.column;
	return {
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_o0", declType: "", declKind: DeclKind.Const, initializer: value },
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "!==", left: { kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }, right: { kind: NodeKind.NullLiteral, line: ln, column: col } },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [{ kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }] } },
				] },
			},
		] },
	};
}

macro whenPresentSpliced(value: Node, fn: Node): Node {
	const ln = value.line;
	const col = value.column;
	return { kind: NodeKind.SpliceMany, line: ln, column: col, spliceNodes: [
		{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_hoisted", declType: "", declKind: DeclKind.Const, initializer: { kind: NodeKind.StringLiteral, line: ln, column: col, value: "x" } },
		{
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_o0", declType: "", declKind: DeclKind.Const, initializer: value },
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "!==", left: { kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }, right: { kind: NodeKind.NullLiteral, line: ln, column: col } },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [{ kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }] } },
				] },
			},
		] },
	} ] };
}

macro whenTrue(fn: Node): Node {
	const ln = fn.line;
	const col = fn.column;
	return {
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BooleanLiteral, line: ln, column: col, boolValue: true },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [] } },
				] },
			},
		] },
	};
}

let observedPresent: string = "";

let observedTrue: int32 = 0;

function observePresent(value: string): void { observedPresent = observedPresent + value; }

function observeTrue(): void { observedTrue = observedTrue + 1; }

function runPresent(value: string | null): void {
	const direct = whenPresentDirect(value, observePresent);
	const spliced = whenPresentSpliced(value, observePresent);
	direct();
	spliced();
}

test "macro flow expansion: emitted guards narrow and control observable calls" {
	observedPresent = "";
	runPresent(null);
	assert observedPresent == "";
	runPresent("x");
	assert observedPresent == "xx";
	const before = observedTrue;
	const run = whenTrue(observeTrue);
	run();
	assert observedTrue == before + 1;
}
