import { Node, NodeKind, HiddenStdConvData, TypeAssertionData } from "./node";
import { isFuncBoundary } from "./visitor";

export function peelStdConv(node: Node): Node {
	let e = node;
	while (e.kind == NodeKind.HiddenStdConv) e = (e.data as HiddenStdConvData).convExpr;
	return e;
}

// `null` → TypeAssertion(TypeAssertion(NullLiteral, "unknown"), "Type")
export function isNullExpr(node: Node): boolean {
	if (node.kind == NodeKind.NullLiteral) return true;
	if (node.kind == NodeKind.TypeAssertion) return isNullExpr((node.data as TypeAssertionData).asExpr);
	return false;
}

export function isRoutineNode(node: Node): boolean {
	return isFuncBoundary(node) || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl;
}

export function isRoutineOrTestNode(node: Node): boolean {
	return isRoutineNode(node) || node.kind == NodeKind.TestDecl;
}

export function isScopeBoundary(node: Node): boolean {
	return isRoutineNode(node) || node.kind == NodeKind.ClassDecl;
}
