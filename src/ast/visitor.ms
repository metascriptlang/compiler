// forEachChild — canonical read-only child enumerator for all NodeKinds.
// Single source of truth for "what are the child nodes of this NodeKind?"
// Used by analysis passes (reachability, DCE, LSP suggest, validate).
// For MUTATING traversal (transform passes), use mapChildren in transform/walker.ms.
// SYNC: mapChildren in transform/walker.ms must handle the same NodeKinds.

import {
	Node, NodeKind,
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData, PropertyDeclData,
	ExportDeclData, DecoratedDeclData, MacroDeclData,
	VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData,
	TryCatchStmtData, DeferStmtData,
	BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchStmtData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	HiddenDerefData, HiddenStdConvData,
	TypeAssertionData, DestructuringDeclData, QuoteExprData, ComptimeBlockData,
	MacroInvocationData, TestDeclData, AssertStmtData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	TypeGenericData, TypeArrayData, TypeUnionData, TypeFunctionData, TypeObjectData,
} from "./node";

type ChildVisitor = (child: Node) => void;

// Visit all child nodes of a given node (read-only, no mutation).
export function forEachChild(node: Node, cb: ChildVisitor): void {
	if (node === null) return;
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				cb(d.programStmts[i]);
				i += 1;
			}
		},
		// Block
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				cb(d.statements[i]);
				i += 1;
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			cb(d.condition);
			cb(d.consequent);
			cb(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			cb(d.whileCondition);
			cb(d.whileBody);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			cb(d.forInit);
			cb(d.forCondition);
			cb(d.forUpdate);
			cb(d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			cb(d.forOfIterable);
			cb(d.forOfBody);
			if (d.forOfPattern !== null) { cb(d.forOfPattern); }
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			cb(d.forInObject);
			cb(d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			cb(d.doBody);
			cb(d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			cb(d.switchDisc);
			let i = 0;
			while (i < d.switchCases.length) {
				cb(d.switchCases[i]);
				i += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let i = 0;
			while (i < d.caseTests.length) {
				cb(d.caseTests[i]);
				i += 1;
			}
			let j = 0;
			while (j < d.caseStmts.length) {
				cb(d.caseStmts[j]);
				j += 1;
			}
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			cb(d.matchStmtDisc);
			let i = 0;
			while (i < d.matchStmtCases.length) {
				cb(d.matchStmtCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			cb(d.matchDisc);
			let i = 0;
			while (i < d.matchCases.length) {
				cb(d.matchCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			let i = 0;
			while (i < d.casePatterns.length) {
				cb(d.casePatterns[i]);
				i += 1;
			}
			cb(d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			cb(d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			cb(d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			cb(d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				cb(d.classBody[i]);
				i += 1;
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			cb(d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			cb(d.ctorBody);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			cb(d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			cb(d.decoratedNode);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			cb(d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			cb(d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			cb(d.argument);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			cb(d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			cb(d.expr);
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			cb(d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			cb(d.tryBody);
			cb(d.catchBody);
			cb(d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			cb(d.left);
			cb(d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			cb(d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			cb(d.updateArg);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			cb(d.callee);
			let i = 0;
			while (i < d.arguments.length) {
				cb(d.arguments[i]);
				i += 1;
			}
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			cb(d.object);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			cb(d.array);
			cb(d.index);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				cb(d.properties[i]);
				i += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				cb(d.elements[i]);
				i += 1;
			}
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			cb(d.ternaryCondition);
			cb(d.ternaryConsequent);
			cb(d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			cb(d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			cb(d.newCallee);
			let i = 0;
			while (i < d.newArguments.length) {
				cb(d.newArguments[i]);
				i += 1;
			}
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			cb(d.tryArg);
			if (d.hasCatch) { cb(d.catchVal); }
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			cb(d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			cb(d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			cb(d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			cb(d.outArg);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			cb(d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			cb(d.convExpr);
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			cb(d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			cb(d.destrPattern);
			cb(d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d = node.data as QuoteExprData;
			cb(d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d = node.data as ComptimeBlockData;
			cb(d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				cb(d.macroArgs[i]);
				i += 1;
			}
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			cb(d.testBody);
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			cb(d.assertExpr);
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			let i = 0;
			while (i < d.actorBody.length) {
				cb(d.actorBody[i]);
				i += 1;
			}
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			if (d.propInitializer !== null) { cb(d.propInitializer); }
		},
		NodeKind.ArrayPattern => {
			const d = node.data as ArrayPatternData;
			let i = 0;
			while (i < d.patternElements.length) {
				cb(d.patternElements[i]);
				i += 1;
			}
		},
		NodeKind.ObjectPattern => {
			const d = node.data as ObjectPatternData;
			let i = 0;
			while (i < d.patternProps.length) {
				cb(d.patternProps[i]);
				i += 1;
			}
		},
		NodeKind.ObjectPatternProp => {
			const d = node.data as ObjectPatternPropData;
			if (d.propAlias !== null) { cb(d.propAlias); }
		},
		NodeKind.TypeGeneric => {
			const d = node.data as TypeGenericData;
			cb(d.typExprBase);
			let i = 0;
			while (i < d.typExprArgs.length) {
				cb(d.typExprArgs[i]);
				i += 1;
			}
		},
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			cb(d.typExprElement);
		},
		NodeKind.TypeUnion => {
			const d = node.data as TypeUnionData;
			let i = 0;
			while (i < d.typExprMembers.length) {
				cb(d.typExprMembers[i]);
				i += 1;
			}
		},
		NodeKind.TypeFunction => {
			const d = node.data as TypeFunctionData;
			let i = 0;
			while (i < d.typExprParams.length) {
				cb(d.typExprParams[i]);
				i += 1;
			}
			if (d.typExprReturn !== null) { cb(d.typExprReturn); }
		},
		NodeKind.TypeObject => {
			const d = node.data as TypeObjectData;
			let i = 0;
			while (i < d.typExprFieldTypes.length) {
				cb(d.typExprFieldTypes[i]);
				i += 1;
			}
		},
		// Genuine leaves (no Node children). Listed explicitly (not via `_`) so
		// adding a new NodeKind forces an exhaustiveness error here, preventing
		// the silent-gap class of bugs that bit replaceTypeVars.
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral
			| NodeKind.Identifier | NodeKind.TypeAnnotation | NodeKind.SizeofExpr
			| NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt
			| NodeKind.ImportDecl | NodeKind.TypeAliasDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ExternDecl => {},
	};
}
