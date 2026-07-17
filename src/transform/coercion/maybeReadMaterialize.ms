// Maybe Read Materialization — narrowed reads of value-carried nullables.
//
// `T | null` for a value type is represented in C as a Maybe struct { value, present }.
// Flow narrowing retypes a read to plain T (`if (v !== null) use(v)`) but the C
// representation is still the carrier — using the raw node mixes struct and payload
// (loud clang errors, or silent union-stringify of the carrier). Doctrine (see
// native/maybeUnwrap.ms): materialize carrier reads for BOTH backends; the JS backend
// strips `x.value` back to `x`.
//
// A read qualifies when its DECLARED source type (symbol / struct field / array element)
// is Maybe-carried but its narrowed nodeType is not. The node is retyped back to the
// carrier and wrapped in a `.value` member typed at the payload.
//
// Assignment targets stay raw: the checker wraps the RHS into the carrier
// (synthMaybeWrap), so the store writes the whole struct. Bottom-up walking wraps the
// LHS before the assignment node is visited — undo it there.

import { Node, NodeKind, TypeKind, BinaryExprData, MemberExprData, ArrayAccessData, OutExprData, Type } from "../../ast/node";
import { isMaybeType, unwrapMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember } from "../util";

export function materializeMaybeReads(program: Node, ctx: TransformContext): Node {
	return walkNode(program, visitMaybeRead);
}

function isAssignOp(op: string): boolean {
	if (op === "=") return true;
	if (op.length < 2 || op.charAt(op.length - 1) !== "=") return false;
	return op !== "==" && op !== "!=" && op !== "===" && op !== "!==" && op !== "<=" && op !== ">=";
}

function declaredMaybeOf(node: Node): Type | null {
	if (node.kind === NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym !== null && sym.symbolType !== null && isMaybeType(sym.symbolType)) return sym.symbolType;
		return null;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object === null || d.object.nodeType === null) return null;
		let ot = d.object.nodeType as Type | null;
		while (ot !== null && (ot.kind === TypeKind.Ref || ot.kind === TypeKind.Ptr || ot.kind === TypeKind.Var) && ot.typeReturn !== null) {
			ot = ot.typeReturn;
		}
		if (ot === null || ot.typeNames === null) return null;
		for (let i = 0; i < ot.typeNames.length; i += 1) {
			if (ot.typeNames[i] === d.property) {
				const ft = i < ot.typeChildren.length ? ot.typeChildren[i] : null;
				if (ft !== null && isMaybeType(ft)) return ft;
				return null;
			}
		}
		return null;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		if (d.array === null || d.array.nodeType === null) return null;
		const at = d.array.nodeType;
		if (at.kind !== TypeKind.Array || at.typeReturn === null) return null;
		if (isMaybeType(at.typeReturn)) return at.typeReturn;
		return null;
	}
	return null;
}

function unwrapIfMaterialized(n: Node): Node {
	if (n === null || n.kind !== NodeKind.MemberExpr) return n;
	const d = n.data as MemberExprData;
	if (d.property !== "value") return n;
	if (d.object === null || d.object.nodeType === null || !isMaybeType(d.object.nodeType)) return n;
	return d.object;
}

function visitMaybeRead(node: Node): Node {
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) d.left = unwrapIfMaterialized(d.left);
		return node;
	}
	if (node.kind === NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		d.outArg = unwrapIfMaterialized(d.outArg);
		return node;
	}
	if (node.kind !== NodeKind.Identifier && node.kind !== NodeKind.MemberExpr && node.kind !== NodeKind.ArrayAccess) return node;
	const nt = node.nodeType;
	if (nt === null || nt.kind === TypeKind.Null || isMaybeType(nt)) return node;
	const carrier = declaredMaybeOf(node);
	if (carrier === null) return node;
	node.nodeType = carrier;
	const val = makeMember(node, "value", node.location);
	val.nodeType = unwrapMaybeType(carrier);
	return val;
}
