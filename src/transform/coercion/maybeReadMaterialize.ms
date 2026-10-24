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
// carrier and wrapped in a `.value` member typed at the payload. That member is
// checked (ConvCheck): narrowing survives calls and closure writes, so the carrier
// can be absent at the read, which then stops like `as T` does.
//
// Assignment targets stay raw: the checker wraps the RHS into the carrier
// (synthMaybeWrap), so the store writes the whole struct. Bottom-up walking wraps the
// LHS before the assignment node is visited — undo it there.

import { Node, NodeKind, NodeFlag, TypeKind, BinaryExprData, MemberExprData, ArrayAccessData, OutExprData, HiddenStdConvData, TypeAssertionData, Type } from "../../ast/node";
import { isMaybeType, unwrapMaybeType, isTagCarriedUnion, unwrapRefNullUnion, peelTransparentInstance } from "../../checker/types";
import { projectTagUnionMember, narrowMaybePayload, checkedProjection, storesUnionTag } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeBinary } from "../util";
import { unwrapRefusesNull, wrapMaybeValue } from "../native/nullableLower";
import { cloneIfPure } from "../place";
import { isAssignOp, isLogicalAssignOp } from "../../ast/operators";

export function materializeMaybeReads(program: Node, ctx: TransformContext): Node {
	const project = !ctx.jsBackend && !ctx.raiserBackend;
	return walkNode(program, (n: Node): Node => visitMaybeRead(n, project));
}

function carriesTaggedUnion(carrier: Type | null): boolean {
	if (carrier == null || !isMaybeType(carrier)) return false;
	const payload = unwrapMaybeType(carrier);
	return payload != null && payload.kind == TypeKind.Union && storesUnionTag(payload);
}

function isCompoundStoreOp(op: string): boolean {
	return op != "=" && !isLogicalAssignOp(op);
}

// `x op= y` on a narrowed carrier stores what `x = x op y` stores: the checker wraps the
// RHS of `=` into the carrier, but a compound RHS is a bare payload.
function storeCompoundInCarrier(node: Node, d: BinaryExprData, read: Node): Node {
	const carrier = d.left.nodeType;
	const readCarrier = cloneIfPure(d.left);
	if (carrier == null || readCarrier == null) return node;
	const payloadRead = makeMember(readCarrier, "value", node.location);
	payloadRead.nodeType = read.nodeType;
	payloadRead.flags = read.flags;
	const combined = makeBinary(payloadRead, d.operator.slice(0, d.operator.length - 1), d.right, node.location);
	return makeBinary(d.left, "=", wrapMaybeValue(combined, carrier, node.location), node.location);
}

function declaredMaybeOf(node: Node): Type | null {
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		let st = sym != null && sym.symbolType != null ? peelTransparentInstance(sym.symbolType) as Type | null : null;
		if (st != null && (st.kind == TypeKind.Var || st.kind == TypeKind.Borrow) && st.typeReturn != null) {
			st = peelTransparentInstance(st.typeReturn);
		}
		if (st != null && isMaybeType(st)) return st;
		return null;
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object == null || d.object.nodeType == null) return null;
		let ot = peelTransparentInstance(d.object.nodeType) as Type | null;
		while (ot != null && (ot.kind == TypeKind.Ref || ot.kind == TypeKind.Ptr || ot.kind == TypeKind.Var) && ot.typeReturn != null) {
			ot = ot.typeReturn;
		}
		if (ot == null || ot.typeNames == null) return null;
		for (let i = 0; i < ot.typeNames.length; i += 1) {
			if (ot.typeNames[i] == d.property) {
				const ft = i < ot.typeChildren.length && ot.typeChildren[i] != null ? peelTransparentInstance(ot.typeChildren[i]) : null;
				if (ft != null && isMaybeType(ft)) return ft;
				return null;
			}
		}
		return null;
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		if (d.array == null || d.array.nodeType == null) return null;
		const at = peelTransparentInstance(d.array.nodeType);
		if (at.kind != TypeKind.Array || at.typeReturn == null) return null;
		const et = peelTransparentInstance(at.typeReturn);
		if (isMaybeType(et)) return et;
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
	if (target == null) return node;
	const inner = (node.data as TypeAssertionData).asExpr;
	if (inner == null || inner.nodeType == null) return node;
	const carrier = inner.nodeType;
	if (!isMaybeType(carrier) || carrier == target) return node;
	const payload = unwrapMaybeType(carrier);
	if (!isTagCarriedUnion(payload)) return node;
	const checked = node.flags.has(NodeFlag.ConvCheck);
	if (!isMaybeType(target) && unwrapRefNullUnion(target) == null) {
		if (!checked) return node;
		const val = makeMember(inner, "value", node.location);
		val.nodeType = payload;
		const projected = checkedProjection(val, payload, target);
		if (projected == null as unknown as Node) return node;
		(node.data as TypeAssertionData).asExpr = projected;
		return node;
	}
	const narrowed = narrowMaybePayload(inner, carrier, target, true);
	if (narrowed == null as unknown as Node) return node;
	if (checked) narrowed.flags = narrowed.flags.incl(NodeFlag.ConvCheck);
	return narrowed;
}

function qualifiesForTagged(node: Node): boolean {
	if (node.kind == NodeKind.TypeAssertion) {
		const inner = (node.data as TypeAssertionData).asExpr;
		return inner != null && carriesTaggedUnion(inner.nodeType);
	}
	if (node.kind != NodeKind.Identifier && node.kind != NodeKind.MemberExpr && node.kind != NodeKind.ArrayAccess) return false;
	return carriesTaggedUnion(declaredMaybeOf(node));
}

// Narrowed to null, the read still holds whatever the carrier holds: a call or a closure
// may have filled it since the check.
function readNullAsCarrier(node: Node): Node {
	const carrier = declaredMaybeOf(node);
	if (carrier != null) node.nodeType = carrier;
	return node;
}

function visitMaybeRead(node: Node, projectAll: boolean): Node {
	const project = projectAll || qualifiesForTagged(node);
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (!isAssignOp(d.operator)) return node;
		const read = d.left;
		d.left = unwrapIfMaterialized(read);
		if (d.left != read && isCompoundStoreOp(d.operator)) return storeCompoundInCarrier(node, d, read);
		return node;
	}
	if (node.kind == NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		d.outArg = unwrapIfMaterialized(d.outArg);
		return node;
	}
	if (node.kind == NodeKind.TypeAssertion) return project ? narrowAssertedCarrier(node) : node;
	if (node.kind != NodeKind.Identifier && node.kind != NodeKind.MemberExpr && node.kind != NodeKind.ArrayAccess) return node;
	const ntRaw = node.nodeType;
	const nt = ntRaw != null ? peelTransparentInstance(ntRaw) : null;
	if (nt == null) return node;
	if (nt.kind == TypeKind.Null) return readNullAsCarrier(node);
	if (isMaybeType(nt)) {
		if (!project) return node;
		const declared = declaredMaybeOf(node);
		if (declared == null || declared == nt || !isTagCarriedUnion(unwrapMaybeType(declared))) return node;
		node.nodeType = declared;
		const narrowed = narrowMaybePayload(node, declared, nt);
		if (narrowed != null as unknown as Node) return narrowed;
		node.nodeType = ntRaw;
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
	val.nodeType = project ? payload : nt;
	if (unwrapRefusesNull(nt)) val.flags = val.flags.incl(NodeFlag.ConvCheck);
	if (project && nt != payload && isTagCarriedUnion(payload)) {
		const projected = projectTagUnionMember(val, payload, nt);
		if (projected != null as unknown as Node) return projected;
	}
	return val;
}
