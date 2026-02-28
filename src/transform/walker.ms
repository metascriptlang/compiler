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
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, HiddenDerefData,
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

// Apply f to all child nodes of a given node (mutates in place).
// Core dispatch used by walkChildren, and directly by bounded walkers
// that stop at function boundaries.
export function mapChildren(node: Node, f: Visitor): void {
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				d.programStmts[i] = f(d.programStmts[i]);
				i += 1;
			}
		},
		// Block
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				d.statements[i] = f(d.statements[i]);
				i += 1;
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = f(d.condition);
			d.consequent = f(d.consequent);
			d.alternate = f(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = f(d.whileCondition);
			d.whileBody = f(d.whileBody);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			d.forInit = f(d.forInit);
			d.forCondition = f(d.forCondition);
			d.forUpdate = f(d.forUpdate);
			d.forBody = f(d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfIterable = f(d.forOfIterable);
			d.forOfBody = f(d.forOfBody);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			d.forInObject = f(d.forInObject);
			d.forInBody = f(d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doBody = f(d.doBody);
			d.doCondition = f(d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			d.switchDisc = f(d.switchDisc);
			let i = 0;
			while (i < d.switchCases.length) {
				d.switchCases[i] = f(d.switchCases[i]);
				i += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
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
			const d = node.data as MatchStmtData;
			d.matchStmtDisc = f(d.matchStmtDisc);
			let i = 0;
			while (i < d.matchStmtCases.length) {
				d.matchStmtCases[i] = f(d.matchStmtCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = f(d.matchDisc);
			let i = 0;
			while (i < d.matchCases.length) {
				d.matchCases[i] = f(d.matchCases[i]);
				i += 1;
			}
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			let i = 0;
			while (i < d.casePatterns.length) {
				d.casePatterns[i] = f(d.casePatterns[i]);
				i += 1;
			}
			d.caseBody = f(d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			d.fnBody = f(d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			d.arrowBody = f(d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			d.funcExprBody = f(d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				d.classBody[i] = f(d.classBody[i]);
				i += 1;
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			d.methodBody = f(d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			d.ctorBody = f(d.ctorBody);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			d.exportedDecl = f(d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			d.decoratedNode = f(d.decoratedNode);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			d.macroDeclBody = f(d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			d.initializer = f(d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			d.argument = f(d.argument);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			d.throwArg = f(d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = f(d.expr);
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			d.deferExpr = f(d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			d.tryBody = f(d.tryBody);
			d.catchBody = f(d.catchBody);
			d.finallyBody = f(d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = f(d.left);
			d.right = f(d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = f(d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			d.updateArg = f(d.updateArg);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = f(d.callee);
			let i = 0;
			while (i < d.arguments.length) {
				d.arguments[i] = f(d.arguments[i]);
				i += 1;
			}
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
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				d.properties[i] = f(d.properties[i]);
				i += 1;
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				d.elements[i] = f(d.elements[i]);
				i += 1;
			}
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = f(d.ternaryCondition);
			d.ternaryConsequent = f(d.ternaryConsequent);
			d.ternaryAlternate = f(d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			d.spreadArg = f(d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			d.newCallee = f(d.newCallee);
			let i = 0;
			while (i < d.newArguments.length) {
				d.newArguments[i] = f(d.newArguments[i]);
				i += 1;
			}
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			d.tryArg = f(d.tryArg);
			d.catchVal = f(d.catchVal);
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			d.awaitArg = f(d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			d.yieldArg = f(d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			d.moveArg = f(d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			d.outArg = f(d.outArg);
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			d.expr = f(d.expr);
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			d.asExpr = f(d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			d.destrPattern = f(d.destrPattern);
			d.destrInit = f(d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d = node.data as QuoteExprData;
			d.quoteBody = f(d.quoteBody);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				d.macroArgs[i] = f(d.macroArgs[i]);
				i += 1;
			}
		},
		// Leaf nodes (no children to walk)
		_ => {},
	};
}

// Recurse into all child nodes using bottom-up walkNode traversal
export function walkChildren(node: Node, visitor: Visitor): void {
	mapChildren(node, (child: Node): Node => walkNode(child, visitor));
}

// Check if a node is a function boundary (FunctionDecl, ArrowFunction, FunctionExpr)
export function isFuncBoundary(node: Node): boolean {
	return node.kind === NodeKind.FunctionDecl ||
		node.kind === NodeKind.ArrowFunction ||
		node.kind === NodeKind.FunctionExpr;
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
