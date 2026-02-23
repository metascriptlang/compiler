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
			const data = node.data as { fnName: string, params: string[], fnBody: Node, fnFlags: string };
			if (data.fnFlags.length > 0) {
				console.log(`${pad}FunctionDecl: ${data.fnFlags} ${data.fnName} (${data.params.length.toString()} params)`);
			} else {
				console.log(`${pad}FunctionDecl: ${data.fnName} (${data.params.length.toString()} params)`);
			}
			printNode(data.fnBody, level + 1);
		},
		NodeKind.ArrowFunction => {
			const data = node.data as { arrowParams: string[], arrowBody: Node, arrowFlags: string };
			if (data.arrowFlags.length > 0) {
				console.log(`${pad}ArrowFunction: ${data.arrowFlags} (${data.arrowParams.length.toString()} params)`);
			} else {
				console.log(`${pad}ArrowFunction: (${data.arrowParams.length.toString()} params)`);
			}
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
		NodeKind.ImportDecl => {
			const data = node.data as { importNames: string[], importAliases: string[], importSource: string };
			console.log(`${pad}ImportDecl: "${data.importSource}" (${data.importNames.length.toString()} specifiers)`);
			let specIdx = 0;
			for (const name of data.importNames) {
				if (name !== data.importAliases[specIdx]) {
					console.log(`${indent(level + 1)}${name} as ${data.importAliases[specIdx]}`);
				} else {
					console.log(`${indent(level + 1)}${name}`);
				}
				specIdx += 1;
			}
		},
		NodeKind.ExportDecl => {
			const data = node.data as { exportedDecl: Node };
			console.log(`${pad}ExportDecl:`);
			printNode(data.exportedDecl, level + 1);
		},
		NodeKind.TypeAliasDecl => {
			const data = node.data as { aliasName: string };
			console.log(`${pad}TypeAliasDecl: ${data.aliasName}`);
		},
		NodeKind.EnumDecl => {
			const data = node.data as { enumName: string, enumMembers: string[] };
			console.log(`${pad}EnumDecl: ${data.enumName} (${data.enumMembers.length.toString()} members)`);
			for (const member of data.enumMembers) {
				console.log(`${indent(level + 1)}${member}`);
			}
		},
		NodeKind.InterfaceDecl => {
			const data = node.data as { interfaceName: string, interfaceFields: string[] };
			console.log(`${pad}InterfaceDecl: ${data.interfaceName} (${data.interfaceFields.length.toString()} fields)`);
			for (const field of data.interfaceFields) {
				console.log(`${indent(level + 1)}${field}`);
			}
		},
		NodeKind.ThrowStmt => {
			const data = node.data as { throwArg: Node };
			console.log(`${pad}ThrowStmt:`);
			printNode(data.throwArg, level + 1);
		},
		NodeKind.ConditionalExpr => {
			const data = node.data as { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node };
			console.log(`${pad}ConditionalExpr:`);
			console.log(`${indent(level + 1)}Condition:`);
			printNode(data.ternaryCondition, level + 2);
			console.log(`${indent(level + 1)}Then:`);
			printNode(data.ternaryConsequent, level + 2);
			console.log(`${indent(level + 1)}Else:`);
			printNode(data.ternaryAlternate, level + 2);
		},
		NodeKind.SpreadExpr => {
			const data = node.data as { spreadArg: Node };
			console.log(`${pad}SpreadExpr:`);
			printNode(data.spreadArg, level + 1);
		},
		NodeKind.NewExpr => {
			const data = node.data as { newCallee: Node, newArguments: Node[] };
			console.log(`${pad}NewExpr: (${data.newArguments.length.toString()} args)`);
			console.log(`${indent(level + 1)}Callee:`);
			printNode(data.newCallee, level + 2);
			for (const arg of data.newArguments) {
				printNode(arg, level + 1);
			}
		},
		NodeKind.TryCatchStmt => {
			const data = node.data as { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node };
			console.log(`${pad}TryCatchStmt:`);
			console.log(`${indent(level + 1)}Try:`);
			printNode(data.tryBody, level + 2);
			if (data.catchName.length > 0) {
				console.log(`${indent(level + 1)}Catch (${data.catchName}):`);
			} else {
				console.log(`${indent(level + 1)}Catch:`);
			}
			printNode(data.catchBody, level + 2);
			console.log(`${indent(level + 1)}Finally:`);
			printNode(data.finallyBody, level + 2);
		},
		NodeKind.DoWhileStmt => {
			const data = node.data as { doBody: Node, doCondition: Node };
			console.log(`${pad}DoWhileStmt:`);
			console.log(`${indent(level + 1)}Body:`);
			printNode(data.doBody, level + 2);
			console.log(`${indent(level + 1)}Condition:`);
			printNode(data.doCondition, level + 2);
		},
		NodeKind.SwitchStmt => {
			const data = node.data as { switchDisc: Node, switchCases: Node[] };
			console.log(`${pad}SwitchStmt: (${data.switchCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.switchDisc, level + 2);
			for (const c of data.switchCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.SwitchCase => {
			const data = node.data as { caseTests: Node[], caseStmts: Node[], isDefault: boolean };
			if (data.isDefault) {
				console.log(`${pad}DefaultCase:`);
			} else {
				console.log(`${pad}Case: (${data.caseTests.length.toString()} tests)`);
				for (const t of data.caseTests) {
					printNode(t, level + 1);
				}
			}
			for (const s of data.caseStmts) {
				printNode(s, level + 1);
			}
		},
		NodeKind.ClassDecl => {
			const data = node.data as { className: string, classExtends: string, classBody: Node[] };
			if (data.classExtends.length > 0) {
				console.log(`${pad}ClassDecl: ${data.className} extends ${data.classExtends} (${data.classBody.length.toString()} members)`);
			} else {
				console.log(`${pad}ClassDecl: ${data.className} (${data.classBody.length.toString()} members)`);
			}
			for (const member of data.classBody) {
				printNode(member, level + 1);
			}
		},
		NodeKind.PropertyDecl => {
			const data = node.data as { propName: string, propIsStatic: boolean };
			if (data.propIsStatic) {
				console.log(`${pad}PropertyDecl: static ${data.propName}`);
			} else {
				console.log(`${pad}PropertyDecl: ${data.propName}`);
			}
		},
		NodeKind.MethodDecl => {
			const data = node.data as { methodName: string, methodParams: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string };
			let methodPrefix = "";
			if (data.methodIsStatic) { methodPrefix = "static "; }
			if (data.methodFlags.length > 0) { methodPrefix = methodPrefix + data.methodFlags + " "; }
			console.log(`${pad}MethodDecl: ${methodPrefix}${data.methodName} (${data.methodParams.length.toString()} params)`);
			printNode(data.methodBody, level + 1);
		},
		NodeKind.DeferStmt => {
			const data = node.data as { deferExpr: Node };
			console.log(`${pad}DeferStmt:`);
			printNode(data.deferExpr, level + 1);
		},
		NodeKind.BooleanLiteral => {
			const data = node.data as { boolValue: boolean };
			if (data.boolValue) { console.log(`${pad}BooleanLiteral: true`); }
			else { console.log(`${pad}BooleanLiteral: false`); }
		},
		NodeKind.NullLiteral => {
			console.log(`${pad}NullLiteral`);
		},
		NodeKind.RegexLiteral => {
			const data = node.data as { regexPattern: string };
			console.log(`${pad}RegexLiteral: ${data.regexPattern}`);
		},
		NodeKind.BigIntLiteral => {
			const data = node.data as { bigintValue: string };
			console.log(`${pad}BigIntLiteral: ${data.bigintValue}`);
		},
		NodeKind.UpdateExpr => {
			const data = node.data as { updateOp: string, updateArg: Node, isPrefix: boolean };
			if (data.isPrefix) { console.log(`${pad}UpdateExpr: prefix ${data.updateOp}`); }
			else { console.log(`${pad}UpdateExpr: postfix ${data.updateOp}`); }
			printNode(data.updateArg, level + 1);
		},
		NodeKind.AwaitExpr => {
			const data = node.data as { awaitArg: Node };
			console.log(`${pad}AwaitExpr:`);
			printNode(data.awaitArg, level + 1);
		},
		NodeKind.YieldExpr => {
			const data = node.data as { yieldArg: Node, isDelegate: boolean };
			if (data.isDelegate) { console.log(`${pad}YieldExpr: delegate`); }
			else { console.log(`${pad}YieldExpr:`); }
			printNode(data.yieldArg, level + 1);
		},
		NodeKind.MoveExpr => {
			const data = node.data as { moveArg: Node };
			console.log(`${pad}MoveExpr:`);
			printNode(data.moveArg, level + 1);
		},
		NodeKind.OutExpr => {
			const data = node.data as { outArg: Node };
			console.log(`${pad}OutExpr:`);
			printNode(data.outArg, level + 1);
		},
		NodeKind.FunctionExpr => {
			const data = node.data as { funcExprParams: string[], funcExprBody: Node, funcExprFlags: string };
			if (data.funcExprFlags.length > 0) {
				console.log(`${pad}FunctionExpr: ${data.funcExprFlags} (${data.funcExprParams.length.toString()} params)`);
			} else {
				console.log(`${pad}FunctionExpr: (${data.funcExprParams.length.toString()} params)`);
			}
			printNode(data.funcExprBody, level + 1);
		},
		NodeKind.ConstructorDecl => {
			const data = node.data as { ctorParams: string[], ctorBody: Node };
			console.log(`${pad}ConstructorDecl: (${data.ctorParams.length.toString()} params)`);
			printNode(data.ctorBody, level + 1);
		},
		NodeKind.UnreachableStmt => {
			const data = node.data as { unreachableMsg: string };
			if (data.unreachableMsg.length > 0) {
				console.log(`${pad}UnreachableStmt: "${data.unreachableMsg}"`);
			} else {
				console.log(`${pad}UnreachableStmt`);
			}
		},
		NodeKind.TypeAnnotation => {
			const data = node.data as { annotationType: string };
			console.log(`${pad}TypeAnnotation: ${data.annotationType}`);
		},
		NodeKind.MatchStmt => {
			const data = node.data as { matchStmtDisc: Node, matchStmtCases: Node[] };
			console.log(`${pad}MatchStmt: (${data.matchStmtCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.matchStmtDisc, level + 2);
			for (const c of data.matchStmtCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.Program => {
			const data = node.data as { programStmts: Node[] };
			console.log(`${pad}Program: (${data.programStmts.length.toString()} stmts)`);
			for (const stmt of data.programStmts) {
				printNode(stmt, level + 1);
			}
		},
		NodeKind.ForInStmt => {
			const data = node.data as { forInBinding: string, forInIsConst: boolean, forInObject: Node, forInBody: Node };
			const keyword = match (data.forInIsConst) { true => "const", _ => "let" };
			console.log(`${pad}ForInStmt: ${keyword} ${data.forInBinding}`);
			console.log(`${pad}  Object:`);
			printNode(data.forInObject, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.forInBody, level + 2);
		},
		NodeKind.MacroInvocation => {
			const data = node.data as { macroName: string, macroArgs: Node[] };
			console.log(`${pad}MacroInvocation: @${data.macroName} (${data.macroArgs.length.toString()} args)`);
			for (const arg of data.macroArgs) {
				printNode(arg, level + 1);
			}
		},
		NodeKind.DecoratedDecl => {
			const data = node.data as { decorators: Node[], decoratedNode: Node };
			console.log(`${pad}DecoratedDecl: (${data.decorators.length.toString()} decorators)`);
			for (const dec of data.decorators) {
				printNode(dec, level + 1);
			}
			console.log(`${indent(level + 1)}Declaration:`);
			printNode(data.decoratedNode, level + 2);
		},
		NodeKind.ArrayPattern => {
			const data = node.data as { patternElements: Node[], hasRestElement: boolean };
			console.log(`${pad}ArrayPattern: (${data.patternElements.length.toString()} elements)`);
			for (const elem of data.patternElements) {
				printNode(elem, level + 1);
			}
		},
		NodeKind.ObjectPattern => {
			const data = node.data as { patternProps: Node[], hasRestProp: boolean };
			console.log(`${pad}ObjectPattern: (${data.patternProps.length.toString()} props)`);
			for (const prop of data.patternProps) {
				printNode(prop, level + 1);
			}
		},
		NodeKind.ObjectPatternProp => {
			const data = node.data as { propKey: string, propAlias: Node };
			console.log(`${pad}ObjectPatternProp: ${data.propKey}`);
			printNode(data.propAlias, level + 1);
		},
		NodeKind.DestructuringDecl => {
			const data = node.data as { destrPattern: Node, destrInit: Node, destrIsConst: boolean };
			const keyword = match (data.destrIsConst) { true => "const", _ => "let" };
			console.log(`${pad}DestructuringDecl: ${keyword}`);
			console.log(`${indent(level + 1)}Pattern:`);
			printNode(data.destrPattern, level + 2);
			console.log(`${indent(level + 1)}Init:`);
			printNode(data.destrInit, level + 2);
		},
		_ => {},
	}
}
