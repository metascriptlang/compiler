// AST Walker — recursive traversal for transforms
// Two modes: walkNode (1:1 visitor) and walkBlockExpanding (1:N statement expansion, in blockExpand.ms)

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, HiddenDerefData, HiddenStdConvData, TypeAssertionData, PropertyDeclData } from "../ast/node";
import { Visitor, mapChildrenWith, applyVisitor, isFuncBoundary, forEachChild } from "../ast/visitor";

export { mapChildren, mapChildrenWith, isFuncBoundary } from "../ast/visitor";
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
	mapChildrenWith(node, visitor, walkChild);
}

function walkChild(child: Node, visitor: Visitor): Node {
	if (child == null) return null as unknown as Node;
	mapChildrenWith(child, visitor, walkChild);
	return visitor(child);
}

export function walkWithinStatement(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	if (opensStatementScope(node)) return node;
	mapChildrenWith(node, visitor, walkChildWithinStatement);
	return visitor(node);
}

function walkChildWithinStatement(child: Node, visitor: Visitor): Node {
	if (child == null || opensStatementScope(child)) return child;
	mapChildrenWith(child, visitor, walkChildWithinStatement);
	return visitor(child);
}

function opensStatementScope(node: Node): boolean {
	return isFuncBoundary(node) || node.kind == NodeKind.BlockStmt || node.kind == NodeKind.SwitchCase
		|| node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl
		|| node.kind == NodeKind.ActorDecl || isInstanceFieldInit(node);
}

export function walkOutsideInstanceFieldInits(node: Node, visitor: Visitor): Node {
	if (node == null) return null as unknown as Node;
	if (isInstanceFieldInit(node)) return node;
	mapChildrenWith(node, visitor, walkChildOutsideInstanceFieldInits);
	return visitor(node);
}

function walkChildOutsideInstanceFieldInits(child: Node, visitor: Visitor): Node {
	if (child == null || isInstanceFieldInit(child)) return child;
	mapChildrenWith(child, visitor, walkChildOutsideInstanceFieldInits);
	return visitor(child);
}

export function isInstanceFieldInit(node: Node): boolean {
	return node.kind == NodeKind.PropertyDecl && !(node.data as PropertyDeclData).propIsStatic;
}

// ===== Expression-Level Utilities =====
// Shared by resultDesugar (TryExpr hoisting) and matchLower (MatchExpr hoisting).
// Only walks expression-level children — does NOT recurse into function bodies,
// block statements, or match case arms.

export function mapExprChildren(node: Node, f: Visitor): void {
	mapExprChildrenWith(node, f, applyVisitor);
}

export function mapExprChildrenWith<C>(node: Node, ctx: C, f: (child: Node, ctx: C) => Node): void {
	match (node.kind) {
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = f(d.callee, ctx);
			let i = 0;
			while (i < d.arguments.length) { d.arguments[i] = f(d.arguments[i], ctx); i += 1; }
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = f(d.left, ctx);
			d.right = f(d.right, ctx);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = f(d.operand, ctx);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			d.object = f(d.object, ctx);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			d.array = f(d.array, ctx);
			d.index = f(d.index, ctx);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = f(d.ternaryCondition, ctx);
			d.ternaryConsequent = f(d.ternaryConsequent, ctx);
			d.ternaryAlternate = f(d.ternaryAlternate, ctx);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) { d.properties[i] = f(d.properties[i], ctx); i += 1; }
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) { d.elements[i] = f(d.elements[i], ctx); i += 1; }
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			d.spreadArg = f(d.spreadArg, ctx);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			d.newCallee = f(d.newCallee, ctx);
			let i = 0;
			while (i < d.newArguments.length) { d.newArguments[i] = f(d.newArguments[i], ctx); i += 1; }
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			d.tryArg = f(d.tryArg, ctx);
			if (d.hasCatch) { d.catchVal = f(d.catchVal, ctx); }
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = f(d.matchDisc, ctx);
			// Don't recurse into matchCases — they're statement-level
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			d.asExpr = f(d.asExpr, ctx);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			d.expr = f(d.expr, ctx);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			d.convExpr = f(d.convExpr, ctx);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			d.updateArg = f(d.updateArg, ctx);
		},
		_ => {},
	};
}

// Check if any node in an expression tree has the given NodeKind.
export function containsExprKind(node: Node, kind: NodeKind): boolean {
	const probe: ExprKindProbe = { kind, found: false };
	probeExprKind(node, probe);
	return probe.found;
}

interface ExprKindProbe {
	kind: NodeKind;
	found: boolean;
}

function probeExprKind(node: Node, probe: ExprKindProbe): Node {
	if (node == null || probe.found) return node;
	if (node.kind == probe.kind) {
		probe.found = true;
		return node;
	}
	mapExprChildrenWith(node, probe, probeExprKind);
	return node;
}

// Bottom-up expression tree walk: recurse into children first, then apply replacer.
// If replacer returns a different node, use it as the replacement.
export function replaceInExpr(node: Node, replacer: Visitor): Node {
	if (node == null) return node;
	mapExprChildrenWith(node, replacer, replaceInExpr);
	return replacer(node);
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
