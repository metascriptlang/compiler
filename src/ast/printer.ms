// AST Printer - Debug output for all node kinds
// Uses match statement for exhaustive dispatch

import { Node, NodeKind, DeclKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData, RegexLiteralData, BigIntLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData, FunctionExprData,
	TypeAssertionData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	QuoteExprData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	DestructuringDeclData, ExprStmtData, ReturnStmtData, ThrowStmtData, DeferStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	DoWhileStmtData, BlockStmtData, FunctionDeclData, SwitchStmtData, SwitchCaseData,
	MatchStmtData, TryCatchStmtData, UnreachableStmtData, TypeAnnotationData,
	MacroInvocationData, ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData, ProgramData
} from "./node";

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
			const data = node.data as NumberLiteralData;
			console.log(`${pad}NumberLiteral: ${data.value.toString()}`);
		},
		NodeKind.StringLiteral => {
			const data = node.data as StringLiteralData;
			console.log(`${pad}StringLiteral: ${data.value}`);
		},
		NodeKind.Identifier => {
			const data = node.data as IdentifierData;
			console.log(`${pad}Identifier: ${data.name}`);
		},
		NodeKind.BinaryExpr => {
			const data = node.data as BinaryExprData;
			console.log(`${pad}BinaryExpr: ${data.operator}`);
			printNode(data.left, level + 1);
			printNode(data.right, level + 1);
		},
		NodeKind.UnaryExpr => {
			const data = node.data as UnaryExprData;
			console.log(`${pad}UnaryExpr: ${data.unaryOp}`);
			printNode(data.operand, level + 1);
		},
		NodeKind.CallExpr => {
			const data = node.data as CallExprData;
			console.log(`${pad}CallExpr:`);
			console.log(`${pad}  Callee:`);
			printNode(data.callee, level + 2);
			console.log(`${pad}  Arguments: ${data.arguments.length.toString()}`);
			for (const arg of data.arguments) {
				printNode(arg, level + 2);
			}
		},
		NodeKind.MemberExpr => {
			const data = node.data as MemberExprData;
			if (data.isOptional) {
				console.log(`${pad}MemberExpr: ?.${data.property}`);
			} else {
				console.log(`${pad}MemberExpr: .${data.property}`);
			}
			printNode(data.object, level + 1);
		},
		NodeKind.ArrayAccess => {
			const data = node.data as ArrayAccessData;
			console.log(`${pad}ArrayAccess:`);
			printNode(data.array, level + 1);
			printNode(data.index, level + 1);
		},
		NodeKind.ObjectLiteral => {
			const data = node.data as ObjectLiteralData;
			console.log(`${pad}ObjectLiteral: (${data.keys.length.toString()} props)`);
			let propIdx = 0;
			for (const prop of data.properties) {
				console.log(`${indent(level + 1)}${data.keys[propIdx]}:`);
				printNode(prop, level + 2);
				propIdx += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const data = node.data as ArrayLiteralData;
			console.log(`${pad}ArrayLiteral: (${data.elements.length.toString()} elems)`);
			for (const elem of data.elements) {
				printNode(elem, level + 1);
			}
		},
		NodeKind.VariableDecl => {
			const data = node.data as VariableDeclData;
			const keyword = match (data.declKind) { DeclKind.Const => "const", DeclKind.Var => "var", _ => "let" };
			console.log(`${pad}VariableDecl: ${keyword} ${data.declName}`);
			printNode(data.initializer, level + 1);
		},
		NodeKind.IfStmt => {
			const data = node.data as IfStmtData;
			console.log(`${pad}IfStmt:`);
			console.log(`${pad}  Condition:`);
			printNode(data.condition, level + 2);
			console.log(`${pad}  Then:`);
			printNode(data.consequent, level + 2);
			// Skip empty else blocks (no-else case uses empty BlockStmt)
			if (data.alternate.kind === NodeKind.BlockStmt) {
				const altData = data.alternate.data as BlockStmtData;
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
			const data = node.data as WhileStmtData;
			console.log(`${pad}WhileStmt:`);
			console.log(`${pad}  Condition:`);
			printNode(data.whileCondition, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.whileBody, level + 2);
		},
		NodeKind.ForStmt => {
			const data = node.data as ForStmtData;
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
			const data = node.data as ForOfStmtData;
			const keyword = match (data.forOfIsConst) { true => "const", _ => "let" };
			console.log(`${pad}ForOfStmt: ${keyword} ${data.forOfBinding}`);
			console.log(`${pad}  Iterable:`);
			printNode(data.forOfIterable, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.forOfBody, level + 2);
		},
		NodeKind.BlockStmt => {
			const data = node.data as BlockStmtData;
			console.log(`${pad}Block: (${data.statements.length.toString()} stmts)`);
			for (const stmt of data.statements) {
				printNode(stmt, level + 1);
			}
		},
		NodeKind.ExprStmt => {
			const data = node.data as ExprStmtData;
			printNode(data.expr, level);
		},
		NodeKind.ReturnStmt => {
			const data = node.data as ReturnStmtData;
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
			const data = node.data as FunctionDeclData;
			if (data.fnFlags.length > 0) {
				console.log(`${pad}FunctionDecl: ${data.fnFlags} ${data.fnName} (${data.params.length.toString()} params)`);
			} else {
				console.log(`${pad}FunctionDecl: ${data.fnName} (${data.params.length.toString()} params)`);
			}
			printNode(data.fnBody, level + 1);
		},
		NodeKind.ArrowFunction => {
			const data = node.data as ArrowFunctionData;
			if (data.arrowFlags.length > 0) {
				console.log(`${pad}ArrowFunction: ${data.arrowFlags} (${data.arrowParams.length.toString()} params)`);
			} else {
				console.log(`${pad}ArrowFunction: (${data.arrowParams.length.toString()} params)`);
			}
			console.log(`${pad}  Body:`);
			printNode(data.arrowBody, level + 2);
		},
		NodeKind.TypeAssertion => {
			const data = node.data as TypeAssertionData;
			console.log(`${pad}TypeAssertion as ${data.asType}:`);
			printNode(data.asExpr, level + 1);
		},
		NodeKind.TryExpr => {
			const data = node.data as TryExprData;
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
			const data = node.data as MatchExprData;
			console.log(`${pad}MatchExpr: (${data.matchCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.matchDisc, level + 2);
			for (const c of data.matchCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.MatchCase => {
			const data = node.data as MatchCaseData;
			console.log(`${pad}Case: (${data.casePatterns.length.toString()} patterns)`);
			for (const p of data.casePatterns) {
				printNode(p, level + 1);
			}
			console.log(`${indent(level + 1)}Body:`);
			printNode(data.caseBody, level + 2);
		},
		NodeKind.ImportDecl => {
			const data = node.data as ImportDeclData;
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
			const data = node.data as ExportDeclData;
			console.log(`${pad}ExportDecl:`);
			printNode(data.exportedDecl, level + 1);
		},
		NodeKind.TypeAliasDecl => {
			const data = node.data as TypeAliasDeclData;
			if (data.aliasIsDistinct) {
				console.log(`${pad}TypeAliasDecl: distinct ${data.aliasName}`);
			} else {
				console.log(`${pad}TypeAliasDecl: ${data.aliasName}`);
			}
		},
		NodeKind.EnumDecl => {
			const data = node.data as EnumDeclData;
			console.log(`${pad}EnumDecl: ${data.enumName} (${data.enumMembers.length.toString()} members)`);
			for (const member of data.enumMembers) {
				console.log(`${indent(level + 1)}${member}`);
			}
		},
		NodeKind.InterfaceDecl => {
			const data = node.data as InterfaceDeclData;
			console.log(`${pad}InterfaceDecl: ${data.interfaceName} (${data.interfaceFields.length.toString()} fields)`);
			for (const field of data.interfaceFields) {
				console.log(`${indent(level + 1)}${field}`);
			}
		},
		NodeKind.ThrowStmt => {
			const data = node.data as ThrowStmtData;
			console.log(`${pad}ThrowStmt:`);
			printNode(data.throwArg, level + 1);
		},
		NodeKind.ConditionalExpr => {
			const data = node.data as ConditionalExprData;
			console.log(`${pad}ConditionalExpr:`);
			console.log(`${indent(level + 1)}Condition:`);
			printNode(data.ternaryCondition, level + 2);
			console.log(`${indent(level + 1)}Then:`);
			printNode(data.ternaryConsequent, level + 2);
			console.log(`${indent(level + 1)}Else:`);
			printNode(data.ternaryAlternate, level + 2);
		},
		NodeKind.SpreadExpr => {
			const data = node.data as SpreadExprData;
			console.log(`${pad}SpreadExpr:`);
			printNode(data.spreadArg, level + 1);
		},
		NodeKind.NewExpr => {
			const data = node.data as NewExprData;
			console.log(`${pad}NewExpr: (${data.newArguments.length.toString()} args)`);
			console.log(`${indent(level + 1)}Callee:`);
			printNode(data.newCallee, level + 2);
			for (const arg of data.newArguments) {
				printNode(arg, level + 1);
			}
		},
		NodeKind.TryCatchStmt => {
			const data = node.data as TryCatchStmtData;
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
			const data = node.data as DoWhileStmtData;
			console.log(`${pad}DoWhileStmt:`);
			console.log(`${indent(level + 1)}Body:`);
			printNode(data.doBody, level + 2);
			console.log(`${indent(level + 1)}Condition:`);
			printNode(data.doCondition, level + 2);
		},
		NodeKind.SwitchStmt => {
			const data = node.data as SwitchStmtData;
			console.log(`${pad}SwitchStmt: (${data.switchCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.switchDisc, level + 2);
			for (const c of data.switchCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.SwitchCase => {
			const data = node.data as SwitchCaseData;
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
			const data = node.data as ClassDeclData;
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
			const data = node.data as PropertyDeclData;
			if (data.propIsStatic) {
				console.log(`${pad}PropertyDecl: static ${data.propName}`);
			} else {
				console.log(`${pad}PropertyDecl: ${data.propName}`);
			}
		},
		NodeKind.MethodDecl => {
			const data = node.data as MethodDeclData;
			let methodPrefix = "";
			if (data.methodIsStatic) { methodPrefix = "static "; }
			if (data.methodFlags.length > 0) { methodPrefix = methodPrefix + data.methodFlags + " "; }
			console.log(`${pad}MethodDecl: ${methodPrefix}${data.methodName} (${data.methodParams.length.toString()} params)`);
			printNode(data.methodBody, level + 1);
		},
		NodeKind.DeferStmt => {
			const data = node.data as DeferStmtData;
			console.log(`${pad}DeferStmt:`);
			printNode(data.deferExpr, level + 1);
		},
		NodeKind.BooleanLiteral => {
			const data = node.data as BooleanLiteralData;
			if (data.boolValue) { console.log(`${pad}BooleanLiteral: true`); }
			else { console.log(`${pad}BooleanLiteral: false`); }
		},
		NodeKind.NullLiteral => {
			console.log(`${pad}NullLiteral`);
		},
		NodeKind.RegexLiteral => {
			const data = node.data as RegexLiteralData;
			console.log(`${pad}RegexLiteral: ${data.regexPattern}`);
		},
		NodeKind.BigIntLiteral => {
			const data = node.data as BigIntLiteralData;
			console.log(`${pad}BigIntLiteral: ${data.bigintValue}`);
		},
		NodeKind.UpdateExpr => {
			const data = node.data as UpdateExprData;
			if (data.isPrefix) { console.log(`${pad}UpdateExpr: prefix ${data.updateOp}`); }
			else { console.log(`${pad}UpdateExpr: postfix ${data.updateOp}`); }
			printNode(data.updateArg, level + 1);
		},
		NodeKind.AwaitExpr => {
			const data = node.data as AwaitExprData;
			console.log(`${pad}AwaitExpr:`);
			printNode(data.awaitArg, level + 1);
		},
		NodeKind.YieldExpr => {
			const data = node.data as YieldExprData;
			if (data.isDelegate) { console.log(`${pad}YieldExpr: delegate`); }
			else { console.log(`${pad}YieldExpr:`); }
			printNode(data.yieldArg, level + 1);
		},
		NodeKind.MoveExpr => {
			const data = node.data as MoveExprData;
			console.log(`${pad}MoveExpr:`);
			printNode(data.moveArg, level + 1);
		},
		NodeKind.OutExpr => {
			const data = node.data as OutExprData;
			console.log(`${pad}OutExpr:`);
			printNode(data.outArg, level + 1);
		},
		NodeKind.HiddenDeref => {
			const data = node.data as ExprStmtData;
			console.log(`${pad}HiddenDeref:`);
			printNode(data.expr, level + 1);
		},
		NodeKind.FunctionExpr => {
			const data = node.data as FunctionExprData;
			if (data.funcExprFlags.length > 0) {
				console.log(`${pad}FunctionExpr: ${data.funcExprFlags} (${data.funcExprParams.length.toString()} params)`);
			} else {
				console.log(`${pad}FunctionExpr: (${data.funcExprParams.length.toString()} params)`);
			}
			printNode(data.funcExprBody, level + 1);
		},
		NodeKind.ConstructorDecl => {
			const data = node.data as ConstructorDeclData;
			console.log(`${pad}ConstructorDecl: (${data.ctorParams.length.toString()} params)`);
			printNode(data.ctorBody, level + 1);
		},
		NodeKind.UnreachableStmt => {
			const data = node.data as UnreachableStmtData;
			if (data.unreachableMsg.length > 0) {
				console.log(`${pad}UnreachableStmt: "${data.unreachableMsg}"`);
			} else {
				console.log(`${pad}UnreachableStmt`);
			}
		},
		NodeKind.TypeAnnotation => {
			const data = node.data as TypeAnnotationData;
			console.log(`${pad}TypeAnnotation: ${data.annotationType}`);
		},
		NodeKind.MatchStmt => {
			const data = node.data as MatchStmtData;
			console.log(`${pad}MatchStmt: (${data.matchStmtCases.length.toString()} cases)`);
			console.log(`${indent(level + 1)}Discriminant:`);
			printNode(data.matchStmtDisc, level + 2);
			for (const c of data.matchStmtCases) {
				printNode(c, level + 1);
			}
		},
		NodeKind.Program => {
			const data = node.data as ProgramData;
			console.log(`${pad}Program: (${data.programStmts.length.toString()} stmts)`);
			for (const stmt of data.programStmts) {
				printNode(stmt, level + 1);
			}
		},
		NodeKind.ForInStmt => {
			const data = node.data as ForInStmtData;
			const keyword = match (data.forInIsConst) { true => "const", _ => "let" };
			console.log(`${pad}ForInStmt: ${keyword} ${data.forInBinding}`);
			console.log(`${pad}  Object:`);
			printNode(data.forInObject, level + 2);
			console.log(`${pad}  Body:`);
			printNode(data.forInBody, level + 2);
		},
		NodeKind.MacroInvocation => {
			const data = node.data as MacroInvocationData;
			console.log(`${pad}MacroInvocation: @${data.macroName} (${data.macroArgs.length.toString()} args)`);
			for (const arg of data.macroArgs) {
				printNode(arg, level + 1);
			}
		},
		NodeKind.DecoratedDecl => {
			const data = node.data as DecoratedDeclData;
			console.log(`${pad}DecoratedDecl: (${data.decorators.length.toString()} decorators)`);
			for (const dec of data.decorators) {
				printNode(dec, level + 1);
			}
			console.log(`${indent(level + 1)}Declaration:`);
			printNode(data.decoratedNode, level + 2);
		},
		NodeKind.ArrayPattern => {
			const data = node.data as ArrayPatternData;
			console.log(`${pad}ArrayPattern: (${data.patternElements.length.toString()} elements)`);
			for (const elem of data.patternElements) {
				printNode(elem, level + 1);
			}
		},
		NodeKind.ObjectPattern => {
			const data = node.data as ObjectPatternData;
			console.log(`${pad}ObjectPattern: (${data.patternProps.length.toString()} props)`);
			for (const prop of data.patternProps) {
				printNode(prop, level + 1);
			}
		},
		NodeKind.ObjectPatternProp => {
			const data = node.data as ObjectPatternPropData;
			console.log(`${pad}ObjectPatternProp: ${data.propKey}`);
			printNode(data.propAlias, level + 1);
		},
		NodeKind.DestructuringDecl => {
			const data = node.data as DestructuringDeclData;
			const keyword = match (data.destrIsConst) { true => "const", _ => "let" };
			console.log(`${pad}DestructuringDecl: ${keyword}`);
			console.log(`${indent(level + 1)}Pattern:`);
			printNode(data.destrPattern, level + 2);
			console.log(`${indent(level + 1)}Init:`);
			printNode(data.destrInit, level + 2);
		},
		NodeKind.ExternDecl => {
			const data = node.data as ExternDeclData;
			console.log(`${pad}ExternDecl: extern ${data.externKind} ${data.externName}`);
		},
		NodeKind.MacroDecl => {
			const data = node.data as MacroDeclData;
			console.log(`${pad}MacroDecl: ${data.macroDeclName} (${data.macroDeclParams.length.toString()} params)`);
			printNode(data.macroDeclBody, level + 1);
		},
		NodeKind.QuoteExpr => {
			const data = node.data as QuoteExprData;
			console.log(`${pad}QuoteExpr:`);
			printNode(data.quoteBody, level + 1);
		},
		_ => {},
	}
}
