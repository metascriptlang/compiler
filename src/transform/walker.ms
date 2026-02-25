// AST Walker — recursive traversal for transforms
// Two modes: walkNode (1:1 visitor) and walkBlockExpanding (1:N statement expansion)

import {
	Node, NodeKind,
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, DecoratedDeclData, MacroDeclData,
	VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData,
	TryCatchStmtData, DeferStmtData,
	BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchStmtData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	TypeAssertionData, DestructuringDeclData, QuoteExprData,
	MacroInvocationData,
} from "../ast/node";
import { TransformContext } from "./context";

// Visitor function: takes a node, returns replacement (or same node if unchanged)
type Visitor = (node: Node) => Node;

// Expanding visitor: takes a statement, returns array of replacement statements
type ExpandingVisitor = (node: Node) => Node[];

// ===== 1:1 Walk =====
// Bottom-up: recurse into children first, then apply visitor to the node itself

export function walkNode(node: Node, visitor: Visitor): Node {
	// Recurse into children first (bottom-up)
	walkChildren(node, visitor);
	// Then let visitor transform this node
	return visitor(node);
}

// Recurse into all child nodes of a given node (mutates in place)
export function walkChildren(node: Node, visitor: Visitor): void {
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				d.programStmts[i] = walkNode(d.programStmts[i], visitor);
				i += 1;
			}
		},
		// Block
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				d.statements[i] = walkNode(d.statements[i], visitor);
				i += 1;
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = walkNode(d.condition, visitor);
			d.consequent = walkNode(d.consequent, visitor);
			d.alternate = walkNode(d.alternate, visitor);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = walkNode(d.whileCondition, visitor);
			d.whileBody = walkNode(d.whileBody, visitor);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			d.forInit = walkNode(d.forInit, visitor);
			d.forCondition = walkNode(d.forCondition, visitor);
			d.forUpdate = walkNode(d.forUpdate, visitor);
			d.forBody = walkNode(d.forBody, visitor);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfIterable = walkNode(d.forOfIterable, visitor);
			d.forOfBody = walkNode(d.forOfBody, visitor);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			d.forInObject = walkNode(d.forInObject, visitor);
			d.forInBody = walkNode(d.forInBody, visitor);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doBody = walkNode(d.doBody, visitor);
			d.doCondition = walkNode(d.doCondition, visitor);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			d.switchDisc = walkNode(d.switchDisc, visitor);
			let i = 0;
			while (i < d.switchCases.length) {
				d.switchCases[i] = walkNode(d.switchCases[i], visitor);
				i += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let i = 0;
			while (i < d.caseTests.length) {
				d.caseTests[i] = walkNode(d.caseTests[i], visitor);
				i += 1;
			}
			let j = 0;
			while (j < d.caseStmts.length) {
				d.caseStmts[j] = walkNode(d.caseStmts[j], visitor);
				j += 1;
			}
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			d.matchStmtDisc = walkNode(d.matchStmtDisc, visitor);
			let i = 0;
			while (i < d.matchStmtCases.length) {
				d.matchStmtCases[i] = walkNode(d.matchStmtCases[i], visitor);
				i += 1;
			}
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = walkNode(d.matchDisc, visitor);
			let i = 0;
			while (i < d.matchCases.length) {
				d.matchCases[i] = walkNode(d.matchCases[i], visitor);
				i += 1;
			}
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			let i = 0;
			while (i < d.casePatterns.length) {
				d.casePatterns[i] = walkNode(d.casePatterns[i], visitor);
				i += 1;
			}
			d.caseBody = walkNode(d.caseBody, visitor);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			d.fnBody = walkNode(d.fnBody, visitor);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			d.arrowBody = walkNode(d.arrowBody, visitor);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			d.funcExprBody = walkNode(d.funcExprBody, visitor);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				d.classBody[i] = walkNode(d.classBody[i], visitor);
				i += 1;
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			d.methodBody = walkNode(d.methodBody, visitor);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			d.ctorBody = walkNode(d.ctorBody, visitor);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			d.exportedDecl = walkNode(d.exportedDecl, visitor);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			d.decoratedNode = walkNode(d.decoratedNode, visitor);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			d.macroDeclBody = walkNode(d.macroDeclBody, visitor);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			d.initializer = walkNode(d.initializer, visitor);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			d.argument = walkNode(d.argument, visitor);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			d.throwArg = walkNode(d.throwArg, visitor);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = walkNode(d.expr, visitor);
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			d.deferExpr = walkNode(d.deferExpr, visitor);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			d.tryBody = walkNode(d.tryBody, visitor);
			d.catchBody = walkNode(d.catchBody, visitor);
			d.finallyBody = walkNode(d.finallyBody, visitor);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = walkNode(d.left, visitor);
			d.right = walkNode(d.right, visitor);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = walkNode(d.operand, visitor);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			d.updateArg = walkNode(d.updateArg, visitor);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = walkNode(d.callee, visitor);
			let i = 0;
			while (i < d.arguments.length) {
				d.arguments[i] = walkNode(d.arguments[i], visitor);
				i += 1;
			}
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			d.object = walkNode(d.object, visitor);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			d.array = walkNode(d.array, visitor);
			d.index = walkNode(d.index, visitor);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				d.properties[i] = walkNode(d.properties[i], visitor);
				i += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				d.elements[i] = walkNode(d.elements[i], visitor);
				i += 1;
			}
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = walkNode(d.ternaryCondition, visitor);
			d.ternaryConsequent = walkNode(d.ternaryConsequent, visitor);
			d.ternaryAlternate = walkNode(d.ternaryAlternate, visitor);
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			d.spreadArg = walkNode(d.spreadArg, visitor);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			d.newCallee = walkNode(d.newCallee, visitor);
			let i = 0;
			while (i < d.newArguments.length) {
				d.newArguments[i] = walkNode(d.newArguments[i], visitor);
				i += 1;
			}
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			d.tryArg = walkNode(d.tryArg, visitor);
			d.catchVal = walkNode(d.catchVal, visitor);
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			d.awaitArg = walkNode(d.awaitArg, visitor);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			d.yieldArg = walkNode(d.yieldArg, visitor);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			d.moveArg = walkNode(d.moveArg, visitor);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			d.outArg = walkNode(d.outArg, visitor);
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			d.asExpr = walkNode(d.asExpr, visitor);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			d.destrPattern = walkNode(d.destrPattern, visitor);
			d.destrInit = walkNode(d.destrInit, visitor);
		},
		NodeKind.QuoteExpr => {
			const d = node.data as QuoteExprData;
			d.quoteBody = walkNode(d.quoteBody, visitor);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				d.macroArgs[i] = walkNode(d.macroArgs[i], visitor);
				i += 1;
			}
		},
		// Leaf nodes (no children to walk)
		_ => {},
	};
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

export function walkExpandBlocks(node: Node, expander: StmtExpander, ctx: TransformContext): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			d.programStmts = expandAndRecurse(d.programStmts, expander, ctx);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			d.statements = expandAndRecurse(d.statements, expander, ctx);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkExpandBlocks(d.fnBody, expander, ctx);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkExpandBlocks(d.arrowBody, expander, ctx);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkExpandBlocks(d.funcExprBody, expander, ctx);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkExpandBlocks(d.methodBody, expander, ctx);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkExpandBlocks(d.ctorBody, expander, ctx);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkExpandBlocks(d.exportedDecl, expander, ctx);
		},
		_ => {},
	};
}

function expandAndRecurse(stmts: Node[], expander: StmtExpander, ctx: TransformContext): Node[] {
	const result: Node[] = [];
	for (const stmt of stmts) {
		const expanded = expander(stmt, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	for (const node of result) {
		walkExpandBlocks(node, expander, ctx);
	}
	return result;
}
