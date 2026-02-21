// AST Printer - Debug output for all node kinds
// Uses match statement for exhaustive dispatch

import { Node, NodeKind } from "./node";

// ===== Indentation Helper =====

function indent(level: number): string {
	let spaces = "";
	for (let i = 0; i < level; i++) {
		spaces += "  ";
	}
	return spaces;
}

// ===== Unified Node Printer =====

export function printNode(node: Node, level: number): void {
	const pad = indent(level);

	match (node.kind) {
		NodeKind.NumberLiteral => {
			const data = node.data as { value: number };
			console.log(`${pad}NumberLiteral: ${data.value.toString()}`);
		},
		NodeKind.StringLiteral => {
			const data = node.data as { value: string };
			console.log(`${pad}StringLiteral: ${data.value}`);
		},
		NodeKind.Identifier => {
			const data = node.data as { name: string };
			console.log(`${pad}Identifier: ${data.name}`);
		},
		NodeKind.BinaryExpr => {
			const data = node.data as { operator: string, left: Node, right: Node };
			console.log(`${pad}BinaryExpr: ${data.operator}`);
			printNode(data.left, level + 1);
			printNode(data.right, level + 1);
		},
		NodeKind.UnaryExpr => {
			const data = node.data as { unaryOp: string, operand: Node };
			console.log(`${pad}UnaryExpr: ${data.unaryOp}`);
			printNode(data.operand, level + 1);
		},
		NodeKind.CallExpr => {
			const data = node.data as { callee: Node, arguments: Node[] };
			console.log(`${pad}CallExpr:`);
			console.log(`${pad}  Callee:`);
			printNode(data.callee, level + 2);
			console.log(`${pad}  Arguments: ${data.arguments.length.toString()}`);
			for (const arg of data.arguments) {
				printNode(arg, level + 2);
			}
		},
		NodeKind.MemberExpr => {
			const data = node.data as { object: Node, property: string };
			console.log(`${pad}MemberExpr: .${data.property}`);
			printNode(data.object, level + 1);
		},
		NodeKind.ArrayAccess => {
			const data = node.data as { array: Node, index: Node };
			console.log(`${pad}ArrayAccess:`);
			printNode(data.array, level + 1);
			printNode(data.index, level + 1);
		},
		NodeKind.ObjectLiteral => {
			const data = node.data as { properties: Node[], keys: string[] };
			console.log(`${pad}ObjectLiteral: (${data.keys.length.toString()} props)`);
			let propIdx = 0;
			for (const prop of data.properties) {
				console.log(`${indent(level + 1)}${data.keys[propIdx]}:`);
				printNode(prop, level + 2);
				propIdx += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const data = node.data as { elements: Node[] };
			console.log(`${pad}ArrayLiteral: (${data.elements.length.toString()} elems)`);
			for (const elem of data.elements) {
				printNode(elem, level + 1);
			}
		},
		NodeKind.VariableDecl => {
			const data = node.data as { declName: string, initializer: Node, isConst: boolean };
			const keyword = match (data.isConst) { true => "const", _ => "let" };
			console.log(`${pad}VariableDecl: ${keyword} ${data.declName}`);
			printNode(data.initializer, level + 1);
		},
		NodeKind.IfStmt => {
			const data = node.data as { condition: Node, consequent: Node, alternate: Node };
			console.log(`${pad}IfStmt:`);
			console.log(`${pad}  Condition:`);
			printNode(data.condition, level + 2);
			console.log(`${pad}  Then:`);
			printNode(data.consequent, level + 2);
			// Skip empty else blocks (no-else case uses empty BlockStmt)
			if (data.alternate.kind === NodeKind.BlockStmt) {
				const altData = data.alternate.data as { statements: Node[] };
				if (altData.statements.length > 0) {
					console.log(`${pad}  Else:`);
					printNode(data.alternate, level + 2);
				}
			} else {
				console.log(`${pad}  Else:`);
				printNode(data.alternate, level + 2);
			}
		},
		NodeKind.WhileStmt => {
			const data = node.data as { whileCondition: Node, whileBody: Node };
			console.log(`${pad}WhileStmt:`);
			console.log(`${pad}  Condition:`);
			printNode(data.whileCondition, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.whileBody, level + 2);
		},
		NodeKind.ForStmt => {
			const data = node.data as { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node };
			console.log(`${pad}ForStmt:`);
			console.log(`${pad}  Init:`);
			printNode(data.forInit, level + 2);
			console.log(`${pad}  Condition:`);
			printNode(data.forCondition, level + 2);
			console.log(`${pad}  Update:`);
			printNode(data.forUpdate, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.forBody, level + 2);
		},
		NodeKind.ForOfStmt => {
			const data = node.data as { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node };
			const keyword = match (data.forOfIsConst) { true => "const", _ => "let" };
			console.log(`${pad}ForOfStmt: ${keyword} ${data.forOfBinding}`);
			console.log(`${pad}  Iterable:`);
			printNode(data.forOfIterable, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.forOfBody, level + 2);
		},
		NodeKind.BlockStmt => {
			const data = node.data as { statements: Node[] };
			console.log(`${pad}Block: (${data.statements.length.toString()} stmts)`);
			for (const stmt of data.statements) {
				printNode(stmt, level + 1);
			}
		},
		NodeKind.ExprStmt => {
			const data = node.data as { expr: Node };
			printNode(data.expr, level);
		},
		NodeKind.ReturnStmt => {
			const data = node.data as { argument: Node };
			console.log(`${pad}ReturnStmt:`);
			printNode(data.argument, level + 1);
		},
		NodeKind.BreakStmt => {
			console.log(`${pad}BreakStmt`);
		},
		NodeKind.ContinueStmt => {
			console.log(`${pad}ContinueStmt`);
		},
		NodeKind.FunctionDecl => {
			const data = node.data as { fnName: string, params: string[], fnBody: Node };
			console.log(`${pad}FunctionDecl: ${data.fnName} (${data.params.length.toString()} params)`);
			printNode(data.fnBody, level + 1);
		},
		NodeKind.ArrowFunction => {
			const data = node.data as { arrowParams: string[], arrowBody: Node };
			console.log(`${pad}ArrowFunction: (${data.arrowParams.length.toString()} params)`);
			console.log(`${pad}  Body:`);
			printNode(data.arrowBody, level + 2);
		},
		NodeKind.TypeAssertion => {
			const data = node.data as { asExpr: Node };
			console.log(`${pad}TypeAssertion:`);
			printNode(data.asExpr, level + 1);
		},
		NodeKind.TryExpr => {
			const data = node.data as { tryArg: Node, hasCatch: boolean, catchVal: Node };
			if (data.hasCatch) {
				console.log(`${pad}TryExpr (with catch):`);
				printNode(data.tryArg, level + 1);
				console.log(`${indent(level + 1)}Catch:`);
				printNode(data.catchVal, level + 2);
			} else {
				console.log(`${pad}TryExpr:`);
				printNode(data.tryArg, level + 1);
			}
		},
		NodeKind.MatchExpr => {
			const data = node.data as { matchDisc: Node, matchCases: Node[] };
			console.log(`${pad}MatchExpr: (${data.matchCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.matchDisc, level + 2);
			for (const c of data.matchCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.MatchCase => {
			const data = node.data as { casePatterns: Node[], caseBody: Node };
			console.log(`${pad}Case: (${data.casePatterns.length.toString()} patterns)`);
			for (const p of data.casePatterns) {
				printNode(p, level + 1);
			}
			console.log(`${indent(level + 1)}Body:`);
			printNode(data.caseBody, level + 2);
		},
		_ => {},
	}
}
