import { Node, NodeKind, NodeFlag, TypeKind, TypeFlag, Type, Symbol, SymbolKind, SourceLocation, HiddenStdConvData, BinaryExprData, ProgramData, CallExprData, ArrayLiteralData, ObjectLiteralData } from "../../ast/node";
import { convertsBetweenUnions, unionMemberSlots, storesUnionTag, nullableUnionPayloads, isSlotUnion, booleanLiteralSlots, wrapInConv, convertStoredUnionRead } from "../../checker/fit";
import { instantiatedUnionBehind, isTagCarriedUnion, inlineVariantStruct, storesNothing, peelToStruct, unwrapRef, peelTransparentInstance, typeDisplayName, unionMemberDisplay, jsMemberKind, runtimeClassSym, classParentOf, int32Type, booleanType, stringType, createArray, unknownType, isNumeric, booleanLiteralValue } from "../../checker/types";
import { hashToBase36, typeKey } from "../../codegen/c/types";
import { sameType } from "../../checker/compat";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBlock, makeCall, makeExprStmt, makeFnDecl, makeIf, makeIdentResolved, makeIntNumber, makeMember, makeReturn, makeString, makeTypedIdentResolved, makeTypedObjectLiteral, makeUnary, runtimeRef, syntheticToken, makeBool, makeNull, makeHiddenSubConv } from "../util";
import { createNode } from "../../ast/node";
import { memberLabels } from "../native/unionProjectLower";
import { makeSymbol } from "../../checker/symbol";
import { monoInstanceName } from "../../monomorphize/registry";

// A value moving between two unions is re-tagged member by member: one generated
// routine per union pair cases on the source's held member, projects it out and
// widens it into the target's slot for the same type. A member the target lacks
// stops the program with the member-check error.

let _convNames: string[] = [];
let _convSyms: Symbol[] = [];
let _convDecls: Node[] = [];

export function lowerUnionConversions(program: Node, ctx: TransformContext): Node {
	_convNames = [];
	_convSyms = [];
	_convDecls = [];
	const result = walkNode(program, (node: Node): Node => lowerConversion(node, ctx));
	if (_convDecls.length > 0 && result.kind == NodeKind.Program) {
		const pd = result.data as ProgramData;
		for (const decl of _convDecls) pd.programStmts.push(decl);
	}
	_convNames = [];
	_convSyms = [];
	_convDecls = [];
	return result;
}

function unionPair(node: Node): Type[] | null {
	if (node.kind != NodeKind.HiddenSubConv || node.variantSlot > 0) return null;
	const d = node.data as HiddenStdConvData;
	if (d.convExpr == null || d.convExpr.nodeType == null || d.convType == null) return null;
	const source = peelTransparentInstance(d.convExpr.nodeType);
	const target = peelTransparentInstance(d.convType);
	if (nullableUnionPayloads(source, target) != null) return [source, target];
	if (node.flags.has(NodeFlag.ConvCheck) && target.kind != TypeKind.Union && isSlotUnion(source)) return [source, target];
	return convertsBetweenUnions(source, target) ? [source, target] : null;
}

function targetMembers(target: Type): Type[] {
	return target.kind == TypeKind.Union ? target.typeChildren : [target];
}

function lowerConversion(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.BinaryExpr) return lowerComparison(node, ctx);
	if (!ctx.jsBackend && !ctx.raiserBackend) storeNarrowedReads(node, ctx);
	if (!ctx.jsBackend && !ctx.raiserBackend && node.kind == NodeKind.HiddenSubConv && node.variantSlot > 0) buildArm(node, ctx);
	const pair = unionPair(node);
	if (pair == null) return node;
	const source = pair[0];
	const target = pair[1];
	const operand = (node.data as HiddenStdConvData).convExpr;
	const payloads = nullableUnionPayloads(source, target);
	if (payloads != null && passesUnchanged(payloads[0], payloads[1], ctx)) {
		operand.nodeType = node.nodeType;
		return operand;
	}
	if (payloads != null) {
		const wrapped = makeCall(makeTypedIdentResolved(nullableConversionRoutine(source, target, payloads[0], payloads[1], ctx, node.location), null, node.location), [operand], node.location);
		wrapped.nodeType = node.nodeType;
		return wrapped;
	}
	if (passesUnchanged(source, target, ctx)) {
		operand.nodeType = node.nodeType;
		return operand;
	}
	const call = makeCall(makeTypedIdentResolved(conversionRoutine(source, target, ctx, node.location), null, node.location), [operand], node.location);
	call.nodeType = node.nodeType;
	return call;
}

function buildArm(node: Node, ctx: TransformContext): void {
	const d = node.data as HiddenStdConvData;
	const union = d.convType == null ? null : instantiatedUnionBehind(d.convType);
	const from = d.convExpr.nodeType;
	if (union == null || !isTagCarriedUnion(union) || from == null || node.variantSlot > union.typeChildren.length) return;
	const slot = node.variantSlot - 1;
	const arm = inlineVariantStruct(union.typeChildren[slot]);
	const source = peelToStruct(unwrapRef(from));
	if (arm == null || source == null || source == arm || source.typeFlags.has(TypeFlag.DuVariant)) return;
	if (!omitsField(arm)) return;
	const call = makeCall(makeTypedIdentResolved(armRoutine(union, slot, arm, from, source, ctx, node.location), null, node.location), [d.convExpr], node.location);
	call.nodeType = union.typeChildren[slot];
	d.convExpr = call;
}

function omitsField(arm: Type): boolean {
	for (const f of arm.typeChildren) {
		if (storesNothing(arm, f)) return true;
	}
	return false;
}

function armRoutine(union: Type, slot: int32, arm: Type, from: Type, source: Type, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = "msArmConv_" + hashToBase36(typeKey(from) + ">" + typeKey(union) + "." + slot);
	const at = _convNames.indexOf(name);
	if (at >= 0) return _convSyms[at];
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_convNames.push(name);
	_convSyms.push(sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", from);
	const keys: string[] = [];
	const values: Node[] = [];
	for (let i = 0; i < arm.typeNames.length; i += 1) {
		if (storesNothing(arm, arm.typeChildren[i])) continue;
		if (!source.typeNames.includes(arm.typeNames[i])) throw new Error(`internal: object '${typeDisplayName(source)}' has no field '${arm.typeNames[i]}' of the union arm it converts into`);
		keys.push(arm.typeNames[i]);
		values.push(makeMember(read(valueSym, from, loc), arm.typeNames[i], loc));
	}
	const member = union.typeChildren[slot];
	const literal = makeTypedObjectLiteral(keys, values, member, loc);
	literal.flags = literal.flags.incl(NodeFlag.Sem);
	return declareRoutine(sym, name, [valueSym], [from], member, [makeReturn(literal, loc)], loc);
}

function storeNarrowedReads(node: Node, ctx: TransformContext): void {
	if (node.kind == NodeKind.ArrayLiteral) {
		storeEach((node.data as ArrayLiteralData).elements, null, ctx);
	} else if (node.kind == NodeKind.ObjectLiteral) {
		storeEach((node.data as ObjectLiteralData).properties, null, ctx);
	} else if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const fn = d.callee.nodeType;
		if (fn != null && fn.kind == TypeKind.Function && fn.typeChildren.length == d.arguments.length) storeEach(d.arguments, fn.typeChildren, ctx);
	}
}

function storeEach(values: Node[], formals: Type[] | null, ctx: TransformContext): void {
	for (let i = 0; i < values.length; i += 1) {
		const v = values[i];
		const narrowed = v.nodeType;
		if ((v.kind != NodeKind.Identifier && v.kind != NodeKind.MemberExpr) || narrowed == null) continue;
		if (formals != null && !sameType(formals[i], narrowed)) continue;
		const read = convertStoredUnionRead(v, narrowed, narrowed);
		if (read != null) values[i] = lowerConversion(read, ctx);
	}
}

function comparesByKind(kind: string): boolean {
	return kind == "number" || kind == "string" || kind == "boolean" || kind == "bigint";
}

// `u === v` with a union on one side and a value of a primitive kind on the other
// is true when the union holds a member of that kind and the member equals the value.
function lowerComparison(node: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend || ctx.raiserBackend) return node;
	const d = node.data as BinaryExprData;
	const negated = d.operator == "!=" || d.operator == "!==";
	if (!negated && d.operator != "==" && d.operator != "===") return node;
	if (d.left.nodeType == null || d.right.nodeType == null) return node;
	const left = peelTransparentInstance(d.left.nodeType);
	const right = peelTransparentInstance(d.right.nodeType);
	if (isSlotUnion(left) == isSlotUnion(right)) return node;
	const unionOnLeft = isSlotUnion(left);
	if (!comparesByKind(jsMemberKind(unionOnLeft ? right : left))) return node;
	const call = makeCall(makeTypedIdentResolved(comparisonRoutine(left, right, unionOnLeft, ctx, node.location), null, node.location), [d.left, d.right], node.location);
	call.nodeType = booleanType();
	return negated ? makeUnary("!", call, node.location) : call;
}

function comparisonRoutine(left: Type, right: Type, unionOnLeft: boolean, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = "msUnionEq_" + hashToBase36(typeKey(left) + "=" + typeKey(right));
	const at = _convNames.indexOf(name);
	if (at >= 0) return _convSyms[at];
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_convNames.push(name);
	_convSyms.push(sym);
	const x = mintSym(ctx, SymbolKind.Parameter, "x", left);
	const y = mintSym(ctx, SymbolKind.Parameter, "y", right);
	const union = unionOnLeft ? left : right;
	const unionSym = unionOnLeft ? x : y;
	const kind = jsMemberKind(unionOnLeft ? right : left);
	const body: Node[] = [];
	for (const vi of armOrder(union, ctx, loc)) {
		const member = union.typeChildren[vi];
		if (jsMemberKind(member) != kind) continue;
		const held = slotConv(read(unionSym, union, loc), member, vi);
		const same = unionOnLeft ? makeBinary(held, "==", read(y, right, loc), loc) : makeBinary(read(x, left, loc), "==", held, loc);
		same.nodeType = booleanType();
		body.push(makeIf(holdsMember(union, unionSym, vi, ctx, loc), makeBlock([makeReturn(same, loc)], loc), null, loc));
	}
	body.push(makeReturn(makeBool(false, loc), loc));
	return declareRoutine(sym, name, [x, y], [left, right], booleanType(), body, loc);
}

function passesUnchanged(source: Type, target: Type, ctx: TransformContext): boolean {
	if (!ctx.jsBackend && !ctx.raiserBackend) return false;
	if (target.kind != TypeKind.Union || storesUnionTag(source) || storesUnionTag(target)) return false;
	const slots = unionMemberSlots(source, target);
	for (let i = 0; i < slots.length; i += 1) {
		if (slots[i] < 0) return false;
		const member = source.typeChildren[i];
		if (isNumeric(member) && !sameType(member, target.typeChildren[slots[i]])) return false;
	}
	return true;
}

function conversionRoutine(source: Type, target: Type, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = "msUnionConv_" + hashToBase36(typeKey(source) + ">" + typeKey(target));
	const at = _convNames.indexOf(name);
	if (at >= 0) return _convSyms[at];
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_convNames.push(name);
	_convSyms.push(sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", source);
	return declareRoutine(sym, name, [valueSym], [source], target, conversionArms(source, target, valueSym, ctx, loc), loc);
}

function nullableConversionRoutine(source: Type, target: Type, from: Type, to: Type, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = "msUnionConvMaybe_" + hashToBase36(typeKey(source) + ">" + typeKey(target));
	const at = _convNames.indexOf(name);
	if (at >= 0) return _convSyms[at];
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_convNames.push(name);
	_convSyms.push(sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", source);
	const present = makeMember(read(valueSym, source, loc), "present", loc);
	present.nodeType = booleanType();
	const payload = makeMember(read(valueSym, source, loc), "value", loc);
	payload.nodeType = from;
	const converted = makeCall(makeTypedIdentResolved(conversionRoutine(from, to, ctx, loc), null, loc), [payload], loc);
	converted.nodeType = to;
	const held = makeTypedObjectLiteral(["value", "present"], [converted, makeBool(true, loc)], target, loc);
	const absent = makeNull(loc);
	absent.nodeType = target;
	const body = [makeIf(present, makeBlock([makeReturn(held, loc)], loc), null, loc), makeReturn(absent, loc)];
	return declareRoutine(sym, name, [valueSym], [source], target, body, loc);
}

function declareRoutine(sym: Symbol, name: string, params: Symbol[], paramTypes: Type[], target: Type, body: Node[], loc: SourceLocation): Symbol {
	const fnNode = makeFnDecl(name, params, params.map((p: Symbol): string => "unknown"), makeBlock(body, loc), "", "unknown", loc);
	const fnType = fnNode.nodeType;
	if (fnType == null || fnType.typeChildren == null || fnType.typeChildren.length != params.length) {
		throw new Error(`internal: the routine '${name}' has no parameter types`);
	}
	for (let i = 0; i < params.length; i += 1) fnType.typeChildren[i] = paramTypes[i];
	fnType.typeReturn = target;
	sym.symbolType = fnType;
	fnNode.resolvedSym = sym;
	_convDecls.push(fnNode);
	return sym;
}

function read(valueSym: Symbol, source: Type, loc: SourceLocation): Node {
	const n = makeIdentResolved(valueSym, loc);
	n.nodeType = source;
	return n;
}

function slotConv(expr: Node, target: Type, slot: int32): Node {
	const conv = createNode(NodeKind.HiddenSubConv, { convExpr: expr, convType: target }, syntheticToken(expr.location));
	conv.nodeType = target;
	conv.flags = conv.flags.incl(NodeFlag.Sem);
	conv.variantSlot = slot + 1;
	return conv;
}

function conversionArms(source: Type, target: Type, valueSym: Symbol, ctx: TransformContext, loc: SourceLocation): Node[] {
	const slots = unionMemberSlots(source, target);
	const order = armOrder(source, ctx, loc);
	const stmts: Node[] = [];
	for (let k = 0; k < order.length; k += 1) {
		const vi = order[k];
		const member = source.typeChildren[vi];
		const arm = slots[vi] >= 0
			? [makeReturn(intoTarget(heldAs(slotConv(read(valueSym, source, loc), member, vi), targetMembers(target)[slots[vi]], loc), target, slots[vi]), loc)]
			: literalArms(source, target, valueSym, vi, ctx, loc);
		if (k == order.length - 1) {
			for (const stmt of arm) stmts.push(stmt);
		} else {
			stmts.push(makeIf(holdsMember(source, valueSym, vi, ctx, loc), makeBlock(arm, loc), null, loc));
		}
	}
	return stmts;
}

function heldAs(held: Node, slot: Type, loc: SourceLocation): Node {
	if (held.nodeType == null || held.nodeType == slot) return held;
	if (isNumeric(held.nodeType) && isNumeric(slot) && !sameType(held.nodeType, slot)) return wrapInConv(held, slot);
	if (held.nodeType.kind != TypeKind.Ref || slot.kind != TypeKind.Ref) return held;
	const upcast = makeHiddenSubConv(held, slot, loc);
	upcast.nodeType = slot;
	return upcast;
}

function intoTarget(held: Node, target: Type, slot: int32): Node {
	if (target.kind != TypeKind.Union) {
		held.nodeType = target;
		return held;
	}
	return slotConv(held, target, slot);
}

function literalArms(source: Type, target: Type, valueSym: Symbol, vi: int32, ctx: TransformContext, loc: SourceLocation): Node[] {
	const member = source.typeChildren[vi];
	const stmts: Node[] = [];
	for (const slot of booleanLiteralSlots(target, member)) {
		const literal = targetMembers(target)[slot];
		const held = slotConv(read(valueSym, source, loc), member, vi);
		const same = makeBinary(held, "==", makeBool(booleanLiteralValue(literal), loc), loc);
		same.nodeType = booleanType();
		const value = slotConv(read(valueSym, source, loc), literal, vi);
		stmts.push(makeIf(same, makeBlock([makeReturn(intoTarget(value, target, slot), loc)], loc), null, loc));
	}
	stmts.push(memberMissing(source, target, vi, ctx, loc));
	return stmts;
}

function testsByTag(source: Type, ctx: TransformContext): boolean {
	return (!ctx.jsBackend && !ctx.raiserBackend) || storesUnionTag(source);
}

function classDepth(m: Type): int32 {
	let depth = 0;
	let parent = classParentOf(m);
	while (parent != null) {
		depth += 1;
		parent = classParentOf(parent);
	}
	return depth;
}

function valueKind(m: Type): string {
	const v = peelTransparentInstance(m);
	if (v.kind == TypeKind.Int64 || v.kind == TypeKind.Uint64) return "bigint";
	return jsMemberKind(m);
}

function testedByTypeof(kind: string): boolean {
	return kind == "number" || kind == "string" || kind == "boolean" || kind == "bigint";
}

export function armOrder(source: Type, ctx: TransformContext, loc: SourceLocation): int32[] {
	const order: int32[] = [];
	if (testsByTag(source, ctx)) {
		for (let vi: int32 = 0; vi < source.typeChildren.length; vi += 1) order.push(vi);
		return order;
	}
	let deepest = 0;
	for (const m of source.typeChildren) {
		if (valueKind(m) == "class" && classDepth(m) > deepest) deepest = classDepth(m);
	}
	for (let depth = deepest; depth >= 0; depth -= 1) {
		for (let vi: int32 = 0; vi < source.typeChildren.length; vi += 1) {
			const m = source.typeChildren[vi];
			if (valueKind(m) == "class" && classDepth(m) == depth) order.push(vi);
		}
	}
	for (let vi: int32 = 0; vi < source.typeChildren.length; vi += 1) {
		if (testedByTypeof(valueKind(source.typeChildren[vi]))) order.push(vi);
	}
	const rest: int32[] = [];
	for (let vi: int32 = 0; vi < source.typeChildren.length; vi += 1) {
		const kind = valueKind(source.typeChildren[vi]);
		if (kind != "class" && !testedByTypeof(kind)) rest.push(vi);
	}
	if (rest.length > 1) {
		reportTransformError(ctx, `a '${typeDisplayName(source)}' value carries no tag here, and its members ${rest.map((vi: int32): string => `'${unionMemberDisplay(source.typeChildren[vi])}'`).join(" and ")} cannot be told apart at run time; convert each member on its own`, loc);
	}
	for (const vi of rest) order.push(vi);
	return order;
}

export function holdsMember(source: Type, valueSym: Symbol, vi: int32, ctx: TransformContext, loc: SourceLocation): Node {
	const member = source.typeChildren[vi];
	let test: Node;
	if (testsByTag(source, ctx)) {
		const tag = makeMember(read(valueSym, source, loc), ctx.jsBackend || ctx.raiserBackend ? "$tag" : "_tag", loc);
		tag.nodeType = int32Type();
		test = makeBinary(tag, "==", makeIntNumber(vi as int64, loc), loc);
	} else if (valueKind(member) == "class") {
		const cls = runtimeClassSym(member.typeReturn);
		if (cls == null) throw new Error(`internal: the class member '${typeDisplayName(member)}' of '${typeDisplayName(source)}' has no runtime class`);
		const body = member.typeReturn;
		const tested = body != null && body.kind == TypeKind.GenericInstance ? instanceClassSym(cls, member, body) : cls;
		const ref = makeIdentResolved(tested, loc);
		ref.nodeType = tested.symbolType;
		test = makeBinary(read(valueSym, source, loc), "instanceof", ref, loc);
	} else {
		const kind = makeUnary("typeof", read(valueSym, source, loc), loc);
		kind.nodeType = stringType();
		const want = makeString(ctx.raiserBackend ? jsMemberKind(member) : valueKind(member), loc);
		test = makeBinary(kind, "===", want, loc);
	}
	test.nodeType = booleanType();
	return test;
}

// The class an instantiation is emitted as, named as its instance declaration names it.
function instanceClassSym(generic: Symbol, member: Type, body: Type): Symbol {
	const instance = makeSymbol(monoInstanceName(body), SymbolKind.Class, member, false);
	instance.modulePath = generic.modulePath;
	instance.symFlags = generic.symFlags;
	instance.instantiatedFrom = generic;
	return instance;
}

function memberMissing(source: Type, target: Type, vi: int32, ctx: TransformContext, loc: SourceLocation): Node {
	const head = makeString(`member '${typeDisplayName(target)}' is not accessible for type '${typeDisplayName(source)}' using '`, loc);
	const labels = memberLabels(source);
	if (!ctx.jsBackend && !ctx.raiserBackend) {
		const fail = makeCall(runtimeRef("msRaiseFieldError", loc), [head, makeString(labels.join("|"), loc), makeIntNumber(vi as int64, loc)], loc);
		return makeExprStmt(fail, loc);
	}
	const held = makeTypedObjectLiteral(["$tag"], [makeIntNumber(vi as int64, loc)], unknownType(), loc);
	const none = createNode(NodeKind.ArrayLiteral, { elements: [makeIntNumber(-1, loc)] }, syntheticToken(loc));
	none.nodeType = createArray(int32Type());
	const names = createNode(NodeKind.ArrayLiteral, { elements: labels.map((l: string): Node => makeString(l, loc)) }, syntheticToken(loc));
	names.nodeType = createArray(stringType());
	const fail = makeCall(runtimeRef("msUnionRead", loc), [held, none, head, names], loc);
	fail.nodeType = target;
	return makeExprStmt(fail, loc);
}
