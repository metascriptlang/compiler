// AST Walker — recursive traversal for transforms
// Two modes: walkNode (1:1 visitor) and walkBlockExpanding (1:N statement expansion)

import {
	Node, NodeKind,
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData,
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
	MacroInvocationData, TestDeclData, AssertStmtData, PropertyDeclData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData,
	SpliceManyData,
	JSXElementData, JSXFragmentData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, ComputedPropertyData,
} from "../ast/node";
import { TransformContext } from "./context";
import { makeBlock } from "./util";
import { forEachChild } from "../ast/visitor";

// Visitor function: takes a node, returns replacement (or same node if unchanged)
type Visitor = (node: Node) => Node;

// Expanding visitor: takes a statement, returns array of replacement statements
type ExpandingVisitor = (node: Node) => Node[];

// ===== 1:1 Walk =====
// Bottom-up: recurse into children first, then apply visitor to the node itself

export function walkNode(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	// Recurse into children first (bottom-up)
	walkChildren(node, visitor);
	// Then let visitor transform this node
	return visitor(node);
}

// Apply f to all child nodes of a given node (mutates in place).
// Core dispatch used by walkChildren, and directly by bounded walkers
// that stop at function boundaries.
// SYNC: forEachChild in ast/visitor.ms must handle the same NodeKinds (read-only variant).
export function mapChildren(node: Node, f: Visitor): void {
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d: Cursor<ProgramData> = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				d.programStmts[i] = f(d.programStmts[i]);
				i += 1;
			}
		},
		// SpliceMany — A2 macro multi-decl emission
		NodeKind.SpliceMany => {
			const d: Cursor<SpliceManyData> = node.data as SpliceManyData;
			let i = 0;
			for (const child of d.spliceNodes) {
				d.spliceNodes[i] = f(child);
				i += 1;
			}
		},
		// Block
		NodeKind.BlockStmt => {
			const d: Cursor<BlockStmtData> = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				d.statements[i] = f(d.statements[i]);
				i += 1;
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d: Cursor<IfStmtData> = node.data as IfStmtData;
			d.condition = f(d.condition);
			d.consequent = f(d.consequent);
			d.alternate = f(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d: Cursor<WhileStmtData> = node.data as WhileStmtData;
			d.whileCondition = f(d.whileCondition);
			d.whileBody = f(d.whileBody);
		},
		NodeKind.ForStmt => {
			const d: Cursor<ForStmtData> = node.data as ForStmtData;
			d.forInit = f(d.forInit);
			d.forCondition = f(d.forCondition);
			d.forUpdate = f(d.forUpdate);
			d.forBody = f(d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d: Cursor<ForOfStmtData> = node.data as ForOfStmtData;
			d.forOfIterable = f(d.forOfIterable);
			d.forOfBody = f(d.forOfBody);
			if (d.forOfPattern != null) { d.forOfPattern = f(d.forOfPattern); }
		},
		NodeKind.ForInStmt => {
			const d: Cursor<ForInStmtData> = node.data as ForInStmtData;
			d.forInObject = f(d.forInObject);
			d.forInBody = f(d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d: Cursor<DoWhileStmtData> = node.data as DoWhileStmtData;
			d.doBody = f(d.doBody);
			d.doCondition = f(d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d: Cursor<SwitchStmtData> = node.data as SwitchStmtData;
			d.switchDisc = f(d.switchDisc);
			let i = 0;
			while (i < d.switchCases.length) {
				d.switchCases[i] = f(d.switchCases[i]);
				i += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d: Cursor<SwitchCaseData> = node.data as SwitchCaseData;
			let i = 0;
			while (i < d.caseTests.length) {
				d.caseTests[i] = f(d.caseTests[i]);
				i += 1;
			}
			let j = 0;
			while (j < d.caseStmts.length) {
				d.caseStmts[j] = f(d.caseStmts[j]);
				j += 1;
			}
		},
		NodeKind.MatchStmt => {
			const d: Cursor<MatchStmtData> = node.data as MatchStmtData;
			d.matchStmtDisc = f(d.matchStmtDisc);
			let i = 0;
			while (i < d.matchStmtCases.length) {
				d.matchStmtCases[i] = f(d.matchStmtCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchExpr => {
			const d: Cursor<MatchExprData> = node.data as MatchExprData;
			d.matchDisc = f(d.matchDisc);
			let i = 0;
			while (i < d.matchCases.length) {
				d.matchCases[i] = f(d.matchCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchCase => {
			const d: Cursor<MatchCaseData> = node.data as MatchCaseData;
			let i = 0;
			while (i < d.casePatterns.length) {
				d.casePatterns[i] = f(d.casePatterns[i]);
				i += 1;
			}
			if (d.caseGuard != null) { d.caseGuard = f(d.caseGuard); }
			d.caseBody = f(d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d: Cursor<FunctionDeclData> = node.data as FunctionDeclData;
			d.fnBody = f(d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d: Cursor<ArrowFunctionData> = node.data as ArrowFunctionData;
			d.arrowBody = f(d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d: Cursor<FunctionExprData> = node.data as FunctionExprData;
			d.funcExprBody = f(d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d: Cursor<ClassDeclData> = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				d.classBody[i] = f(d.classBody[i]);
				i += 1;
			}
		},
		NodeKind.ActorDecl => {
			const d: Cursor<ActorDeclData> = node.data as ActorDeclData;
			let i = 0;
			while (i < d.actorBody.length) {
				d.actorBody[i] = f(d.actorBody[i]);
				i += 1;
			}
		},
		NodeKind.MethodDecl => {
			const d: Cursor<MethodDeclData> = node.data as MethodDeclData;
			d.methodBody = f(d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d: Cursor<ConstructorDeclData> = node.data as ConstructorDeclData;
			d.ctorBody = f(d.ctorBody);
		},
		NodeKind.ExportDecl => {
			const d: Cursor<ExportDeclData> = node.data as ExportDeclData;
			d.exportedDecl = f(d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d: Cursor<DecoratedDeclData> = node.data as DecoratedDeclData;
			d.decoratedNode = f(d.decoratedNode);
		},
		NodeKind.MacroDecl => {
			const d: Cursor<MacroDeclData> = node.data as MacroDeclData;
			d.macroDeclBody = f(d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d: Cursor<VariableDeclData> = node.data as VariableDeclData;
			if (d.initializer != null) d.initializer = f(d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d: Cursor<ReturnStmtData> = node.data as ReturnStmtData;
			d.argument = f(d.argument!);
		},
		NodeKind.ThrowStmt => {
			const d: Cursor<ThrowStmtData> = node.data as ThrowStmtData;
			d.throwArg = f(d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d: Cursor<ExprStmtData> = node.data as ExprStmtData;
			d.expr = f(d.expr);
		},
		NodeKind.DeferStmt => {
			const d: Cursor<DeferStmtData> = node.data as DeferStmtData;
			d.deferExpr = f(d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d: Cursor<TryCatchStmtData> = node.data as TryCatchStmtData;
			d.tryBody = f(d.tryBody);
			d.catchBody = f(d.catchBody);
			d.finallyBody = f(d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d: Cursor<BinaryExprData> = node.data as BinaryExprData;
			d.left = f(d.left);
			d.right = f(d.right);
		},
		NodeKind.UnaryExpr => {
			const d: Cursor<UnaryExprData> = node.data as UnaryExprData;
			d.operand = f(d.operand);
		},
		NodeKind.UpdateExpr => {
			const d: Cursor<UpdateExprData> = node.data as UpdateExprData;
			d.updateArg = f(d.updateArg);
		},
		NodeKind.CallExpr => {
			const d: Cursor<CallExprData> = node.data as CallExprData;
			d.callee = f(d.callee);
			let i = 0;
			while (i < d.arguments.length) {
				d.arguments[i] = f(d.arguments[i]);
				i += 1;
			}
		},
		NodeKind.MemberExpr => {
			const d: Cursor<MemberExprData> = node.data as MemberExprData;
			d.object = f(d.object);
		},
		NodeKind.ArrayAccess => {
			const d: Cursor<ArrayAccessData> = node.data as ArrayAccessData;
			d.array = f(d.array);
			d.index = f(d.index);
		},
		NodeKind.ObjectLiteral => {
			const d: Cursor<ObjectLiteralData> = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				d.properties[i] = f(d.properties[i]);
				i += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const d: Cursor<ArrayLiteralData> = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				d.elements[i] = f(d.elements[i]);
				i += 1;
			}
		},
		NodeKind.ConditionalExpr => {
			const d: Cursor<ConditionalExprData> = node.data as ConditionalExprData;
			d.ternaryCondition = f(d.ternaryCondition);
			d.ternaryConsequent = f(d.ternaryConsequent);
			d.ternaryAlternate = f(d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d: Cursor<SpreadExprData> = node.data as SpreadExprData;
			d.spreadArg = f(d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d: Cursor<NewExprData> = node.data as NewExprData;
			d.newCallee = f(d.newCallee);
			let i = 0;
			while (i < d.newArguments.length) {
				d.newArguments[i] = f(d.newArguments[i]);
				i += 1;
			}
		},
		NodeKind.TryExpr => {
			const d: Cursor<TryExprData> = node.data as TryExprData;
			d.tryArg = f(d.tryArg);
			if (d.hasCatch) { d.catchVal = f(d.catchVal); }
		},
		NodeKind.AwaitExpr => {
			const d: Cursor<AwaitExprData> = node.data as AwaitExprData;
			d.awaitArg = f(d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d: Cursor<YieldExprData> = node.data as YieldExprData;
			d.yieldArg = f(d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d: Cursor<MoveExprData> = node.data as MoveExprData;
			d.moveArg = f(d.moveArg);
		},
		NodeKind.OutExpr => {
			const d: Cursor<OutExprData> = node.data as OutExprData;
			d.outArg = f(d.outArg);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d: Cursor<HiddenDerefData> = node.data as HiddenDerefData;
			d.expr = f(d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d: Cursor<HiddenStdConvData> = node.data as HiddenStdConvData;
			d.convExpr = f(d.convExpr);
		},
		NodeKind.TypeAssertion => {
			const d: Cursor<TypeAssertionData> = node.data as TypeAssertionData;
			d.asExpr = f(d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d: Cursor<DestructuringDeclData> = node.data as DestructuringDeclData;
			d.destrPattern = f(d.destrPattern);
			d.destrInit = f(d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d: Cursor<QuoteExprData> = node.data as QuoteExprData;
			d.quoteBody = f(d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d: Cursor<ComptimeBlockData> = node.data as ComptimeBlockData;
			d.comptimeBody = f(d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d: Cursor<MacroInvocationData> = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				d.macroArgs[i] = f(d.macroArgs[i]);
				i += 1;
			}
		},
		NodeKind.TestDecl => {
			const d: Cursor<TestDeclData> = node.data as TestDeclData;
			d.testBody = f(d.testBody);
		},
		NodeKind.AssertStmt => {
			const d: Cursor<AssertStmtData> = node.data as AssertStmtData;
			d.assertExpr = f(d.assertExpr);
			if (d.assertMessageExpr != null) { d.assertMessageExpr = f(d.assertMessageExpr); }
		},
		NodeKind.PropertyDecl => {
			const d: Cursor<PropertyDeclData> = node.data as PropertyDeclData;
			if (d.propInitializer != null) { d.propInitializer = f(d.propInitializer); }
		},
		NodeKind.ArrayPattern => {
			const d: Cursor<ArrayPatternData> = node.data as ArrayPatternData;
			let i = 0;
			while (i < d.patternElements.length) {
				d.patternElements[i] = f(d.patternElements[i]);
				i += 1;
			}
			i = 0;
			while (i < d.patternDefaults.length) {
				if (d.patternDefaults[i] != null) { d.patternDefaults[i] = f(d.patternDefaults[i]); }
				i += 1;
			}
		},
		NodeKind.ObjectPattern => {
			const d: Cursor<ObjectPatternData> = node.data as ObjectPatternData;
			let i = 0;
			while (i < d.patternProps.length) {
				d.patternProps[i] = f(d.patternProps[i]);
				i += 1;
			}
		},
		NodeKind.ObjectPatternProp => {
			const d: Cursor<ObjectPatternPropData> = node.data as ObjectPatternPropData;
			if (d.propAlias != null) { d.propAlias = f(d.propAlias); }
			if (d.propDefault != null) { d.propDefault = f(d.propDefault); }
		},
		NodeKind.TypeGeneric => {
			const d: Cursor<TypeGenericData> = node.data as TypeGenericData;
			d.typExprBase = f(d.typExprBase);
			let i = 0;
			while (i < d.typExprArgs.length) {
				d.typExprArgs[i] = f(d.typExprArgs[i]);
				i += 1;
			}
		},
		NodeKind.TypeArray => {
			const d: Cursor<TypeArrayData> = node.data as TypeArrayData;
			d.typExprElement = f(d.typExprElement);
		},
		NodeKind.TypeUnion => {
			const d: Cursor<TypeUnionData> = node.data as TypeUnionData;
			let i = 0;
			while (i < d.typExprMembers.length) {
				d.typExprMembers[i] = f(d.typExprMembers[i]);
				i += 1;
			}
		},
		NodeKind.TypeIntersection => {
			const d: Cursor<TypeIntersectionData> = node.data as TypeIntersectionData;
			for (let i = 0; i < d.typExprMembers.length; i += 1) {
				d.typExprMembers[i] = f(d.typExprMembers[i]);
			}
		},
		NodeKind.TypeFunction => {
			const d: Cursor<TypeFunctionData> = node.data as TypeFunctionData;
			let i = 0;
			while (i < d.typExprParams.length) {
				d.typExprParams[i] = f(d.typExprParams[i]);
				i += 1;
			}
			if (d.typExprReturn != null) { d.typExprReturn = f(d.typExprReturn); }
		},
		NodeKind.TypeObject => {
			const d: Cursor<TypeObjectData> = node.data as TypeObjectData;
			let i = 0;
			while (i < d.typExprFieldTypes.length) {
				d.typExprFieldTypes[i] = f(d.typExprFieldTypes[i]);
				i += 1;
			}
			if (d.typExprIndexKey != null) { d.typExprIndexKey = f(d.typExprIndexKey); }
			if (d.typExprIndexValue != null) { d.typExprIndexValue = f(d.typExprIndexValue); }
			// Per-field decorators (V2): walk each decorator node in place
			let di = 0;
			while (di < d.typExprFieldDecorators.length) {
				const decs = d.typExprFieldDecorators[di];
				let dj = 0;
				while (dj < decs.length) {
					decs[dj] = f(decs[dj]);
					dj += 1;
				}
				di += 1;
			}
		},
		NodeKind.JSXElement => {
			const d: Cursor<JSXElementData> = node.data as JSXElementData;
			let i = 0;
			while (i < d.jsxAttrs.length) { d.jsxAttrs[i] = f(d.jsxAttrs[i]); i += 1; }
			let j = 0;
			while (j < d.jsxChildren.length) { d.jsxChildren[j] = f(d.jsxChildren[j]); j += 1; }
		},
		NodeKind.JSXFragment => {
			const d: Cursor<JSXFragmentData> = node.data as JSXFragmentData;
			let i = 0;
			while (i < d.jsxFragChildren.length) { d.jsxFragChildren[i] = f(d.jsxFragChildren[i]); i += 1; }
		},
		NodeKind.JSXExpressionContainer => {
			const d: Cursor<JSXExpressionContainerData> = node.data as JSXExpressionContainerData;
			d.jsxExpr = f(d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d: Cursor<JSXAttributeData> = node.data as JSXAttributeData;
			d.jsxAttrValue = f(d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d: Cursor<JSXSpreadAttributeData> = node.data as JSXSpreadAttributeData;
			d.jsxSpreadArg = f(d.jsxSpreadArg);
		},
		NodeKind.ComputedProperty => {
			const d: Cursor<ComputedPropertyData> = node.data as ComputedPropertyData;
			d.computedKey = f(d.computedKey);
			d.computedValue = f(d.computedValue);
		},
		// Genuine leaves (no Node children). Listed explicitly (not via `_`) so
		// adding a new NodeKind forces an exhaustiveness error here — keeping
		// this walker in sync with the AST by construction.
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral
			| NodeKind.Identifier | NodeKind.TypeAnnotation | NodeKind.SizeofExpr
			| NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt
			| NodeKind.ImportDecl | NodeKind.TypeAliasDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ExternDecl
			| NodeKind.JSXText => {},
	};
}

// Recurse into all child nodes using bottom-up walkNode traversal
export function walkChildren(node: Node, visitor: Visitor): void {
	const walk = (child: Node): Node => {
		if (child == null) return null as unknown as Node;
		mapChildren(child, walk);
		return visitor(child);
	};
	mapChildren(node, walk);
}

export function walkWithinStatement(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	if (opensStatementScope(node)) return node;
	const walk = (child: Node): Node => {
		if (child == null || opensStatementScope(child)) return child;
		mapChildren(child, walk);
		return visitor(child);
	};
	mapChildren(node, walk);
	return visitor(node);
}

function opensStatementScope(node: Node): boolean {
	return isFuncBoundary(node) || node.kind == NodeKind.BlockStmt || node.kind == NodeKind.SwitchCase
		|| node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl
		|| node.kind == NodeKind.ActorDecl || isInstanceFieldInit(node);
}

export function walkOutsideInstanceFieldInits(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	if (isInstanceFieldInit(node)) return node;
	const walk = (child: Node): Node => {
		if (child == null || isInstanceFieldInit(child)) return child;
		mapChildren(child, walk);
		return visitor(child);
	};
	mapChildren(node, walk);
	return visitor(node);
}

export function isInstanceFieldInit(node: Node): boolean {
	return node.kind == NodeKind.PropertyDecl && !(node.data as PropertyDeclData).propIsStatic;
}

// Check if a node is a function boundary (FunctionDecl, ArrowFunction, FunctionExpr)
export function isFuncBoundary(node: Node): boolean {
	return node.kind == NodeKind.FunctionDecl ||
		node.kind == NodeKind.ArrowFunction ||
		node.kind == NodeKind.FunctionExpr;
}

function isEffectNode(n: Node): boolean {
	if (n.kind == NodeKind.CallExpr || n.kind == NodeKind.NewExpr || n.kind == NodeKind.UpdateExpr
		|| n.kind == NodeKind.AwaitExpr || n.kind == NodeKind.YieldExpr || n.kind == NodeKind.OutExpr) return true;
	return n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator);
}

export function isAssignOp(op: string): boolean {
	if (op == "==" || op == "!=" || op == "===" || op == "!==" || op == "<=" || op == ">=") return false;
	return op.endsWith("=");
}

export function hasEffect(n: Node): boolean {
	if (n == null || isFuncBoundary(n)) return false;
	if (isEffectNode(n)) return true;
	let found = false;
	const scan = (c: Node): void => {
		if (found || c == null || isFuncBoundary(c)) return;
		if (isEffectNode(c)) { found = true; return; }
		forEachChild(c, scan);
	};
	forEachChild(n, scan);
	return found;
}

export const DEEP_DESCEND = 0;
export const DEEP_HIT = 1;
export const DEEP_SKIP = 2;

// Does any node in the subtree answer DEEP_HIT? A null node and a DEEP_SKIP subtree are not
// entered. One closure serves the whole search, where a recursive predicate builds one per node.
export function anyDeep(n: Node, verdict: (n: Node) => int32): boolean {
	let found = false;
	const scan = (c: Node): void => {
		if (found || c == null) return;
		const v = verdict(c);
		if (v == DEEP_HIT) { found = true; return; }
		if (v == DEEP_SKIP) return;
		forEachChild(c, scan);
	};
	scan(n);
	return found;
}

export interface OnceEvalState {
	effectSeen: boolean;
}

export type OnceEvalVisitor = (node: Node, effectBefore: boolean) => void;

export function walkOnceEvaluated(node: Node, st: OnceEvalState, visit: OnceEvalVisitor): void {
	const step = (c: Node): void => onceWalk(c, st, visit, step);
	onceWalk(node, st, visit, step);
}

function onceWalk(node: Node, st: OnceEvalState, visit: OnceEvalVisitor, step: (c: Node) => void): void {
	if (node == null || isFuncBoundary(node)) return;
	const k = node.kind;
	if (k == NodeKind.BlockStmt || k == NodeKind.MethodDecl || k == NodeKind.ClassDecl || k == NodeKind.ActorDecl
		|| k == NodeKind.SwitchCase || k == NodeKind.MatchCase
		|| k == NodeKind.WhileStmt || k == NodeKind.DoWhileStmt) return;
	if (k == NodeKind.ForStmt) {
		onceWalk((node.data as ForStmtData).forInit, st, visit, step);
		return;
	}
	if (k == NodeKind.IfStmt) {
		onceWalk((node.data as IfStmtData).condition, st, visit, step);
		return;
	}
	if (k == NodeKind.ConditionalExpr) {
		const cd = node.data as ConditionalExprData;
		onceWalk(cd.ternaryCondition, st, visit, step);
		if (hasEffect(cd.ternaryConsequent) || hasEffect(cd.ternaryAlternate)) st.effectSeen = true;
		return;
	}
	if (k == NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		if (bd.operator == "&&" || bd.operator == "||") {
			onceWalk(bd.left, st, visit, step);
			if (hasEffect(bd.right)) st.effectSeen = true;
			return;
		}
		if (bd.operator == "=" && (bd.left.kind == NodeKind.ArrayLiteral || bd.left.kind == NodeKind.ObjectLiteral)) {
			onceWalk(bd.right, st, visit, step);
			st.effectSeen = true;
			return;
		}
	}
	const effectBefore = st.effectSeen;
	forEachChild(node, step);
	visit(node, effectBefore);
	if (isEffectNode(node)) st.effectSeen = true;
}

// ===== 1:N Block Expansion =====
// Walks a statement list, allowing each statement to expand into multiple statements.
// The expanding visitor returns Node[] for each input statement.

export function walkBlockExpanding(stmts: Node[], expander: ExpandingVisitor): Node[] {
	const result: Node[] = [];
	for (const stmt of stmts) {
		const expanded = expander(stmt);
		for (const node of expanded) {
			result.push(node);
		}
	}
	return result;
}

// ===== Block-Expanding Walk =====
// Shared walker for transforms that expand statement lists (1:N).
// Used by matchLower and resultDesugar — both walk the same node kinds,
// expanding Program/BlockStmt stmt lists and recursing into function bodies.

type StmtExpander = (stmt: Node, ctx: TransformContext) => Node[];

class ExpandWalk {
	expander: StmtExpander;
	ctx: TransformContext;
	onFnEntry: FnEntryHook;
	onFnExit: FnExitHook;
}

// Optional hook called on function-like node entry/exit.
// onEntry receives the function node, returns opaque state to restore on exit.
// Used by resultDesugar to track enclosing function return types.
export type FnEntryHook = (node: Node) => void;
export type FnExitHook = (node: Node) => void;

// Helpers to replace statement arrays in-place without value-copy aliasing.
// In C backend, `const d = node.data as X; d.field = y;` modifies a VALUE COPY,
// not the original node. These helpers take the node, extract old stmts, compute
// new stmts, and write back via node.data = {...} in a single scope where the
// return value is directly consumed (no local for DRC to destroy).
function replaceProgStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const pd = node.data as ProgramData;
	node.data = { programStmts: expandStmtList(pd.programStmts, w, visit) };
}

function replaceBlockStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const bd = node.data as BlockStmtData;
	node.data = { statements: expandStmtList(bd.statements, w, visit) };
}

function replaceCaseStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const cd = node.data as SwitchCaseData;
	node.data = { caseTests: cd.caseTests, caseStmts: expandStmtList(cd.caseStmts, w, visit), isDefault: cd.isDefault };
}

let expandTryDepth = 0;

export function expandingInsideTry(): boolean {
	return expandTryDepth > 0;
}

function walkFnBodyHooked(body: Node, w: ExpandWalk, visit: Visitor): void {
	const outerTryDepth = expandTryDepth;
	expandTryDepth = 0;
	expandWalk(body, w, visit);
	expandTryDepth = outerTryDepth;
}

function expandStmtBodyHooked(node: Node, w: ExpandWalk, visit: Visitor): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.BlockStmt) {
		expandWalk(node, w, visit);
		return node;
	}
	const expanded = w.expander(node, w.ctx);
	for (const stmt of expanded) {
		expandWalk(stmt, w, visit);
	}
	if (expanded.length == 1) return expanded[0];
	return makeBlock(expanded, node.location);
}

export function walkExpandBlocks(node: Node, expander: StmtExpander, ctx: TransformContext): void {
	walkExpandBlocksHooked(node, expander, ctx, null as unknown as FnEntryHook, null as unknown as FnExitHook);
}

// One visitor per walk: the default arm hands it to mapChildren for every node it does not
// special-case, so it is built once here and not once per node.
export function walkExpandBlocksHooked(node: Node, expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): void {
	const w: ExpandWalk = { expander, ctx, onFnEntry, onFnExit };
	const visit = (child: Node): Node => {
		expandWalk(child, w, visit);
		return child;
	};
	expandWalk(node, w, visit);
}

function expandWalk(node: Node, w: ExpandWalk, visit: Visitor): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Program => {
			replaceProgStmts(node, w, visit);
		},
		NodeKind.BlockStmt => {
			replaceBlockStmts(node, w, visit);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.fnBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.arrowBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.funcExprBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.methodBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkFnBodyHooked(d.ctorBody, w, visit);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			expandWalk(d.exportedDecl, w, visit);
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			walkFnBodyHooked(d.testBody, w, visit);
		},
		NodeKind.AssertStmt => {},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.consequent = expandStmtBodyHooked(d.consequent, w, visit);
			d.alternate = expandStmtBodyHooked(d.alternate, w, visit);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileBody = expandStmtBodyHooked(d.whileBody, w, visit);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doBody = expandStmtBodyHooked(d.doBody, w, visit);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			d.forBody = expandStmtBodyHooked(d.forBody, w, visit);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfBody = expandStmtBodyHooked(d.forOfBody, w, visit);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			d.forInBody = expandStmtBodyHooked(d.forInBody, w, visit);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			expandTryDepth += 1;
			expandWalk(d.tryBody, w, visit);
			expandWalk(d.catchBody, w, visit);
			expandWalk(d.finallyBody, w, visit);
			expandTryDepth -= 1;
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			let i = 0;
			while (i < d.switchCases.length) {
				expandWalk(d.switchCases[i], w, visit);
				i = i + 1;
			}
		},
		NodeKind.SwitchCase => {
			replaceCaseStmts(node, w, visit);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			expandWalk(d.decoratedNode, w, visit);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				expandWalk(d.classBody[i], w, visit);
				i = i + 1;
			}
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			let i = 0;
			while (i < d.actorBody.length) {
				expandWalk(d.actorBody[i], w, visit);
				i = i + 1;
			}
		},
		_ => {
			mapChildren(node, visit);
		},
	};
}

// ===== Expression-Level Utilities =====
// Shared by resultDesugar (TryExpr hoisting) and matchLower (MatchExpr hoisting).
// Only walks expression-level children — does NOT recurse into function bodies,
// block statements, or match case arms.

export function mapExprChildren(node: Node, f: Visitor): void {
	match (node.kind) {
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = f(d.callee);
			let i = 0;
			while (i < d.arguments.length) { d.arguments[i] = f(d.arguments[i]); i += 1; }
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = f(d.left);
			d.right = f(d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = f(d.operand);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			d.object = f(d.object);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			d.array = f(d.array);
			d.index = f(d.index);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = f(d.ternaryCondition);
			d.ternaryConsequent = f(d.ternaryConsequent);
			d.ternaryAlternate = f(d.ternaryAlternate);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) { d.properties[i] = f(d.properties[i]); i += 1; }
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) { d.elements[i] = f(d.elements[i]); i += 1; }
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			d.spreadArg = f(d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			d.newCallee = f(d.newCallee);
			let i = 0;
			while (i < d.newArguments.length) { d.newArguments[i] = f(d.newArguments[i]); i += 1; }
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			d.tryArg = f(d.tryArg);
			if (d.hasCatch) { d.catchVal = f(d.catchVal); }
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = f(d.matchDisc);
			// Don't recurse into matchCases — they're statement-level
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			d.asExpr = f(d.asExpr);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			d.expr = f(d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			d.convExpr = f(d.convExpr);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			d.updateArg = f(d.updateArg);
		},
		_ => {},
	};
}

// Check if any node in an expression tree has the given NodeKind.
export function containsExprKind(node: Node, kind: NodeKind): boolean {
	if (node == null) return false;
	if (node.kind == kind) return true;
	let found = false;
	const scan = (child: Node): Node => {
		if (found || child == null) return child;
		if (child.kind == kind) { found = true; return child; }
		mapExprChildren(child, scan);
		return child;
	};
	mapExprChildren(node, scan);
	return found;
}

// Bottom-up expression tree walk: recurse into children first, then apply replacer.
// If replacer returns a different node, use it as the replacement.
export function replaceInExpr(node: Node, replacer: Visitor): Node {
	if (node == null) return node;
	const walk = (child: Node): Node => {
		if (child == null) return child;
		mapExprChildren(child, walk);
		return replacer(child);
	};
	mapExprChildren(node, walk);
	return replacer(node);
}

function expandStmtList(stmts: Node[], w: ExpandWalk, visit: Visitor): Node[] {
	const result: Node[] = [];
	for (const stmt of stmts) {
		const expanded = w.expander(stmt, w.ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	for (const node of result) {
		expandWalk(node, w, visit);
	}
	return result;
}
