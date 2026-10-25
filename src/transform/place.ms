// Clones of a place expression: a name, a field chain, an index, a deref, so a
// lowering can read or write the same location a second time.

import { Node, NodeKind, NodeData, StringLiteralData, createNodeAt, TypeAssertionData, MemberExprData, ArrayAccessData, CallExprData, NumberLiteralData, HiddenDerefData, HiddenStdConvData, SourceLocation, TypeKind } from "../ast/node";
import { isMaybeType } from "../checker/types";
import { makeCall, cloneIdent, makeMember, makeArrayAccess, makeNumber, makeHiddenDeref, makeHiddenAddr, isRuntimeProcCall } from "./util";

// A second read of the lvalue is only safe when re-evaluating it cannot call
// anything or move anything — identifiers, field chains over them, and indexes
// that are themselves identifiers or literals.
export function cloneIfPure(node: Node): Node | null {
	if (node.kind == NodeKind.Identifier) {
		return cloneIdent(node, node.location);
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const obj = cloneIfPure(d.object);
		if (obj == null) return null;
		const c = makeMember(obj, d.property, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const arr = cloneIfPure(d.array);
		if (arr == null) return null;
		const idx = cloneIfPure(d.index);
		if (idx == null) return null;
		const c = makeArrayAccess(arr, idx, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	if (node.kind == NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const c = makeNumber(d.value, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	if (node.kind == NodeKind.StringLiteral) {
		const c = createNodeAt(NodeKind.StringLiteral, { value: (node.data as StringLiteralData).value }, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	// A deref/addr wrapper evaluates nothing of its own, so re-reading it costs
	// exactly what re-reading its operand costs. conditionalExprLower walks the
	// same pair transparently when it hoists assignment-target effects.
	if (node.kind == NodeKind.HiddenDeref || node.kind == NodeKind.HiddenAddr) {
		const d = node.data as HiddenDerefData;
		const inner = cloneIfPure(d.expr);
		if (inner == null) return null;
		const c = node.kind == NodeKind.HiddenDeref ? makeHiddenDeref(inner, node.location) : makeHiddenAddr(inner, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	if (node.kind == NodeKind.CallExpr && isCompilerCheckCall(node)) {
		const d = node.data as CallExprData;
		const args: Node[] = [];
		for (const a of d.arguments) {
			const c = cloneIfPure(a);
			if (c == null) return null;
			args.push(c);
		}
		const c = makeCall(cloneIdent(d.callee, node.location), args, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	return null;
}

// A bound check the access lowering injected re-runs nothing the program can
// observe, so a checked read stays clonable while its own operands are.
function isCompilerCheckCall(node: Node): boolean {
	return isRuntimeProcCall(node, "msChkIndex") || isRuntimeProcCall(node, "msChkArray")
		|| isRuntimeProcCall(node, "msArrayAt") || isRuntimeProcCall(node, "msSpanAt") || isRuntimeProcCall(node, "msMaybeGet");
}

export function isVariantRead(node: Node): boolean {
	if (node.kind != NodeKind.HiddenSubConv || node.variantSlot <= 0) return false;
	const d = node.data as HiddenStdConvData;
	const from = d.convExpr.nodeType;
	return from != null && from.kind == TypeKind.Union
		&& d.convType.kind != TypeKind.Union && !isMaybeType(d.convType);
}

export function clonePlace(node: Node, loc: SourceLocation): Node {
	if (node.kind == NodeKind.Identifier) {
		return cloneIdent(node, loc);
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const clone = makeMember(clonePlace(d.object, loc), d.property, loc);
		clone.nodeType = node.nodeType;
		clone.resolvedSym = node.resolvedSym;
		return clone;
	}
	if (node.kind == NodeKind.HiddenDeref) {
		const clone = makeHiddenDeref(clonePlace((node.data as HiddenDerefData).expr, loc), loc);
		clone.nodeType = node.nodeType;
		return clone;
	}
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const clone = createNodeAt(NodeKind.TypeAssertion, { asExpr: clonePlace(d.asExpr, loc), asType: d.asType } as TypeAssertionData, loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		return clone;
	}
	if (isVariantRead(node)) {
		const d = node.data as HiddenStdConvData;
		const clone = createNodeAt(NodeKind.HiddenSubConv, { convExpr: clonePlace(d.convExpr, loc), convType: d.convType } as NodeData, loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		clone.variantSlot = node.variantSlot;
		return clone;
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const clone = makeArrayAccess(clonePlace(d.array, loc), clonePlace(d.index, loc), loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		return clone;
	}
	if (node.kind == NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const clone = createNodeAt(NodeKind.NumberLiteral, { value: d.value, isFloat: d.isFloat, intVal: d.intVal, outOfRangeText: d.outOfRangeText, isBitPattern: d.isBitPattern } as NumberLiteralData, loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		return clone;
	}
	throw new Error(`internal: re-read of a place that is not a symbol path (node kind ${node.kind})`);
}
