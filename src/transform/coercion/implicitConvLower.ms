// Implicit conversion lowering — the checker marks T → Maybe<T>, named
// function → closure and T → Borrow<T> as hidden conversions; this turns each into
// what every later pass reads: the `{ value, present }` carrier, the `{ fn, env }`
// pair and the address of the borrowed place.

import { Node, NodeKind, NodeFlag, TypeKind, CallingConvention, HiddenStdConvData } from "../../ast/node";
import { isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeTypedObjectLiteral, makeHiddenAddr } from "../util";
import { wrapMaybeValue } from "../native/nullableLower";

export function lowerImplicitConv(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerImplicitConvNode);
}

function lowerImplicitConvNode(node: Node): Node {
	if (node.kind != NodeKind.HiddenStdConv) return node;
	const d = node.data as HiddenStdConvData;
	if (isMaybeType(d.convType)) {
		if (d.convExpr.nodeType != null && isMaybeType(d.convExpr.nodeType)) return d.convExpr;
		return wrapMaybeValue(d.convExpr, d.convType, node.location);
	}
	if (d.convType.kind == TypeKind.Borrow) {
		const addr = makeHiddenAddr(d.convExpr, node.location);
		addr.nodeType = d.convType;
		return addr;
	}
	if (isClosureThunkConv(d)) {
		const pair = makeTypedObjectLiteral(["fn", "env"], [d.convExpr, makeNull(node.location)], d.convType, node.location);
		pair.flags = pair.flags.incl(NodeFlag.Closure);
		return pair;
	}
	return node;
}

function isClosureThunkConv(d: HiddenStdConvData): boolean {
	const inner = d.convExpr.nodeType;
	return d.convType.kind == TypeKind.Function && d.convType.callConv == CallingConvention.CcClosure
		&& inner != null && inner.kind == TypeKind.Function && inner.callConv != CallingConvention.CcClosure;
}
