import { Node, NodeKind, NodeFlag, SymbolKind, Type, TypeKind, TypeAssertionData, HiddenDerefData, MemberExprData, OutExprData, BinaryExprData, UpdateExprData, createNodeAt } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode, isAssignOp } from "../walker";
import { skipModifier, unwrapRefNullUnion, isUnknownType, isUnresolvedType, getProperty } from "../../checker/types";
import { GcMode } from "../../checker/context";

export function lowerDownConversions(program: Node, ctx: TransformContext): Node {
	const headersCarryType = ctx.checkerCtx == null || ctx.checkerCtx.gcMode != GcMode.Manual;
	const checks = ctx.objChecks && headersCarryType;
	return walkNode(program, (node: Node): Node => {
		if (!ctx.rangeChecks && node.flags.has(NodeFlag.ConvCheck)) node.flags = node.flags.excl(NodeFlag.ConvCheck);
		if (node.kind == NodeKind.TypeAssertion) {
			if (!checks && node.flags.has(NodeFlag.ObjCheck)) node.flags = node.flags.excl(NodeFlag.ObjCheck);
			return node;
		}
		if (node.kind == NodeKind.HiddenAddr) {
			const d = node.data as HiddenDerefData;
			d.expr = unwrapNarrowedRead(d.expr);
			return node;
		}
		if (node.kind == NodeKind.BinaryExpr) {
			const d = node.data as BinaryExprData;
			if (isAssignOp(d.operator)) d.left = unwrapNarrowedRead(d.left);
			return node;
		}
		if (node.kind == NodeKind.UpdateExpr) {
			const d = node.data as UpdateExprData;
			d.updateArg = unwrapNarrowedRead(d.updateArg);
			return node;
		}
		if (node.kind == NodeKind.OutExpr) {
			const d = node.data as OutExprData;
			d.outArg = unwrapNarrowedRead(d.outArg);
			return node;
		}
		if (node.kind == NodeKind.Identifier) return convertNarrowedRead(node, declaredBindingType(node));
		if (node.kind == NodeKind.MemberExpr) return convertNarrowedRead(node, declaredFieldType(node));
		return node;
	});
}

function declaredBindingType(node: Node): Type | null {
	const sym = node.resolvedSym;
	if (sym == null || (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter)) return null;
	return sym.symbolType;
}

function declaredFieldType(node: Node): Type | null {
	const d = node.data as MemberExprData;
	let owner = d.object;
	if (owner != null && owner.kind == NodeKind.HiddenDeref) owner = (owner.data as HiddenDerefData).expr;
	if (owner == null || owner.nodeType == null) return null;
	const field = getProperty(owner.nodeType, d.property);
	return isUnresolvedType(field) ? null : field;
}

function convertNarrowedRead(node: Node, declared: Type | null): Node {
	const narrowed = node.nodeType;
	if (narrowed == null || declared == null || narrowed == declared) return node;
	if (narrowed.kind != TypeKind.Ref || narrowed.sym == null || narrowed.sym.symbolKind != SymbolKind.Class) return node;
	const bare = skipModifier(declared);
	const held = bare != null && bare.kind == TypeKind.Union ? unwrapRefNullUnion(bare) : bare;
	if (held == null) return node;
	const fromOther = isUnknownType(held) || (held.kind == TypeKind.Ref && held.sym != null && held.sym != narrowed.sym);
	if (!fromOther) return node;
	const conv = createNodeAt(NodeKind.TypeAssertion, { asExpr: node, asType: "" } as TypeAssertionData, node.location);
	conv.nodeType = narrowed;
	conv.flags = conv.flags.incl(NodeFlag.Sem);
	node.nodeType = declared;
	return conv;
}

function unwrapNarrowedRead(n: Node): Node {
	if (n == null || n.kind != NodeKind.TypeAssertion) return n;
	const d = n.data as TypeAssertionData;
	if (d.asType != "" || d.asExpr == null || (d.asExpr.kind != NodeKind.Identifier && d.asExpr.kind != NodeKind.MemberExpr)) return n;
	return d.asExpr;
}
