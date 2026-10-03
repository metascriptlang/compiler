import { Node, NodeKind, TypeKind, TypeAssertionData } from "../../ast/node";
import { skipModifier, peelTransparentInstance, createPtr } from "../../checker/types";
import { pointerAddressElement, nativeAddressSource } from "../../checker/pointerAddress";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeArrayAccess, makeNumber, makeHiddenAddr, makeHiddenStdConv } from "../util";

function lowerAddress(node: Node, native: boolean): Node {
	if (node.kind != NodeKind.TypeAssertion) return node;
	const d = node.data as TypeAssertionData;
	let source = skipModifier(d.asExpr.nodeType);
	const target = skipModifier(node.nodeType);
	if (source != null) source = peelTransparentInstance(source);
	if (target != null && target.kind == TypeKind.Span && source != null) {
		let container = source;
		if (container.kind == TypeKind.Ref && container.typeReturn != null) container = peelTransparentInstance(container.typeReturn);
		if (container.kind == TypeKind.Array || container.kind == TypeKind.SizedArray || container.kind == TypeKind.String) {
			const view = makeHiddenStdConv(d.asExpr, target, node.location);
			view.nodeType = node.nodeType;
			return view;
		}
	}
	const elem = pointerAddressElement(d.asExpr.nodeType, node.nodeType);
	if (elem == null) {
		const held = native ? nativeAddressSource(d.asExpr.nodeType, node.nodeType) : null;
		if (held != null) {
			const address = makeHiddenAddr(d.asExpr, node.location);
			address.nodeType = createPtr(held);
			d.asExpr = address;
		}
		return node;
	}
	let place = d.asExpr;
	if (source != null && source.kind == TypeKind.Span) {
		place = makeArrayAccess(place, makeNumber(0, node.location), node.location);
		place.nodeType = elem;
	}
	const address = makeHiddenAddr(place, node.location);
	address.nodeType = node.nodeType;
	return address;
}

export function lowerPointerAddresses(program: Node, ctx: TransformContext): Node {
	const native = !ctx.jsBackend;
	return walkNode(program, (node: Node): Node => lowerAddress(node, native));
}
