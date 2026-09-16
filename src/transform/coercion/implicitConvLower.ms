// Implicit conversion lowering — the checker marks T → Maybe<T> and named
// function → closure as hidden conversions; this turns each into the literal
// every later pass reads: the `{ value, present }` carrier and the `{ fn, env }` pair.

import { Node, NodeKind, NodeFlag, TypeKind, CallingConvention, HiddenStdConvData } from "../../ast/node";
import { isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeTypedObjectLiteral } from "../util";
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
