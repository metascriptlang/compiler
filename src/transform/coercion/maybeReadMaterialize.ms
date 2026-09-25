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

import { Node, NodeKind, TypeKind, BinaryExprData, MemberExprData, ArrayAccessData, OutExprData, HiddenStdConvData, TypeAssertionData, Type } from "../../ast/node";
import { isMaybeType, unwrapMaybeType, isTagCarriedUnion, unwrapRefNullUnion } from "../../checker/types";
import { projectTagUnionMember, narrowMaybePayload } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember } from "../util";

export function materializeMaybeReads(program: Node, ctx: TransformContext): Node {
	const project = !ctx.jsBackend;
	return walkNode(program, (n: Node): Node => visitMaybeRead(n, project));
}

function isAssignOp(op: string): boolean {
	if (op == "=") return true;
	if (op.length < 2 || op.charAt(op.length - 1) != "=") return false;
	return op != "==" && op != "!=" && op != "===" && op != "!==" && op != "<=" && op != ">=";
}

function declaredMaybeOf(node: Node): Type | null {
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym != null && sym.symbolType != null && isMaybeType(sym.symbolType)) return sym.symbolType;
		return null;
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object == null || d.object.nodeType == null) return null;
		let ot = d.object.nodeType as Type | null;
		while (ot != null && (ot.kind == TypeKind.Ref || ot.kind == TypeKind.Ptr || ot.kind == TypeKind.Var) && ot.typeReturn != null) {
			ot = ot.typeReturn;
		}
		if (ot == null || ot.typeNames == null) return null;
		for (let i = 0; i < ot.typeNames.length; i += 1) {
			if (ot.typeNames[i] == d.property) {
				const ft = i < ot.typeChildren.length ? ot.typeChildren[i] : null;
				if (ft != null && isMaybeType(ft)) return ft;
				return null;
			}
		}
		return null;
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		if (d.array == null || d.array.nodeType == null) return null;
		const at = d.array.nodeType;
		if (at.kind != TypeKind.Array || at.typeReturn == null) return null;
		if (isMaybeType(at.typeReturn)) return at.typeReturn;
		return null;
	}
	return null;
}

function unwrapIfMaterialized(n: Node): Node {
	if (n != null && n.kind == NodeKind.HiddenSubConv && n.variantSlot > 0) {
		n = (n.data as HiddenStdConvData).convExpr;
		if (n != null && n.nodeType != null && isMaybeType(n.nodeType)) return n;
	}
	if (n == null || n.kind != NodeKind.MemberExpr) return n;
	const d = n.data as MemberExprData;
	if (d.property != "value") return n;
	if (d.object == null || d.object.nodeType == null || !isMaybeType(d.object.nodeType)) return n;
	return d.object;
}

function narrowAssertedCarrier(node: Node): Node {
	const target = node.nodeType;
	if (target == null || !isMaybeType(target)) return node;
	const inner = (node.data as TypeAssertionData).asExpr;
	if (inner == null || inner.nodeType == null) return node;
	const carrier = inner.nodeType;
	if (!isMaybeType(carrier) || carrier == target) return node;
	if (!isTagCarriedUnion(unwrapMaybeType(carrier))) return node;
	const narrowed = narrowMaybePayload(inner, carrier, target);
	if (narrowed != null as unknown as Node) return narrowed;
	return node;
}

function visitMaybeRead(node: Node, project: boolean): Node {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) d.left = unwrapIfMaterialized(d.left);
		return node;
	}
	if (node.kind == NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		d.outArg = unwrapIfMaterialized(d.outArg);
		return node;
	}
	if (node.kind == NodeKind.TypeAssertion) return project ? narrowAssertedCarrier(node) : node;
	if (node.kind != NodeKind.Identifier && node.kind != NodeKind.MemberExpr && node.kind != NodeKind.ArrayAccess) return node;
	const nt = node.nodeType;
	if (nt == null || nt.kind == TypeKind.Null) return node;
	if (isMaybeType(nt)) {
		if (!project) return node;
		const declared = declaredMaybeOf(node);
		if (declared == null || declared == nt || !isTagCarriedUnion(unwrapMaybeType(declared))) return node;
		node.nodeType = declared;
		const narrowed = narrowMaybePayload(node, declared, nt);
		if (narrowed != null as unknown as Node) return narrowed;
		node.nodeType = nt;
		return node;
	}
	const carrier = declaredMaybeOf(node);
	if (carrier == null) return node;
	node.nodeType = carrier;
	if (project && unwrapRefNullUnion(nt) != null && isTagCarriedUnion(unwrapMaybeType(carrier))) {
		const nilable = narrowMaybePayload(node, carrier, nt);
		if (nilable != null as unknown as Node) return nilable;
	}
	const val = makeMember(node, "value", node.location);
	const payload = unwrapMaybeType(carrier);
	val.nodeType = payload;
	if (project && nt != payload && isTagCarriedUnion(payload)) {
		const projected = projectTagUnionMember(val, payload, nt);
		if (projected != null as unknown as Node) return projected;
	}
	return val;
}
