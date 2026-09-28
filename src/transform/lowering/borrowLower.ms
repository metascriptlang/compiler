import { Node, NodeKind, CallExprData, Symbol } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

function borrowTarget(sym: Symbol | null): Symbol | null {
	if (sym == null || !hasFlag(sym, SymbolFlag.Borrow)) return null;
	const base = borrowedBy(sym);
	return base != null && hasFlag(base, SymbolFlag.Borrow) ? borrowTarget(base) : base;
}

function borrowedBy(sym: Symbol): Symbol | null {
	return sym.instantiatedFrom != null ? sym.instantiatedFrom.borrowedFrom : sym.borrowedFrom;
}

function calledMember(set: Symbol, idx: number): Symbol {
	return idx > 0 && idx - 1 < set.overloads.length ? set.overloads[idx - 1] : set;
}

function retarget(node: Node, target: Symbol): void {
	node.resolvedSym = target;
	node.nodeType = target.symbolType;
}

function lowerBorrowNode(node: Node): Node {
	if (node.kind == NodeKind.Identifier) {
		const target = borrowTarget(node.resolvedSym);
		if (target != null && node.resolvedSym!.overloads.length == 0) retarget(node, target);
		return node;
	}
	if (node.kind != NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;
	if (d.callee.kind == NodeKind.Identifier && d.callee.resolvedSym != null) {
		const target = borrowTarget(calledMember(d.callee.resolvedSym, d.resolvedOverloadIdx));
		if (target != null) {
			retarget(d.callee, target);
			d.resolvedOverloadIdx = -1;
			node.resolvedSym = target;
		}
	}
	const target = borrowTarget(node.resolvedSym);
	if (target != null) node.resolvedSym = target;
	return node;
}

export function lowerBorrow(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerBorrowNode);
}
