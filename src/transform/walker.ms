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
	HiddenDerefData, HiddenStdConvData,
	TypeAssertionData, DestructuringDeclData, QuoteExprData, ComptimeBlockData,
	MacroInvocationData, TestDeclData, AssertStmtData,
} from "../ast/node";
import { TransformContext } from "./context";

// Visitor function: takes a node, returns replacement (or same node if unchanged)
type Visitor = (node: Node) => Node;

// Expanding visitor: takes a statement, returns array of replacement statements
type ExpandingVisitor = (node: Node) => Node[];

// ===== 1:1 Walk =====
// Bottom-up: recurse into children first, then apply visitor to the node itself

export function walkNode(node: Node, visitor: Visitor): Node {
	if (node === null) return null as unknown as Node;
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
			if (d.forOfPattern !== null) { d.forOfPattern = f(d.forOfPattern); }
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
			if (d.initializer !== null) d.initializer = f(d.initializer);
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
			if (d.hasCatch) { d.catchVal = f(d.catchVal); }
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
		NodeKind.SizeofExpr => {},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			d.expr = f(d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			d.convExpr = f(d.convExpr);
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
		NodeKind.ComptimeBlock => {
			const d = node.data as ComptimeBlockData;
			d.comptimeBody = f(d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				d.macroArgs[i] = f(d.macroArgs[i]);
				i += 1;
			}
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			d.testBody = f(d.testBody);
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			d.assertExpr = f(d.assertExpr);
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
function replaceProgStmts(node: Node, expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): void {
	const pd = node.data as ProgramData;
	node.data = { programStmts: expandAndRecurseHooked(pd.programStmts, expander, ctx, onFnEntry, onFnExit) };
}

function replaceBlockStmts(node: Node, expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): void {
	const bd = node.data as BlockStmtData;
	node.data = { statements: expandAndRecurseHooked(bd.statements, expander, ctx, onFnEntry, onFnExit) };
}

export function walkExpandBlocks(node: Node, expander: StmtExpander, ctx: TransformContext): void {
	walkExpandBlocksHooked(node, expander, ctx, null as unknown as FnEntryHook, null as unknown as FnExitHook);
}

export function walkExpandBlocksHooked(node: Node, expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): void {
	match (node.kind) {
		NodeKind.Program => {
			replaceProgStmts(node, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.BlockStmt => {
			replaceBlockStmts(node, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (onFnEntry !== null) onFnEntry(node);
			walkExpandBlocksHooked(d.fnBody, expander, ctx, onFnEntry, onFnExit);
			if (onFnExit !== null) onFnExit(node);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			if (onFnEntry !== null) onFnEntry(node);
			walkExpandBlocksHooked(d.arrowBody, expander, ctx, onFnEntry, onFnExit);
			if (onFnExit !== null) onFnExit(node);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			if (onFnEntry !== null) onFnEntry(node);
			walkExpandBlocksHooked(d.funcExprBody, expander, ctx, onFnEntry, onFnExit);
			if (onFnExit !== null) onFnExit(node);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			if (onFnEntry !== null) onFnEntry(node);
			walkExpandBlocksHooked(d.methodBody, expander, ctx, onFnEntry, onFnExit);
			if (onFnExit !== null) onFnExit(node);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkExpandBlocksHooked(d.ctorBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkExpandBlocksHooked(d.exportedDecl, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			walkExpandBlocksHooked(d.testBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.AssertStmt => {},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkExpandBlocksHooked(d.consequent, expander, ctx, onFnEntry, onFnExit);
			walkExpandBlocksHooked(d.alternate, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			walkExpandBlocksHooked(d.whileBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			walkExpandBlocksHooked(d.forBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			walkExpandBlocksHooked(d.forOfBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkExpandBlocksHooked(d.tryBody, expander, ctx, onFnEntry, onFnExit);
			walkExpandBlocksHooked(d.catchBody, expander, ctx, onFnEntry, onFnExit);
			walkExpandBlocksHooked(d.finallyBody, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			let i = 0;
			while (i < d.switchCases.length) {
				walkExpandBlocksHooked(d.switchCases[i], expander, ctx, onFnEntry, onFnExit);
				i = i + 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let j = 0;
			while (j < d.caseStmts.length) {
				walkExpandBlocksHooked(d.caseStmts[j], expander, ctx, onFnEntry, onFnExit);
				j = j + 1;
			}
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkExpandBlocksHooked(d.decoratedNode, expander, ctx, onFnEntry, onFnExit);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				walkExpandBlocksHooked(d.classBody[i], expander, ctx, onFnEntry, onFnExit);
				i = i + 1;
			}
		},
		_ => {},
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
	if (node === null) return false;
	if (node.kind === kind) return true;
	let found = false;
	mapExprChildren(node, (child: Node): Node => {
		if (!found && containsExprKind(child, kind)) { found = true; }
		return child;
	});
	return found;
}

// Bottom-up expression tree walk: recurse into children first, then apply replacer.
// If replacer returns a different node, use it as the replacement.
export function replaceInExpr(node: Node, replacer: Visitor): Node {
	if (node === null) return node;
	mapExprChildren(node, (child: Node): Node => replaceInExpr(child, replacer));
	return replacer(node);
}

function expandAndRecurse(stmts: Node[], expander: StmtExpander, ctx: TransformContext): Node[] {
	return expandAndRecurseHooked(stmts, expander, ctx, null as unknown as FnEntryHook, null as unknown as FnExitHook);
}

function expandAndRecurseHooked(stmts: Node[], expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): Node[] {
	const result: Node[] = [];
	for (const stmt of stmts) {
		const expanded = expander(stmt, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	for (const node of result) {
		walkExpandBlocksHooked(node, expander, ctx, onFnEntry, onFnExit);
	}
	return result;
}
