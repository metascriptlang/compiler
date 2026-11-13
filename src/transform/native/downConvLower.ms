import { Node, NodeKind, NodeFlag, SymbolKind, Type, TypeKind, TypeAssertionData, HiddenDerefData, MemberExprData, OutExprData, BinaryExprData, UpdateExprData, createNodeAt } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { isAssignOp } from "../../ast/operators";
import { skipModifier, unwrapRefNullUnion, isUnknownType, isUnresolvedType, declaredFieldOfRead } from "../../checker/types";
import { GcMode } from "../../checker/context";
import { widenVariantToUnion } from "../../checker/fit";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { makeBinary, makeConditional, makeTypedIdentResolved } from "../util";

export function lowerDownConversions(program: Node, ctx: TransformContext): Node {
	const headersCarryType = ctx.checkerCtx == null || ctx.checkerCtx.gcMode != GcMode.Manual;
	const checks = ctx.objChecks && headersCarryType;
	return walkNode(program, (node: Node): Node => {
		if (!ctx.rangeChecks && node.flags.has(NodeFlag.ConvCheck) && node.kind != NodeKind.MemberExpr) node.flags = node.flags.excl(NodeFlag.ConvCheck);
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
	const field = declaredFieldOfRead(owner.nodeType, d.property, node.resolvedSym != null ? node.resolvedSym.duVariantSlot : 0);
	return isUnresolvedType(field) ? null : field;
}

// A reference narrowed to a union of classes (`e instanceof A || e instanceof B`) is still the one pointer
// its declaration holds, while a value of that union type is a tagged carrier: the read tags the pointer
// with the member it is an instance of, as converting `new A()` into the union does.
function carrierOfStoredClass(node: Node, narrowed: Type, held: Type): Node {
	const members = narrowed.typeChildren;
	if (members == null || members.length < 2) return node;
	for (const m of members) {
		if (m == null || m.kind != TypeKind.Ref || m.sym == null || m.sym.symbolKind != SymbolKind.Class) return node;
	}
	let carrier: Node | null = null;
	for (let i = members.length - 1; i >= 0; i -= 1) {
		const m = members[i];
		const stored = cloneNodeKeepSem(node);
		stored.nodeType = held;
		const cast = createNodeAt(NodeKind.TypeAssertion, { asExpr: stored, asType: "" } as TypeAssertionData, node.location);
		cast.nodeType = m;
		cast.flags = cast.flags.incl(NodeFlag.Sem);
		const tagged = widenVariantToUnion(cast, narrowed, m);
		if (tagged == null as unknown as Node) return node;
		if (carrier == null) {
			carrier = tagged;
			continue;
		}
		const probe = cloneNodeKeepSem(node);
		probe.nodeType = held;
		const test = makeBinary(probe, "instanceof", makeTypedIdentResolved(m.sym!, null, node.location), node.location);
		carrier = makeConditional(test, tagged, carrier, node.location);
		carrier.nodeType = narrowed;
	}
	return carrier!;
}

function convertNarrowedRead(node: Node, declared: Type | null): Node {
	const narrowed = node.nodeType;
	if (narrowed == null || declared == null || narrowed == declared) return node;
	const bare = skipModifier(declared);
	const held = bare != null && bare.kind == TypeKind.Union ? unwrapRefNullUnion(bare) : bare;
	if (held == null) return node;
	if (narrowed.kind == TypeKind.Union) return held.kind == TypeKind.Ref && held.sym != null && held.sym.symbolKind == SymbolKind.Class ? carrierOfStoredClass(node, narrowed, held) : node;
	if (narrowed.kind != TypeKind.Ref || narrowed.sym == null || narrowed.sym.symbolKind != SymbolKind.Class) return node;
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
