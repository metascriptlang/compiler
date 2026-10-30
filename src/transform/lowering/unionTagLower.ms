import { Node, NodeKind, NodeFlag, TypeKind, Type, SourceLocation, HiddenStdConvData, MemberExprData, BinaryExprData, UnaryExprData, CallExprData, createNode } from "../../ast/node";
import { storesUnionTag, unionSlotOf, narrowUnionToVariant, declaredTagUnionOf, objectHolderSlots, joinBranchTypes } from "../../checker/fit";
import { isLiteralSet, isMaybeType, unwrapRefNullUnion, typeDisplayName, createArray, int32Type, stringType, peelTransparentInstance, createUnion, nullType, jsMemberKind, isUnknownType, isArrayShaped, peelToStructOrUnion, unwrapRef, widenNumberLiteralType } from "../../checker/types";
import { TransformContext, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { callBuiltinKind, isRuntimeProcCall, makeCall, makeIntNumber, makeString, makeTypedObjectLiteral, runtimeRef, syntheticToken } from "../util";
import { memberLabels, accessHead } from "../native/unionProjectLower";

const TAG_FIELD = "$tag";
const VALUE_FIELD = "$v";
const ECHO_BUILTIN_KINDS = ["Echo", "ToString", "UnionText", "UnionDebug"];

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
	return match (node.kind) {
		NodeKind.Identifier => lowerIdentifier(node, field, ctx),
		NodeKind.HiddenSubConv => {
			if (node.variantSlot > 0) return lowerConv(node, field, ctx);
			return node;
		},
		NodeKind.HiddenStdConv => lowerStdConv(node),
		NodeKind.ObjectLiteral => {
			if (node.variantSlot > 0) return lowerLiteral(node);
			return node;
		},
		NodeKind.UnaryExpr => unwrapTypeofOperand(node),
		NodeKind.BinaryExpr => unwrapOperands(node),
		NodeKind.CallExpr => unwrapCallArguments(refuseHostUnion(node, ctx)),
		_ => node,
	};
}

function makeValueRead(object: Node, type: Type, loc: SourceLocation): Node {
	const read = createNode(NodeKind.MemberExpr, { object, property: VALUE_FIELD, isOptional: false }, syntheticToken(loc));
	read.nodeType = type;
	read.flags = read.flags.incl(NodeFlag.Sem);
	return read;
}

function makeTaggedValue(slot: int32, value: Node, ut: Type, loc: SourceLocation): Node {
	const lit = makeTypedObjectLiteral([TAG_FIELD, VALUE_FIELD], [makeIntNumber(slot as int64, loc), value], ut, loc);
	lit.flags = lit.flags.incl(NodeFlag.Sem);
	return lit;
}

function unionValue(n: Node): Node {
	const ut = taggedUnion(n.nodeType);
	if (ut == null) throw new Error("internal: a union value read has no tagged union operand");
	return makeValueRead(n, valueType(ut), n.location);
}

function valueType(ut: Type): Type {
	const kinds: string[] = [];
	const reps: Type[] = [];
	for (const m of ut.typeChildren) {
		const kind = jsMemberKind(m);
		const at = kinds.indexOf(kind);
		if (at < 0) {
			kinds.push(kind);
			reps.push(m);
		} else if (kind == "number") {
			reps[at] = joinBranchTypes([widenNumberLiteralType(reps[at]), widenNumberLiteralType(m)]);
		}
	}
	return reps.length == 1 ? reps[0] : createUnion(reps);
}

function holdsTaggedUnion(n: Node): boolean {
	return n != null && taggedUnion(n.nodeType) != null;
}

function unwrapTypeofOperand(node: Node): Node {
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "typeof") return node;
	if (holdsTaggedUnion(d.operand)) {
		d.operand = unionValue(d.operand);
		return node;
	}
	const t = d.operand != null && d.operand.nodeType != null ? peelTransparentInstance(d.operand.nodeType) : null;
	const ut = t != null && isMaybeType(t) ? taggedUnion(t.typeReturn) : null;
	if (ut != null) d.operand = readUnion(true, d.operand, ut, [], "", createUnion([valueType(ut), nullType()]), node.location);
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
	const echo = ECHO_BUILTIN_KINDS.indexOf(kind) >= 0 || isRuntimeProcCall(node, "msPrintln") || (sym != null && sym.nativeName == "msStringFromValue");
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
	if (md.property == VALUE_FIELD || md.property == TAG_FIELD) return node;
	const ut = taggedUnion(md.object.nodeType);
	if (ut == null) return node;
	md.object = makeValueRead(md.object, memberHaving(ut, md.property), node.location);
	return node;
}

function lowerIdentifier(node: Node, field: string, ctx: TransformContext): Node {
	const t = node.nodeType;
	if (t == null || (t.kind == TypeKind.Union && !isLiteralSet(t))) return node;
	const declared = declaredTagUnionOf(node);
	if (declared == null || !storesUnionTag(declared)) return node;
	const conv: Node | null = narrowUnionToVariant(node, t);
	if (conv == null) return node;
	return projectConv(conv, field, ctx);
}

function lowerConv(node: Node, field: string, ctx: TransformContext): Node {
	const d = node.data as HiddenStdConvData;
	const direct = taggedUnion(d.convType);
	if (direct != null) return wrapValue(node, d, direct);
	if (isMaybeType(d.convType)) {
		const inner = taggedUnion(d.convType.typeReturn);
		if (inner != null) return wrapMaybeValue(node, d, inner);
	}
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
	return makeTaggedValue(slot, d.convExpr, ut, node.location);
}

function slotOf(node: Node, ut: Type): int32 {
	const slot = node.variantSlot - 1;
	if (slot < 0 || slot >= ut.typeChildren.length) throw new Error(`internal: '${typeDisplayName(ut)}' has no tag slot ${slot} a conversion can name`);
	return slot;
}

function wrapValue(node: Node, d: HiddenStdConvData, ut: Type): Node {
	return makeTaggedValue(slotOf(node, ut), d.convExpr, d.convType, node.location);
}

function wrapMaybeValue(node: Node, d: HiddenStdConvData, ut: Type): Node {
	const slot = slotOf(node, ut);
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
	return makeTaggedValue(slot, node, ut, node.location);
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
		return makeValueRead(src, d.convType, loc);
	}
	const allowed: int32[] = !checked ? [] : objectSlot ? holderSlots(d, ut) : [slotOf(node, ut)];
	return readUnion(maybe, src, ut, allowed, accessHead(field, node, ut), d.convType, loc);
}

function readUnion(maybe: boolean, src: Node, ut: Type, allowed: int32[], head: string, type: Type, loc: SourceLocation): Node {
	const slots = createNode(NodeKind.ArrayLiteral, { elements: allowed.map((h: int32): Node => makeIntNumber(h as int64, loc)) }, syntheticToken(loc));
	slots.nodeType = createArray(int32Type());
	const labels = createNode(NodeKind.ArrayLiteral, { elements: memberLabels(ut).map((l: string): Node => makeString(l, loc)) }, syntheticToken(loc));
	labels.nodeType = createArray(stringType());
	const call = makeCall(runtimeRef(maybe ? "msUnionReadMaybe" : "msUnionRead", loc), [src, slots, makeString(head, loc), labels], loc);
	call.nodeType = type;
	return call;
}
