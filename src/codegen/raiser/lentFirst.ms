// The first parameter of a Borrow-returning routine passes as its place, the C backend's lent-first ABI, so the borrow
// points at the caller's value, never into the callee's frame. Runs after the analyzer: lifetime placement must keep
// seeing a by-value parameter.

import { Node, NodeKind, Type, TypeKind, Symbol, CallExprData, HiddenDerefData } from "../../ast/node";
import { mapChildren } from "../../ast/visitor";
import { skipModifier, createBorrow } from "../../checker/types";
import { passedByValue } from "../../checker/varPartitions";
import { makeHiddenAddr, makeHiddenDeref } from "../../transform/util";
import { RaiserCompState } from "./context";
import { heldByLocation } from "./valueCopy";

export function lentFirstParam(fnType: Type | null): Type | null {
	const t = skipModifier(fnType);
	if (t == null || t.kind != TypeKind.Function || t.typeReturn == null || t.typeReturn.kind != TypeKind.Borrow || t.typeChildren.length == 0) return null;
	const first = t.typeChildren[0];
	return first.kind != TypeKind.Var && first.kind != TypeKind.Void && passedByValue(skipModifier(first)) ? first : null;
}

// The parameter's register holds a location, not the value, when the Raiser keeps the type in a place.
export function lentFirstLocation(s: RaiserCompState, fnType: Type | null): boolean {
	const first = lentFirstParam(fnType);
	return first != null && heldByLocation(s, first);
}

function calleeType(d: CallExprData): Type | null {
	const t = skipModifier(d.callee.nodeType);
	if (t != null && t.kind == TypeKind.Function) return t;
	return d.callee.resolvedSym != null ? d.callee.resolvedSym.symbolType : null;
}

function lentParamOf(node: Node): Symbol | null {
	if (node.kind != NodeKind.FunctionDecl && node.kind != NodeKind.ArrowFunction && node.kind != NodeKind.FunctionExpr && node.kind != NodeKind.MethodDecl) return null;
	const fnType = node.resolvedSym != null && node.resolvedSym.symbolType != null ? node.resolvedSym.symbolType : node.nodeType;
	if (lentFirstParam(fnType) == null) return null;
	const params = node.paramSyms;
	if (params == null || params.length != fnType!.typeChildren.length) {
		throw new Error(`internal: a routine returning a Borrow reached the Raiser without one symbol per parameter`);
	}
	return params[0];
}

export function lowerLentFirst(program: Node): Node {
	const lent = new Set<Symbol>();
	const visit = (node: Node): Node => {
		if (node == null) return node;
		if (node.kind == NodeKind.Identifier) return node.resolvedSym != null && lent.has(node.resolvedSym) ? makeHiddenDeref(node, node.location) : node;
		if (node.kind == NodeKind.HiddenDeref) {
			const inner = (node.data as HiddenDerefData).expr;
			if (inner != null && inner.kind == NodeKind.Identifier && inner.resolvedSym != null && lent.has(inner.resolvedSym)) return node;
		}
		const param = lentParamOf(node);
		if (param != null) lent.add(param);
		mapChildren(node, visit);
		if (node.kind == NodeKind.CallExpr) {
			const d = node.data as CallExprData;
			if (d.arguments.length > 0 && d.arguments[0].kind != NodeKind.HiddenAddr && lentFirstParam(calleeType(d)) != null) {
				const arg = d.arguments[0];
				const addr = makeHiddenAddr(arg, arg.location);
				if (arg.nodeType != null) addr.nodeType = createBorrow(arg.nodeType);
				d.arguments[0] = addr;
			}
		}
		return node;
	};
	mapChildren(program, visit);
	return program;
}
