// AST Walker — recursive traversal for transforms
// Two modes: walkNode (1:1 visitor) and walkBlockExpanding (1:N statement expansion, in blockExpand.ms)

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, HiddenDerefData, HiddenStdConvData, TypeAssertionData, PropertyDeclData } from "../ast/node";
import { Visitor, mapChildren, isFuncBoundary } from "../ast/visitor";

export { mapChildren, isFuncBoundary } from "../ast/visitor";
export { hasEffect, walkOnceEvaluated, OnceEvalState, OnceEvalVisitor } from "./walkEffects";
export { walkExpandBlocks, walkExpandBlocksHooked, walkBlockExpanding, expandingInsideTry, FnEntryHook, FnExitHook } from "./blockExpand";

// ===== 1:1 Walk =====
// Bottom-up: recurse into children first, then apply visitor to the node itself

export function walkNode(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	// Recurse into children first (bottom-up)
	walkChildren(node, visitor);
	// Then let visitor transform this node
	return visitor(node);
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

// True if the expression contains a CONDITIONALLY-evaluated sub-position: the RHS
// of a short-circuit `&&`/`||`, or a ternary branch. A fresh call there runs only
// sometimes — hoisting it to a preceding statement would evaluate it eagerly and
// break the guard (proven: `if (xs.length>0 && xs[0].slice(...))` hoisted the slice
// before the length guard → crash). Such inits are skipped until the nested-if
// lowering (which preserves short-circuit) is in place.
export function containsConditionalEval(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if (node.kind == NodeKind.ConditionalExpr) { found = true; }
		if (node.kind == NodeKind.BinaryExpr) {
			const op = (node.data as BinaryExprData).operator;
			if (op == "&&" || op == "||") { found = true; }
		}
		return node;
	});
	return found;
}
