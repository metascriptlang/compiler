import { Node, NodeKind, NodeFlag, TypeKind, Type, SourceLocation, HiddenStdConvData, TypeAssertionData, MemberExprData, BinaryExprData, HiddenDerefData, ArrayAccessData } from "../../ast/node";
import { narrowUnionToVariant, isSlotUnion, projectTagUnionMember, objectHolderSlots } from "../../checker/fit";
import { isMaybeType, unwrapRefNullUnion, typeDisplayName, unionMemberDisplay, isDiscriminatedUnion, getDiscriminantName, int32Type, booleanType, stringType } from "../../checker/types";
import { forEachChild } from "../../ast/visitor";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBool, makeCall, makeConditional, makeTypedIdentResolved, makeMember, makeNumber, makeString, runtimeRef, enumToStringSym } from "../util";

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

function checkedProjectionSource(n: Node, anySource: boolean = false): Type | null {
	if (n == null || n.kind != NodeKind.HiddenSubConv || n.variantSlot <= 0) return null;
	const d = n.data as HiddenStdConvData;
	if (d.convType.kind == TypeKind.Union || isMaybeType(d.convType)) return null;
	const ut = d.convExpr.nodeType;
	if (ut == null || isMaybeType(ut) || !isSlotUnion(ut) || (!anySource && !isLocation(d.convExpr))) return null;
	return ut;
}

function memberLabels(ut: Type): string[] {
	const labels: string[] = [];
	const du = isDiscriminatedUnion(ut);
	for (let vi = 0; vi < ut.typeChildren.length; vi += 1) {
		if (du && vi + 1 < ut.typeNames.length) {
			const stored = ut.typeNames[vi + 1];
			const dot = stored.lastIndexOf(".");
			labels.push(getDiscriminantName(ut) + " = " + (dot >= 0 ? stored.slice(dot + 1, stored.length) : stored));
		} else {
			labels.push(unionMemberDisplay(ut.typeChildren[vi]));
		}
	}
	return labels;
}

function unionDisplay(ut: Type): string {
	if (ut.sym != null && ut.sym.name != "") return ut.sym.name;
	const names: string[] = [];
	for (const m of ut.typeChildren) names.push(unionMemberDisplay(m));
	return names.join(" | ");
}

function accessHead(field: string, projection: Node, ut: Type): string {
	const what = field != "" ? `field '${field}'` : `member '${unionMemberDisplay((projection.data as HiddenStdConvData).convType)}'`;
	return `${what} is not accessible for type '${unionDisplay(ut)}' using '`;
}

export function checkVariantReads(program: Node, ctx: TransformContext): Node {
	if (!ctx.rangeChecks) return program;
	guardReads(program, ctx);
	return program;
}

function guardReads(node: Node, ctx: TransformContext): void {
	if (node == null) return;
	if (node.kind == NodeKind.HiddenSubConv && node.flags.has(NodeFlag.ObjectSlot)) {
		guardObjectSlot(node);
		forEachChild(node, (c: Node): void => guardReads(c, ctx));
		return;
	}
	if (node.kind == NodeKind.TypeAssertion && !node.flags.has(NodeFlag.ConvCheck)) {
		const cast = (node.data as TypeAssertionData).asExpr;
		if (cast != null && cast.kind == NodeKind.HiddenSubConv && !cast.flags.has(NodeFlag.ConvCheck)) {
			forEachChild(cast, (c: Node): void => guardReads(c, ctx));
			return;
		}
	}
	if (node.kind == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		guardProjection(md.object, md.property, ctx, false);
	}
	guardProjection(node, "", ctx, node.flags.has(NodeFlag.ConvCheck));
	forEachChild(node, (c: Node): void => guardReads(c, ctx));
}

function guardProjection(p: Node, field: string, ctx: TransformContext, anySource: boolean): void {
	if (p != null && p.flags.has(NodeFlag.ObjectSlot)) return;
	const ut = checkedProjectionSource(p, anySource);
	if (ut == null) return;
	const d = p.data as HiddenStdConvData;
	const loc = p.location;
	const u = d.convExpr;
	const labels = memberLabels(ut).join("|");
	const check = isLocation(u) ? "msVariantAccess" : "msVariantAccessVal";
	const access = makeCall(runtimeRef(check, loc), [u, makeNumber(p.variantSlot - 1, loc), makeString(accessHead(field, p, ut), loc), makeString(labels, loc)], loc);
	access.nodeType = ut;
	d.convExpr = access;
}

function guardObjectSlot(p: Node): void {
	const d = p.data as HiddenStdConvData;
	const source = d.convExpr.nodeType;
	const carried = source != null && isMaybeType(source);
	const ut = carried ? source!.typeReturn : source;
	const member = d.convType.kind == TypeKind.Union ? unwrapRefNullUnion(d.convType) : d.convType;
	if (ut == null || member == null || !isSlotUnion(ut)) throw new Error(`internal: an object-slot projection to ${typeDisplayName(d.convType)} reads no tagged union`);
	const holders = objectHolderSlots(ut, member);
	if (holders.length == 0) throw new Error(`internal: '${unionDisplay(ut)}' has no slot holding ${typeDisplayName(member)}`);
	let mask = 0;
	for (const h of holders) {
		if (h > 52) throw new Error(`internal: '${unionDisplay(ut)}' holds an object in slot ${h}, past the 53 slots a conversion check can name`);
		let bit = 1;
		for (let i = 0; i < h; i += 1) bit = bit * 2;
		mask += bit;
	}
	const loc = p.location;
	const u = d.convExpr;
	const check = carried ? "msMaybeVariantObject" : isLocation(u) ? "msVariantObject" : "msVariantObjectVal";
	const access = makeCall(runtimeRef(check, loc), [u, makeNumber(mask, loc), makeString(accessHead("", p, ut), loc), makeString(memberLabels(ut).join("|"), loc)], loc);
	access.nodeType = source;
	d.convExpr = access;
	if (carried) p.flags = p.flags.incl(NodeFlag.NoFieldCheck);
}

export function checkVariantReadsJS(program: Node, ctx: TransformContext): Node {
	guardReadsJS(program, ctx);
	return program;
}

function guardReadsJS(node: Node, ctx: TransformContext): void {
	if (node == null) return;
	if (node.kind == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		if (md.object.kind == NodeKind.Identifier) md.object = projectIdentifier(md.object);
		guardProjectionJS(md.object, md.property, ctx);
	}
	forEachChild(node, (c: Node): void => guardReadsJS(c, ctx));
}

function discriminantValue(ut: Type, slot: int32, loc: SourceLocation): Node | null {
	const en = ut.typeExtra;
	if (en == null || en.kind != TypeKind.Enum || slot + 1 >= ut.typeNames.length) return null;
	const stored = ut.typeNames[slot + 1];
	const dot = stored.lastIndexOf(".");
	const bare = dot >= 0 ? stored.slice(dot + 1, stored.length) : stored;
	for (let i = 0; i < en.typeNames.length; i += 1) {
		if (en.typeNames[i] != bare) continue;
		const v = i < en.typeChildren.length ? en.typeChildren[i].typeValue : i;
		return makeNumber(v, loc);
	}
	return null;
}

function guardProjectionJS(p: Node, field: string, ctx: TransformContext): void {
	const ut = checkedProjectionSource(p);
	if (ut == null || !isDiscriminatedUnion(ut)) return;
	const d = p.data as HiddenStdConvData;
	const loc = p.location;
	const u = d.convExpr;
	const want = discriminantValue(ut, p.variantSlot - 1, loc);
	if (want == null) return;
	const disc = getDiscriminantName(ut);
	const same = makeBinary(makeMember(cloneNodeKeepSem(u), disc, loc), "==", want, loc);
	const en = ut.typeExtra;
	if (en == null) return;
	const actual = makeCall(makeTypedIdentResolved(enumToStringSym(ctx, en), null, loc), [makeMember(cloneNodeKeepSem(u), disc, loc)], loc);
	actual.nodeType = stringType();
	const fail = makeCall(runtimeRef("msFieldError", loc), [makeString(accessHead(field, p, ut) + disc + " = ", loc), actual], loc);
	const guarded = makeConditional(same, u, fail, loc);
	guarded.nodeType = ut;
	d.convExpr = guarded;
}
