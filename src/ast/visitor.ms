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
	TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData,
	SpliceManyData,
	JSXElementData, JSXFragmentData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, ComputedPropertyData,
} from "./node";

type ChildVisitor = (child: Node) => void;

export function literalHeldClosures(init: Node, out: Node[]): void {
	if (init.kind == NodeKind.ArrowFunction || init.kind == NodeKind.FunctionExpr) {
		out.push(init);
	} else if (init.kind == NodeKind.ObjectLiteral) {
		for (const p of (init.data as ObjectLiteralData).properties) literalHeldClosures(p, out);
	} else if (init.kind == NodeKind.ArrayLiteral) {
		for (const e of (init.data as ArrayLiteralData).elements) literalHeldClosures(e, out);
	}
}

export function initializerHoldsClosure(init: Node | null): boolean {
	if (init == null) return false;
	const held: Node[] = [];
	literalHeldClosures(init, held);
	return held.length > 0;
}

// Visit all child nodes of a given node (read-only, no mutation).
function visitChild(cb: ChildVisitor, n: Node): void {
	if (n != null) cb(n);
}

export function forEachChild(node: Node, cb: ChildVisitor): void {
	if (node == null) return;
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d: Cursor<ProgramData> = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				visitChild(cb, d.programStmts[i]);
				i += 1;
			}
		},
		// SpliceMany — A2 macro multi-decl emission
		NodeKind.SpliceMany => {
			const d: Cursor<SpliceManyData> = node.data as SpliceManyData;
			for (const child of d.spliceNodes) visitChild(cb, child);
		},
		// Block
		NodeKind.BlockStmt => {
			const d: Cursor<BlockStmtData> = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				visitChild(cb, d.statements[i]);
				i += 1;
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d: Cursor<IfStmtData> = node.data as IfStmtData;
			visitChild(cb, d.condition);
			visitChild(cb, d.consequent);
			visitChild(cb, d.alternate);
		},
		NodeKind.WhileStmt => {
			const d: Cursor<WhileStmtData> = node.data as WhileStmtData;
			visitChild(cb, d.whileCondition);
			visitChild(cb, d.whileBody);
		},
		NodeKind.ForStmt => {
			const d: Cursor<ForStmtData> = node.data as ForStmtData;
			visitChild(cb, d.forInit);
			visitChild(cb, d.forCondition);
			visitChild(cb, d.forUpdate);
			visitChild(cb, d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d: Cursor<ForOfStmtData> = node.data as ForOfStmtData;
			visitChild(cb, d.forOfIterable);
			visitChild(cb, d.forOfBody);
			if (d.forOfPattern != null) { visitChild(cb, d.forOfPattern); }
		},
		NodeKind.ForInStmt => {
			const d: Cursor<ForInStmtData> = node.data as ForInStmtData;
			visitChild(cb, d.forInObject);
			visitChild(cb, d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d: Cursor<DoWhileStmtData> = node.data as DoWhileStmtData;
			visitChild(cb, d.doBody);
			visitChild(cb, d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d: Cursor<SwitchStmtData> = node.data as SwitchStmtData;
			visitChild(cb, d.switchDisc);
			let i = 0;
			while (i < d.switchCases.length) {
				visitChild(cb, d.switchCases[i]);
				i += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d: Cursor<SwitchCaseData> = node.data as SwitchCaseData;
			let i = 0;
			while (i < d.caseTests.length) {
				visitChild(cb, d.caseTests[i]);
				i += 1;
			}
			let j = 0;
			while (j < d.caseStmts.length) {
				visitChild(cb, d.caseStmts[j]);
				j += 1;
			}
		},
		NodeKind.MatchStmt => {
			const d: Cursor<MatchStmtData> = node.data as MatchStmtData;
			visitChild(cb, d.matchStmtDisc);
			let i = 0;
			while (i < d.matchStmtCases.length) {
				visitChild(cb, d.matchStmtCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchExpr => {
			const d: Cursor<MatchExprData> = node.data as MatchExprData;
			visitChild(cb, d.matchDisc);
			let i = 0;
			while (i < d.matchCases.length) {
				visitChild(cb, d.matchCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchCase => {
			const d: Cursor<MatchCaseData> = node.data as MatchCaseData;
			let i = 0;
			while (i < d.casePatterns.length) {
				visitChild(cb, d.casePatterns[i]);
				i += 1;
			}
			if (d.caseGuard != null) { visitChild(cb, d.caseGuard); }
			visitChild(cb, d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d: Cursor<FunctionDeclData> = node.data as FunctionDeclData;
			visitChild(cb, d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d: Cursor<ArrowFunctionData> = node.data as ArrowFunctionData;
			visitChild(cb, d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d: Cursor<FunctionExprData> = node.data as FunctionExprData;
			visitChild(cb, d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d: Cursor<ClassDeclData> = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				visitChild(cb, d.classBody[i]);
				i += 1;
			}
		},
		NodeKind.MethodDecl => {
			const d: Cursor<MethodDeclData> = node.data as MethodDeclData;
			visitChild(cb, d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d: Cursor<ConstructorDeclData> = node.data as ConstructorDeclData;
			visitChild(cb, d.ctorBody);
		},
		NodeKind.ExportDecl => {
			const d: Cursor<ExportDeclData> = node.data as ExportDeclData;
			visitChild(cb, d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d: Cursor<DecoratedDeclData> = node.data as DecoratedDeclData;
			visitChild(cb, d.decoratedNode);
		},
		NodeKind.MacroDecl => {
			const d: Cursor<MacroDeclData> = node.data as MacroDeclData;
			visitChild(cb, d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d: Cursor<VariableDeclData> = node.data as VariableDeclData;
			visitChild(cb, d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d: Cursor<ReturnStmtData> = node.data as ReturnStmtData;
			visitChild(cb, d.argument!);
		},
		NodeKind.ThrowStmt => {
			const d: Cursor<ThrowStmtData> = node.data as ThrowStmtData;
			visitChild(cb, d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d: Cursor<ExprStmtData> = node.data as ExprStmtData;
			visitChild(cb, d.expr);
		},
		NodeKind.DeferStmt => {
			const d: Cursor<DeferStmtData> = node.data as DeferStmtData;
			visitChild(cb, d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d: Cursor<TryCatchStmtData> = node.data as TryCatchStmtData;
			visitChild(cb, d.tryBody);
			visitChild(cb, d.catchBody);
			visitChild(cb, d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d: Cursor<BinaryExprData> = node.data as BinaryExprData;
			visitChild(cb, d.left);
			visitChild(cb, d.right);
		},
		NodeKind.UnaryExpr => {
			const d: Cursor<UnaryExprData> = node.data as UnaryExprData;
			visitChild(cb, d.operand);
		},
		NodeKind.UpdateExpr => {
			const d: Cursor<UpdateExprData> = node.data as UpdateExprData;
			visitChild(cb, d.updateArg);
		},
		NodeKind.CallExpr => {
			const d: Cursor<CallExprData> = node.data as CallExprData;
			visitChild(cb, d.callee);
			let i = 0;
			while (i < d.arguments.length) {
				visitChild(cb, d.arguments[i]);
				i += 1;
			}
		},
		NodeKind.MemberExpr => {
			const d: Cursor<MemberExprData> = node.data as MemberExprData;
			visitChild(cb, d.object);
		},
		NodeKind.ArrayAccess => {
			const d: Cursor<ArrayAccessData> = node.data as ArrayAccessData;
			visitChild(cb, d.array);
			visitChild(cb, d.index);
		},
		NodeKind.ObjectLiteral => {
			const d: Cursor<ObjectLiteralData> = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				visitChild(cb, d.properties[i]);
				i += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const d: Cursor<ArrayLiteralData> = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				visitChild(cb, d.elements[i]);
				i += 1;
			}
		},
		NodeKind.ConditionalExpr => {
			const d: Cursor<ConditionalExprData> = node.data as ConditionalExprData;
			visitChild(cb, d.ternaryCondition);
			visitChild(cb, d.ternaryConsequent);
			visitChild(cb, d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d: Cursor<SpreadExprData> = node.data as SpreadExprData;
			visitChild(cb, d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d: Cursor<NewExprData> = node.data as NewExprData;
			visitChild(cb, d.newCallee);
			let i = 0;
			while (i < d.newArguments.length) {
				visitChild(cb, d.newArguments[i]);
				i += 1;
			}
		},
		NodeKind.TryExpr => {
			const d: Cursor<TryExprData> = node.data as TryExprData;
			visitChild(cb, d.tryArg);
			if (d.hasCatch) { visitChild(cb, d.catchVal); }
		},
		NodeKind.AwaitExpr => {
			const d: Cursor<AwaitExprData> = node.data as AwaitExprData;
			visitChild(cb, d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d: Cursor<YieldExprData> = node.data as YieldExprData;
			visitChild(cb, d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d: Cursor<MoveExprData> = node.data as MoveExprData;
			visitChild(cb, d.moveArg);
		},
		NodeKind.OutExpr => {
			const d: Cursor<OutExprData> = node.data as OutExprData;
			visitChild(cb, d.outArg);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d: Cursor<HiddenDerefData> = node.data as HiddenDerefData;
			visitChild(cb, d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d: Cursor<HiddenStdConvData> = node.data as HiddenStdConvData;
			visitChild(cb, d.convExpr);
		},
		NodeKind.TypeAssertion => {
			const d: Cursor<TypeAssertionData> = node.data as TypeAssertionData;
			visitChild(cb, d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d: Cursor<DestructuringDeclData> = node.data as DestructuringDeclData;
			visitChild(cb, d.destrPattern);
			visitChild(cb, d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d: Cursor<QuoteExprData> = node.data as QuoteExprData;
			visitChild(cb, d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d: Cursor<ComptimeBlockData> = node.data as ComptimeBlockData;
			visitChild(cb, d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d: Cursor<MacroInvocationData> = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				visitChild(cb, d.macroArgs[i]);
				i += 1;
			}
		},
		NodeKind.TestDecl => {
			const d: Cursor<TestDeclData> = node.data as TestDeclData;
			visitChild(cb, d.testBody);
		},
		NodeKind.AssertStmt => {
			const d: Cursor<AssertStmtData> = node.data as AssertStmtData;
			visitChild(cb, d.assertExpr);
			if (d.assertMessageExpr != null) visitChild(cb, d.assertMessageExpr);
		},
		NodeKind.ActorDecl => {
			const d: Cursor<ActorDeclData> = node.data as ActorDeclData;
			let i = 0;
			while (i < d.actorBody.length) {
				visitChild(cb, d.actorBody[i]);
				i += 1;
			}
		},
		NodeKind.PropertyDecl => {
			const d: Cursor<PropertyDeclData> = node.data as PropertyDeclData;
			if (d.propInitializer != null) { visitChild(cb, d.propInitializer); }
		},
		NodeKind.ArrayPattern => {
			const d: Cursor<ArrayPatternData> = node.data as ArrayPatternData;
			let i = 0;
			while (i < d.patternElements.length) {
				visitChild(cb, d.patternElements[i]);
				i += 1;
			}
			i = 0;
			while (i < d.patternDefaults.length) {
				if (d.patternDefaults[i] != null) { visitChild(cb, d.patternDefaults[i]); }
				i += 1;
			}
		},
		NodeKind.ObjectPattern => {
			const d: Cursor<ObjectPatternData> = node.data as ObjectPatternData;
			let i = 0;
			while (i < d.patternProps.length) {
				visitChild(cb, d.patternProps[i]);
				i += 1;
			}
		},
		NodeKind.ObjectPatternProp => {
			const d: Cursor<ObjectPatternPropData> = node.data as ObjectPatternPropData;
			if (d.propAlias != null) { visitChild(cb, d.propAlias); }
			if (d.propDefault != null) { visitChild(cb, d.propDefault); }
		},
		NodeKind.TypeGeneric => {
			const d: Cursor<TypeGenericData> = node.data as TypeGenericData;
			visitChild(cb, d.typExprBase);
			let i = 0;
			while (i < d.typExprArgs.length) {
				visitChild(cb, d.typExprArgs[i]);
				i += 1;
			}
		},
		NodeKind.TypeArray => {
			const d: Cursor<TypeArrayData> = node.data as TypeArrayData;
			visitChild(cb, d.typExprElement);
		},
		NodeKind.TypeUnion => {
			const d: Cursor<TypeUnionData> = node.data as TypeUnionData;
			let i = 0;
			while (i < d.typExprMembers.length) {
				visitChild(cb, d.typExprMembers[i]);
				i += 1;
			}
		},
		NodeKind.TypeIntersection => {
			const d: Cursor<TypeIntersectionData> = node.data as TypeIntersectionData;
			for (const member of d.typExprMembers) {
				visitChild(cb, member);
			}
		},
		NodeKind.TypeFunction => {
			const d: Cursor<TypeFunctionData> = node.data as TypeFunctionData;
			let i = 0;
			while (i < d.typExprParams.length) {
				visitChild(cb, d.typExprParams[i]);
				i += 1;
			}
			if (d.typExprReturn != null) { visitChild(cb, d.typExprReturn); }
		},
		NodeKind.TypeObject => {
			const d: Cursor<TypeObjectData> = node.data as TypeObjectData;
			let i = 0;
			while (i < d.typExprFieldTypes.length) {
				visitChild(cb, d.typExprFieldTypes[i]);
				i += 1;
			}
			if (d.typExprIndexKey != null) { visitChild(cb, d.typExprIndexKey); }
			if (d.typExprIndexValue != null) { visitChild(cb, d.typExprIndexValue); }
			// Per-field decorators (V2): each inner array holds 0+ decorator nodes
			let di = 0;
			while (di < d.typExprFieldDecorators.length) {
				const decs = d.typExprFieldDecorators[di];
				let dj = 0;
				while (dj < decs.length) {
					visitChild(cb, decs[dj]);
					dj += 1;
				}
				di += 1;
			}
		},
		NodeKind.JSXElement => {
			const d: Cursor<JSXElementData> = node.data as JSXElementData;
			for (const a of d.jsxAttrs) { visitChild(cb, a); }
			for (const c of d.jsxChildren) { visitChild(cb, c); }
		},
		NodeKind.JSXFragment => {
			const d: Cursor<JSXFragmentData> = node.data as JSXFragmentData;
			for (const c of d.jsxFragChildren) { visitChild(cb, c); }
		},
		NodeKind.JSXExpressionContainer => {
			const d: Cursor<JSXExpressionContainerData> = node.data as JSXExpressionContainerData;
			visitChild(cb, d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d: Cursor<JSXAttributeData> = node.data as JSXAttributeData;
			visitChild(cb, d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d: Cursor<JSXSpreadAttributeData> = node.data as JSXSpreadAttributeData;
			visitChild(cb, d.jsxSpreadArg);
		},
		NodeKind.ComputedProperty => {
			const d: Cursor<ComputedPropertyData> = node.data as ComputedPropertyData;
			visitChild(cb, d.computedKey);
			visitChild(cb, d.computedValue);
		},
		// Genuine leaves (no Node children). Listed explicitly (not via `_`) so
		// adding a new NodeKind forces an exhaustiveness error here, preventing
		// the silent-gap class of bugs that bit replaceTypeVars.
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral
			| NodeKind.Identifier | NodeKind.TypeAnnotation | NodeKind.SizeofExpr
			| NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt
			| NodeKind.ImportDecl | NodeKind.TypeAliasDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ExternDecl
			| NodeKind.JSXText => {},
	};
}
