import { Node, NodeKind, TypeKind, HiddenStdConvData, TypeAssertionData } from "../../ast/node";
import { narrowUnionToVariant } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";

export function projectNarrowedUnions(program: Node, ctx: TransformContext): Node {
	walkNode(program, projectNode);
	return program;
}

function projectNode(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.Identifier) {
		if (node.nodeType == null || node.nodeType.kind == TypeKind.Union) return node;
		const projected = narrowUnionToVariant(node, node.nodeType);
		if (projected != null as unknown as Node) return projected;
		return node;
	}
	if (node.kind == NodeKind.HiddenSubConv && node.variantSlot > 0) unnestProjection(node);
	return node;
}

function unnestProjection(outer: Node): void {
	const d = outer.data as HiddenStdConvData;
	if (d.convType.kind == TypeKind.Union) return;
	let holder: Node = outer;
	let leaf: Node = d.convExpr;
	while (leaf != null && leaf.kind == NodeKind.TypeAssertion) {
		holder = leaf;
		leaf = (leaf.data as TypeAssertionData).asExpr;
	}
	if (leaf == null || leaf.kind != NodeKind.HiddenSubConv || leaf.variantSlot != outer.variantSlot) return;
	const inner = (leaf.data as HiddenStdConvData).convExpr;
	if (holder == outer) {
		d.convExpr = inner;
	} else {
		(holder.data as TypeAssertionData).asExpr = inner;
	}
}
