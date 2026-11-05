// A store into an Unowned<T> slot counts on the target's second count, not its strong count:
// `slot = v` becomes `msUnownedAssign(&slot, v)` and a literal's `{ slot: v }` becomes
// `{ slot: msUnownedTake(v) }`; both take `v` borrowed, so the analyzer keeps every strong
// count of `v` as it is. An element is a slot too: `arr.push(v)` pushes `msUnownedTake(v)`, an
// array literal takes each element, and `arr.pop()` becomes `msUnownedGive(arr.pop())`, a strong
// value again. Generated lifecycle ops keep their raw stores: destructorLifting already counts
// their Unowned fields.

import { Node, NodeKind, BinaryExprData, ObjectLiteralData, ArrayLiteralData, CallExprData, MemberExprData, HiddenDerefData } from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeCall, makeHiddenAddr, runtimeRef } from "../util";
import { unownedSlotOf, isUnownedSlot, unownedElementOf, getProperty, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

function visit(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.GeneratedOp)) return node;
	mapChildren(node, visit);
	if (node.kind == NodeKind.ObjectLiteral) return takeLiteralFields(node);
	if (node.kind == NodeKind.ArrayLiteral) return takeLiteralElements(node);
	if (node.kind == NodeKind.CallExpr) return countElementCall(node);
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "=" || d.left == null || !unownedSlotOf(d.left)) return node;
	const call = makeCall(runtimeRef("msUnownedAssign", node.location), [makeHiddenAddr(d.left, node.location), d.right], node.location);
	call.nodeType = voidType();
	return call;
}

function take(value: Node): Node {
	const call = makeCall(runtimeRef("msUnownedTake", value.location), [value], value.location);
	call.nodeType = value.nodeType;
	return call;
}

function takeLiteralFields(node: Node): Node {
	const d = node.data as ObjectLiteralData;
	for (let i = 0; i < d.properties.length && i < d.keys.length; i += 1) {
		const value = d.properties[i];
		if (value.kind == NodeKind.ComputedProperty || !isUnownedSlot(getProperty(node.nodeType, d.keys[i]))) continue;
		d.properties[i] = take(value);
	}
	return node;
}

function takeLiteralElements(node: Node): Node {
	if (unownedElementOf(node.nodeType) == null) return node;
	const d = node.data as ArrayLiteralData;
	for (let i = 0; i < d.elements.length; i += 1) {
		if (d.elements[i].kind == NodeKind.SpreadExpr) throw new Error(`internal: a spread into an Unowned element array reached lowerUnownedStores unlowered`);
		d.elements[i] = take(d.elements[i]);
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
	if (recv == null || unownedElementOf(recv.nodeType) == null) return node;
	if (native == "msGenericArrayPop") {
		const give = makeCall(runtimeRef("msUnownedGive", node.location), [node], node.location);
		give.nodeType = node.nodeType;
		return give;
	}
	const args = (node.data as CallExprData).arguments;
	args[args.length - 1] = take(args[args.length - 1]);
	return node;
}

export function lowerUnownedStores(program: Node, ctx: TransformContext): Node {
	mapChildren(program, visit);
	return program;
}
