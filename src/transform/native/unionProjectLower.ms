import { Node, NodeKind, TypeKind, Type, HiddenStdConvData, TypeAssertionData, MemberExprData, BinaryExprData, HiddenDerefData, ArrayAccessData } from "../../ast/node";
import { narrowUnionToVariant, isSlotUnion, projectTagUnionMember } from "../../checker/fit";
import { int32Type, booleanType } from "../../checker/types";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBool, makeMember, makeNumber } from "../util";

export function projectNarrowedUnions(program: Node, ctx: TransformContext): Node {
	walkNode(program, projectNode);
	return program;
}

function projectNode(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.Identifier) return projectIdentifier(node);
	if (node.kind == NodeKind.HiddenSubConv && node.variantSlot > 0) return unnestProjection(node);
	if (node.kind == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "instanceof") return lowerUnionInstanceof(node);
	return node;
}

function projectIdentifier(node: Node): Node {
	if (node.nodeType == null || node.nodeType.kind == TypeKind.Union) return node;
	const projected = narrowUnionToVariant(node, node.nodeType);
	if (projected != null as unknown as Node) return projected;
	return node;
}

function unnestProjection(outer: Node): Node {
	const d = outer.data as HiddenStdConvData;
	if (d.convType.kind == TypeKind.Union) return outer;
	let leaf: Node = d.convExpr;
	while (leaf != null && leaf.kind == NodeKind.TypeAssertion) leaf = (leaf.data as TypeAssertionData).asExpr;
	if (leaf == null || leaf.kind != NodeKind.HiddenSubConv || leaf.variantSlot != outer.variantSlot) return outer;
	if (leaf == d.convExpr) {
		d.convExpr = (leaf.data as HiddenStdConvData).convExpr;
		return outer;
	}
	return d.convExpr;
}

function isClassMember(m: Type): boolean {
	return m.kind == TypeKind.Ref && m.typeReturn != null && m.typeReturn.kind == TypeKind.Struct;
}

function isLocation(n: Node): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind == NodeKind.MemberExpr) return isLocation((n.data as MemberExprData).object);
	if (n.kind == NodeKind.HiddenDeref) return isLocation((n.data as HiddenDerefData).expr);
	if (n.kind == NodeKind.ArrayAccess) {
		const ad = n.data as ArrayAccessData;
		return isLocation(ad.array) && (ad.index.kind == NodeKind.Identifier || ad.index.kind == NodeKind.NumberLiteral);
	}
	return false;
}

function lowerUnionInstanceof(node: Node): Node {
	const d = node.data as BinaryExprData;
	const u = d.left;
	const ut = u.nodeType;
	if (ut == null || !isSlotUnion(ut) || !isLocation(u)) return node;
	const loc = node.location;
	let anyMember: Node | null = null;
	for (let vi = 0; vi < ut.typeChildren.length; vi += 1) {
		const m = ut.typeChildren[vi];
		if (!isClassMember(m)) continue;
		const tag = makeMember(cloneNodeKeepSem(u), "_tag", loc);
		tag.nodeType = int32Type();
		const isSlot = makeBinary(tag, "==", makeNumber(vi, loc), loc);
		const inst = makeBinary(projectTagUnionMember(cloneNodeKeepSem(u), ut, m), "instanceof", cloneNodeKeepSem(d.right), loc);
		inst.nodeType = booleanType();
		const term = makeBinary(isSlot, "&&", inst, loc);
		anyMember = anyMember == null ? term : makeBinary(anyMember, "||", term, loc);
	}
	return anyMember == null ? makeBool(false, loc) : anyMember;
}
