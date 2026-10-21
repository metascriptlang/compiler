import { Node, NodeKind, NodeFlag, CallExprData, MemberExprData, Symbol } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { hasFlag, overloadWinner, SymbolFlag } from "../../checker/symbol";
import { distinctBody } from "../../checker/types";
import { makeHiddenStdConv, makeTypedIdentResolved } from "../util";

function borrowTarget(sym: Symbol | null): Symbol | null {
	if (sym == null || !hasFlag(sym, SymbolFlag.Borrow)) return null;
	const base = borrowedBy(sym);
	return base != null && hasFlag(base, SymbolFlag.Borrow) ? borrowTarget(base) : base;
}

function borrowedBy(sym: Symbol): Symbol | null {
	return sym.instantiatedFrom != null ? sym.instantiatedFrom.borrowedFrom : sym.borrowedFrom;
}

function retarget(node: Node, target: Symbol): void {
	node.resolvedSym = target;
	node.nodeType = target.symbolType;
}

function atBase(arg: Node): Node {
	let base = arg.nodeType;
	while (distinctBody(base) != null) base = distinctBody(base);
	return base == null || base == arg.nodeType ? arg : makeHiddenStdConv(arg, base, arg.location);
}

function lowerBorrowNode(node: Node): Node {
	if (node.kind == NodeKind.Identifier) {
		const target = borrowTarget(node.resolvedSym);
		if (target != null && node.resolvedSym!.overloads.length == 0) retarget(node, target);
		return node;
	}
	if (node.flags.has(NodeFlag.UserOp)) {
		const routine = borrowTarget(node.resolvedSym);
		if (routine != null) node.resolvedSym = routine;
		return node;
	}
	if (node.kind != NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;
	let landed: Symbol | null = null;
	if (d.callee.kind == NodeKind.Identifier && d.callee.resolvedSym != null) {
		const target = borrowTarget(overloadWinner(d.callee.resolvedSym, d.resolvedOverloadIdx));
		if (target != null) {
			retarget(d.callee, target);
			d.resolvedOverloadIdx = -1;
			landed = target;
		}
	}
	if (landed == null) landed = borrowTarget(node.resolvedSym);
	if (landed == null) return node;
	node.resolvedSym = landed;
	if (landed.builtinKind == "ToString") textAtBase(d, landed);
	return node;
}

function textAtBase(d: CallExprData, text: Symbol): void {
	const operand = d.callee.kind == NodeKind.MemberExpr ? (d.callee.data as MemberExprData).object : d.arguments[0];
	d.callee = makeTypedIdentResolved(text, text.symbolType, d.callee.location);
	d.arguments = [atBase(operand)];
}

export function lowerBorrow(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerBorrowNode);
}
