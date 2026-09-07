// BitSet<E> operand lowering.
//
// The checker gives `Flag.A | Flag.B` the type `BitSet<Flag>`, where a member's
// bit position is its ordinal. The operands still carry the ordinal itself, so
// the raw operator would compute the numeric OR of two ordinals. Rewrite every
// enum-typed operand of a BitSet-typed bitwise expression into `1 << ordinal`.

import { Node, NodeKind, BinaryExprData, Type, TypeKind } from "../../ast/node";
import { bitSetElemType, distinctInstanceRepr } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeNumber } from "../util";

function shiftMember(operand: Node, repr: Type): Node {
	const one = makeNumber(1, operand.location);
	one.nodeType = repr;
	const shifted = makeBinary(one, "<<", operand, operand.location);
	shifted.nodeType = repr;
	return shifted;
}

function isEnumOperand(n: Node | null): boolean {
	return n != null && n.nodeType != null && n.nodeType.kind == TypeKind.Enum;
}

function lowerNode(node: Node): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	if (bitSetElemType(node.nodeType) == null) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "|" && d.operator != "&" && d.operator != "^") return node;
	const repr = distinctInstanceRepr(node.nodeType);
	if (repr == null) return node;
	if (isEnumOperand(d.left)) { d.left = shiftMember(d.left, repr); }
	if (isEnumOperand(d.right)) { d.right = shiftMember(d.right, repr); }
	return node;
}

export function lowerBitSet(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (n: Node): Node => { return lowerNode(n); });
}
