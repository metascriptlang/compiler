// Brand erasure — TS branded primitives exist only in the checker (TSGAP
// item 5 S1). Erasing BrandWiden Distincts to their base BEFORE any lowering
// means string/number lowerings and codegen never see a Distinct to peel.

import { Node, Type, TypeKind, TypeFlag } from "../../ast/node";
import { mapChildren } from "../walker";

const ERASE_MAX_DEPTH: int32 = 8;

function eraseBrandType(t: Type | null, depth: int32): Type | null {
	if (t == null || depth > ERASE_MAX_DEPTH) return t;
	if (t.kind == TypeKind.Distinct && (t.typeFlags & (TypeFlag.BrandWiden as int32)) != 0 && t.typeReturn != null) {
		return eraseBrandType(t.typeReturn, depth + 1);
	}
	if (t.kind == TypeKind.Union && t.typeChildren != null) {
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			t.typeChildren[i] = eraseBrandType(t.typeChildren[i], depth + 1) as Type;
		}
	}
	if (t.typeReturn != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray
		|| t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr || t.kind == TypeKind.Span
		|| t.kind == TypeKind.Var || t.kind == TypeKind.Borrow)) {
		t.typeReturn = eraseBrandType(t.typeReturn, depth + 1) as Type;
	}
	return t;
}

function walkErase(node: Node): Node {
	if (node == null) return node;
	if (node.nodeType != null) {
		node.nodeType = eraseBrandType(node.nodeType, 0) as Type;
	}
	mapChildren(node, walkErase);
	return node;
}

export function eraseBrandTypes(program: Node): Node {
	return walkErase(program);
}
