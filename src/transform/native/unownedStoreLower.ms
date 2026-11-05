// A store into an Unowned<T> slot counts on the target's second count, not its strong count:
// `slot = v` becomes `msUnownedAssign(&slot, v)` and a literal's `{ slot: v }` becomes
// `{ slot: msUnownedTake(v) }`; both take `v` borrowed, so the analyzer keeps every strong
// count of `v` as it is. Generated lifecycle ops keep their raw stores: destructorLifting
// already counts their Unowned fields.

import { Node, NodeKind, BinaryExprData, ObjectLiteralData } from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeCall, makeHiddenAddr, runtimeRef } from "../util";
import { unownedSlotOf, isUnownedSlot, getProperty, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";

function visit(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.GeneratedOp)) return node;
	mapChildren(node, visit);
	if (node.kind == NodeKind.ObjectLiteral) return takeLiteralFields(node);
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "=" || d.left == null || !unownedSlotOf(d.left)) return node;
	const call = makeCall(runtimeRef("msUnownedAssign", node.location), [makeHiddenAddr(d.left, node.location), d.right], node.location);
	call.nodeType = voidType();
	return call;
}

function takeLiteralFields(node: Node): Node {
	const d = node.data as ObjectLiteralData;
	for (let i = 0; i < d.properties.length && i < d.keys.length; i += 1) {
		const value = d.properties[i];
		if (value.kind == NodeKind.ComputedProperty || !isUnownedSlot(getProperty(node.nodeType, d.keys[i]))) continue;
		const take = makeCall(runtimeRef("msUnownedTake", value.location), [value], value.location);
		take.nodeType = value.nodeType;
		d.properties[i] = take;
	}
	return node;
}

export function lowerUnownedStores(program: Node, ctx: TransformContext): Node {
	mapChildren(program, visit);
	return program;
}
