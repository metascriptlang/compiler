// A store into an Unowned<T> slot counts on the target's second count, not its strong count:
// `slot = v` becomes `msUnownedAssign(&slot, v)` and a literal's `{ slot: v }` becomes
// `{ slot: msUnownedTake(v) }`; both take `v` borrowed, so the analyzer keeps every strong
// count of `v` as it is. An element is a slot too: `arr.push(v)` pushes `msUnownedTake(v)`, an
// array literal takes each element, and `arr.pop()` becomes `msUnownedGive(arr.pop())`, a strong
// value again. A read of a slot as a plain T becomes `msUnownedLoad(slot)`, which stops when the
// target was destroyed and otherwise is a strong value the analyzer releases; a slot copied into
// another slot is no read. Generated lifecycle ops keep their raw stores: destructorLifting
// already counts their Unowned fields.

import { Node, NodeKind, Type, BinaryExprData, ObjectLiteralData, ArrayLiteralData, CallExprData, MemberExprData, ArrayAccessData, HiddenDerefData } from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeCall, makeHiddenAddr, runtimeRef, isRuntimeProcCall } from "../util";
import { unownedSlotOf, isUnownedSlot, isReadonlyUnownedSlot, unownedElementOf, withoutUnowned, getProperty, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

function visit(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.GeneratedOp)) return node;
	if (node.kind == NodeKind.BinaryExpr && isUnownedStore(node.data as BinaryExprData)) return assign(node);
	if (node.kind == NodeKind.HiddenAddr) {
		mapChildren((node.data as HiddenDerefData).expr, visit);
		return node;
	}
	mapChildren(node, visit);
	if (node.kind == NodeKind.ObjectLiteral) return takeLiteralFields(node);
	if (node.kind == NodeKind.ArrayLiteral) return takeLiteralElements(node);
	if (node.kind == NodeKind.CallExpr) return countElementCall(node);
	const slot = readSlotType(node);
	return slot != null ? load(node, slot) : node;
}

function isUnownedStore(d: BinaryExprData): boolean {
	return d.operator == "=" && d.left != null && unownedSlotOf(d.left);
}

function assign(node: Node): Node {
	const d = node.data as BinaryExprData;
	mapChildren(d.left, visit);
	const value = edgeOf(visit(d.right));
	const call = makeCall(runtimeRef(isReadonlyUnownedSlot(slotType(d.left)) ? "msUnownedAssignRo" : "msUnownedAssign", node.location), [makeHiddenAddr(d.left, node.location), value], node.location);
	call.nodeType = voidType();
	return call;
}

function slotType(place: Node): Type | null {
	return place.kind == NodeKind.MemberExpr && place.resolvedSym != null && isUnownedSlot(place.resolvedSym.symbolType) ? place.resolvedSym.symbolType : place.nodeType;
}

function readSlotType(node: Node): Type | null {
	if (node.kind == NodeKind.MemberExpr) return unownedSlotOf(node) ? slotType(node) : null;
	if (node.kind == NodeKind.ArrayAccess) return unownedElementOf((node.data as ArrayAccessData).array.nodeType);
	return null;
}

function load(read: Node, slot: Type): Node {
	const call = makeCall(runtimeRef(isReadonlyUnownedSlot(slot) ? "msUnownedLoadRo" : "msUnownedLoad", read.location), [read], read.location);
	call.nodeType = read.nodeType != null && isUnownedSlot(read.nodeType) ? withoutUnowned(read.nodeType) : read.nodeType;
	return call;
}

function edgeOf(value: Node): Node {
	if (!isRuntimeProcCall(value, "msUnownedLoad") && !isRuntimeProcCall(value, "msUnownedLoadRo")) return value;
	return (value.data as CallExprData).arguments[0];
}

function take(value: Node, slot: Type | null): Node {
	const edge = edgeOf(value);
	const call = makeCall(runtimeRef(isReadonlyUnownedSlot(slot) ? "msUnownedTakeRo" : "msUnownedTake", edge.location), [edge], edge.location);
	call.nodeType = value.nodeType;
	return call;
}

function takeLiteralFields(node: Node): Node {
	const d = node.data as ObjectLiteralData;
	for (let i = 0; i < d.properties.length && i < d.keys.length; i += 1) {
		const value = d.properties[i];
		const slot = getProperty(node.nodeType, d.keys[i]);
		if (value.kind == NodeKind.ComputedProperty || !isUnownedSlot(slot)) continue;
		d.properties[i] = take(value, slot);
	}
	return node;
}

function takeLiteralElements(node: Node): Node {
	const elem = unownedElementOf(node.nodeType);
	if (elem == null) return node;
	const d = node.data as ArrayLiteralData;
	for (let i = 0; i < d.elements.length; i += 1) {
		if (d.elements[i].kind == NodeKind.SpreadExpr) throw new Error(`internal: a spread into an Unowned element array reached lowerUnownedStores unlowered`);
		d.elements[i] = take(d.elements[i], elem);
	}
	return node;
}

function receiverOf(node: Node): Node | null {
	const d = node.data as CallExprData;
	const recv = d.callee.kind == NodeKind.MemberExpr ? (d.callee.data as MemberExprData).object : d.arguments.length > 0 ? d.arguments[0] : null;
	return recv != null && recv.kind == NodeKind.HiddenAddr ? (recv.data as HiddenDerefData).expr : recv;
}

function countElementCall(node: Node): Node {
	const sym = node.resolvedSym != null ? node.resolvedSym : (node.data as CallExprData).callee.resolvedSym;
	if (sym == null) return node;
	const native = sym.nativeName.startsWith("&") ? sym.nativeName.slice(1) : sym.nativeName;
	if (native != "msGenericArrayPush" && native != "msGenericArrayPop") return node;
	const recv = receiverOf(node);
	const elem = recv != null ? unownedElementOf(recv.nodeType) : null;
	if (elem == null) return node;
	if (native == "msGenericArrayPop") {
		const give = makeCall(runtimeRef(isReadonlyUnownedSlot(elem) ? "msUnownedGiveRo" : "msUnownedGive", node.location), [node], node.location);
		give.nodeType = node.nodeType;
		return give;
	}
	const args = (node.data as CallExprData).arguments;
	args[args.length - 1] = take(args[args.length - 1], elem);
	return node;
}

export function lowerUnownedStores(program: Node, ctx: TransformContext): Node {
	mapChildren(program, visit);
	return program;
}
