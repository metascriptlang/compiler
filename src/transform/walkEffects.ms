import { Node, NodeKind, BinaryExprData, ForStmtData, IfStmtData, ConditionalExprData } from "../ast/node";
import { forEachChild, anyDescendant, isFuncBoundary, Visit } from "../ast/visitor";
import { isAssignOp } from "../ast/operators";

function isEffectNode(n: Node): boolean {
	if (n.kind == NodeKind.CallExpr || n.kind == NodeKind.NewExpr || n.kind == NodeKind.UpdateExpr
		|| n.kind == NodeKind.AwaitExpr || n.kind == NodeKind.YieldExpr || n.kind == NodeKind.OutExpr) return true;
	return n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator);
}

function effectVerdict(n: Node): Visit {
	if (isEffectNode(n)) return Visit.Hit;
	return isFuncBoundary(n) ? Visit.Skip : Visit.Descend;
}

export function hasEffect(n: Node): boolean {
	return anyDescendant(n, effectVerdict);
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
