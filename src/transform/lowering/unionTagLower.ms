import { Node, NodeKind, NodeFlag, TypeKind, Type, HiddenStdConvData, MemberExprData, BinaryExprData, UnaryExprData, CallExprData, createNode } from "../../ast/node";
import { storesUnionTag, unionSlotOf, narrowUnionToVariant, declaredTagUnionOf, objectHolderSlots } from "../../checker/fit";
import { isMaybeType, unwrapRefNullUnion, typeDisplayName, createArray, int32Type, stringType, peelTransparentInstance, createUnion, jsMemberKind, isUnknownType, isArrayShaped, peelToStructOrUnion, unwrapRef } from "../../checker/types";
import { TransformContext, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { callBuiltinKind, isRuntimeProcCall, makeCall, makeIntNumber, makeString, makeTypedObjectLiteral, runtimeRef, syntheticToken } from "../util";
import { memberLabels, accessHead } from "../native/unionProjectLower";

export function lowerUnionTags(program: Node, ctx: TransformContext): Node {
	return lowerNode(program, "", ctx);
}

function taggedUnion(t: Type | null): Type | null {
	if (t == null) return null;
	const u = peelTransparentInstance(t);
	return u.kind == TypeKind.Union && storesUnionTag(u) ? u : null;
}

function lowerNode(node: Node, field: string, ctx: TransformContext): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		md.object = lowerNode(md.object, md.property, ctx);
		return readFieldOfValue(node, md);
	}
	mapChildren(node, (c: Node): Node => lowerNode(c, "", ctx));
	if (node.kind == NodeKind.Identifier) return lowerIdentifier(node, field, ctx);
	if (node.kind == NodeKind.HiddenSubConv && node.variantSlot > 0) return lowerConv(node, field, ctx);
	if (node.kind == NodeKind.HiddenStdConv) return lowerStdConv(node);
	if (node.kind == NodeKind.ObjectLiteral && node.variantSlot > 0) return lowerLiteral(node);
	if (node.kind == NodeKind.UnaryExpr) return unwrapTypeofOperand(node);
	if (node.kind == NodeKind.BinaryExpr) return unwrapOperands(node);
	if (node.kind == NodeKind.CallExpr) return unwrapCallArguments(refuseHostUnion(node, ctx));
	return node;
}

function unionValue(n: Node): Node {
	const ut = taggedUnion(n.nodeType);
	if (ut == null) throw new Error("internal: a union value read has no tagged union operand");
	const read = createNode(NodeKind.MemberExpr, { object: n, property: "$v", isOptional: false }, syntheticToken(n.location));
	read.nodeType = valueType(ut);
	read.flags = read.flags.incl(NodeFlag.Sem);
	return read;
}

function valueType(ut: Type): Type {
	const kinds: string[] = [];
	const reps: Type[] = [];
	for (const m of ut.typeChildren) {
		const kind = jsMemberKind(m);
		if (kinds.indexOf(kind) >= 0) continue;
		kinds.push(kind);
		reps.push(m);
	}
	return reps.length == 1 ? reps[0] : createUnion(reps);
}

function holdsTaggedUnion(n: Node): boolean {
	return n != null && taggedUnion(n.nodeType) != null;
}

function unwrapTypeofOperand(node: Node): Node {
	const d = node.data as UnaryExprData;
	if (d.unaryOp == "typeof" && holdsTaggedUnion(d.operand)) d.operand = unionValue(d.operand);
	return node;
}

function unwrapOperands(node: Node): Node {
	const d = node.data as BinaryExprData;
	const op = d.operator;
	const concat = op == "+" && (isStringTyped(d.left) || isStringTyped(d.right));
	const compare = op == "==" || op == "!=" || op == "===" || op == "!==";
	if (!concat && !compare) return node;
	const left = holdsTaggedUnion(d.left);
	const right = holdsTaggedUnion(d.right);
	if (!left && !right) return node;
	if (left) d.left = unionValue(d.left);
	if (right) d.right = unionValue(d.right);
	return node;
}

function isStringTyped(n: Node): boolean {
	return n != null && n.nodeType != null && n.nodeType.kind == TypeKind.String;
}

function refuseHostUnion(node: Node, ctx: TransformContext): Node {
	const sym = (node.data as CallExprData).callee.resolvedSym;
	if (sym == null || sym.nativeName == "" || node.nodeType == null) return node;
	const t = node.nodeType;
	const ut = taggedUnion(isMaybeType(t) ? t.typeReturn : t);
	if (ut == null) return node;
	reportTransformError(ctx, `'${sym.name}' returns '${typeDisplayName(ut)}' from outside MetaScript, and a host value carries no tag naming its member; return one member type, or build the union in a MetaScript function`, node.location);
	return node;
}

function unwrapCallArguments(node: Node): Node {
	const d = node.data as CallExprData;
	const kind = callBuiltinKind(node);
	const sym = d.callee.resolvedSym;
	const echo = kind == "Echo" || kind == "ToString" || isRuntimeProcCall(node, "msPrintln") || (sym != null && sym.nativeName == "msStringFromValue");
	if (sym == null && !echo) return node;
	const formals = sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function && sym.nativeName != "" ? sym.symbolType.typeChildren : null;
	for (let i = 0; i < d.arguments.length; i += 1) {
		if (!holdsTaggedUnion(d.arguments[i])) continue;
		const formal = formals != null && i < formals.length ? formals[i] : null;
		if (echo || (formal != null && isUnknownType(formal))) d.arguments[i] = unionValue(d.arguments[i]);
	}
	return node;
}

function memberHaving(ut: Type, prop: string): Type {
	for (const m of ut.typeChildren) {
		const body = peelToStructOrUnion(unwrapRef(m));
		if (body != null && body.kind == TypeKind.Struct && body.typeNames.indexOf(prop) >= 0) return m;
		if (prop == "length" && isArrayShaped(m)) return m;
	}
	return ut.typeChildren[0];
}

function readFieldOfValue(node: Node, md: MemberExprData): Node {
	if (md.property == "$v" || md.property == "$tag") return node;
	const ut = taggedUnion(md.object.nodeType);
	if (ut == null) return node;
	const read = createNode(NodeKind.MemberExpr, { object: md.object, property: "$v", isOptional: false }, syntheticToken(node.location));
	read.nodeType = memberHaving(ut, md.property);
	read.flags = read.flags.incl(NodeFlag.Sem);
	md.object = read;
	return node;
}

function lowerIdentifier(node: Node, field: string, ctx: TransformContext): Node {
	const t = node.nodeType;
	if (t == null || t.kind == TypeKind.Union) return node;
	const declared = declaredTagUnionOf(node);
	if (declared == null || !storesUnionTag(declared)) return node;
	const conv = narrowUnionToVariant(node, t);
	if (conv == null as unknown as Node) return node;
	return projectConv(conv, field, ctx);
}

function lowerConv(node: Node, field: string, ctx: TransformContext): Node {
	const d = node.data as HiddenStdConvData;
	if (taggedUnion(d.convType) != null) return wrapValue(node, d, d.convType);
	if (isMaybeType(d.convType) && taggedUnion(d.convType.typeReturn) != null) return wrapMaybeValue(node, d);
	const from = d.convExpr.nodeType;
	if (from == null) return node;
	if (taggedUnion(from) != null || (isMaybeType(from) && taggedUnion(from.typeReturn) != null)) return projectConv(node, field, ctx);
	return node;
}

function lowerStdConv(node: Node): Node {
	const d = node.data as HiddenStdConvData;
	const ut = taggedUnion(d.convType);
	const from = d.convExpr.nodeType;
	if (ut == null || from == null || taggedUnion(from) != null) return node;
	const slot = unionSlotOf(ut, from);
	if (slot < 0) throw new Error(`internal: '${typeDisplayName(ut)}' has no member slot for a ${typeDisplayName(from)} operand`);
	const lit = makeTypedObjectLiteral(["$tag", "$v"], [makeIntNumber(slot as int64, node.location), d.convExpr], ut, node.location);
	lit.flags = lit.flags.incl(NodeFlag.Sem);
	return lit;
}

function slotOf(node: Node, ut: Type): int32 {
	const slot = node.variantSlot - 1;
	if (slot < 0 || slot >= ut.typeChildren.length) throw new Error(`internal: '${typeDisplayName(ut)}' has no tag slot ${slot} a conversion can name`);
	return slot;
}

function wrapValue(node: Node, d: HiddenStdConvData, ut: Type): Node {
	const slot = slotOf(node, taggedUnion(ut)!);
	const lit = makeTypedObjectLiteral(["$tag", "$v"], [makeIntNumber(slot as int64, node.location), d.convExpr], ut, node.location);
	lit.flags = lit.flags.incl(NodeFlag.Sem);
	return lit;
}

function wrapMaybeValue(node: Node, d: HiddenStdConvData): Node {
	const slot = slotOf(node, taggedUnion(d.convType.typeReturn)!);
	const call = makeCall(runtimeRef("msUnionWrapMaybe", node.location), [d.convExpr, makeIntNumber(slot as int64, node.location)], node.location);
	call.nodeType = d.convType;
	return call;
}

function lowerLiteral(node: Node): Node {
	const ut = taggedUnion(node.nodeType);
	if (ut == null) return node;
	const slot = slotOf(node, ut);
	node.nodeType = ut.typeChildren[slot];
	node.variantSlot = 0;
	const lit = makeTypedObjectLiteral(["$tag", "$v"], [makeIntNumber(slot as int64, node.location), node], ut, node.location);
	lit.flags = lit.flags.incl(NodeFlag.Sem);
	return lit;
}

function isLocation(n: Node): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind == NodeKind.MemberExpr) return isLocation((n.data as MemberExprData).object);
	return false;
}

function holderSlots(d: HiddenStdConvData, ut: Type): int32[] {
	const member = d.convType.kind == TypeKind.Union ? unwrapRefNullUnion(d.convType) : d.convType;
	if (member == null) throw new Error(`internal: an object-slot projection to ${typeDisplayName(d.convType)} names no member`);
	const holders = objectHolderSlots(ut, member);
	if (holders.length == 0) throw new Error(`internal: '${typeDisplayName(ut)}' has no slot holding ${typeDisplayName(member)}`);
	return holders;
}

function projectConv(node: Node, field: string, ctx: TransformContext): Node {
	const d = node.data as HiddenStdConvData;
	const src = d.convExpr;
	const from = src.nodeType;
	if (from == null) throw new Error("internal: a union projection reads an untyped operand");
	const maybe = isMaybeType(from);
	const ut = taggedUnion(maybe ? from.typeReturn : from);
	if (ut == null) throw new Error(`internal: a union projection to ${typeDisplayName(d.convType)} reads no tagged union`);
	const loc = node.location;
	const objectSlot = node.flags.has(NodeFlag.ObjectSlot);
	const checked = ctx.rangeChecks && (objectSlot || node.flags.has(NodeFlag.ConvCheck) || (field != "" && isLocation(src)));
	if (!checked && !maybe) {
		const read = createNode(NodeKind.MemberExpr, { object: src, property: "$v", isOptional: false }, syntheticToken(loc));
		read.nodeType = d.convType;
		read.flags = read.flags.incl(NodeFlag.Sem);
		return read;
	}
	const allowed: int32[] = !checked ? [] : objectSlot ? holderSlots(d, ut) : [slotOf(node, ut)];
	const slots = createNode(NodeKind.ArrayLiteral, { elements: allowed.map((h: int32): Node => makeIntNumber(h as int64, loc)) }, syntheticToken(loc));
	slots.nodeType = createArray(int32Type());
	const labels = createNode(NodeKind.ArrayLiteral, { elements: memberLabels(ut).map((l: string): Node => makeString(l, loc)) }, syntheticToken(loc));
	labels.nodeType = createArray(stringType());
	const call = makeCall(runtimeRef(maybe ? "msUnionReadMaybe" : "msUnionRead", loc), [src, slots, makeString(accessHead(field, node, ut), loc), labels], loc);
	call.nodeType = d.convType;
	return call;
}
