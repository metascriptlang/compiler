import { Node, NodeKind, NodeFlag, TypeKind, Type, Symbol, SymbolKind, SourceLocation, HiddenStdConvData, ProgramData } from "../../ast/node";
import { convertsBetweenUnions, unionMemberSlots, storesUnionTag, nullableUnionPayloads } from "../../checker/fit";
import { peelTransparentInstance, typeDisplayName, unionMemberDisplay, jsMemberKind, runtimeClassSym, classParentOf, int32Type, booleanType, stringType, createArray, unknownType } from "../../checker/types";
import { hashToBase36, typeKey } from "../../codegen/c/types";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBlock, makeCall, makeExprStmt, makeFnDecl, makeIf, makeIdentResolved, makeIntNumber, makeMember, makeReturn, makeString, makeTypedIdentResolved, makeTypedObjectLiteral, makeUnary, runtimeRef, syntheticToken, makeBool, makeNull } from "../util";
import { createNode } from "../../ast/node";
import { memberLabels } from "../native/unionProjectLower";

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
	return convertsBetweenUnions(source, target) ? [source, target] : null;
}

function lowerConversion(node: Node, ctx: TransformContext): Node {
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

function passesUnchanged(source: Type, target: Type, ctx: TransformContext): boolean {
	if (!ctx.jsBackend && !ctx.raiserBackend) return false;
	if (storesUnionTag(source) || storesUnionTag(target)) return false;
	for (const slot of unionMemberSlots(source, target)) {
		if (slot < 0) return false;
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
	return declareRoutine(sym, name, valueSym, source, target, conversionArms(source, target, valueSym, ctx, loc), loc);
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
	return declareRoutine(sym, name, valueSym, source, target, body, loc);
}

function declareRoutine(sym: Symbol, name: string, valueSym: Symbol, source: Type, target: Type, body: Node[], loc: SourceLocation): Symbol {
	const fnNode = makeFnDecl(name, [valueSym], ["unknown"], makeBlock(body, loc), "", "unknown", loc);
	if (fnNode.nodeType == null || fnNode.nodeType.typeChildren == null || fnNode.nodeType.typeChildren.length != 1) {
		throw new Error(`internal: the conversion routine from '${typeDisplayName(source)}' to '${typeDisplayName(target)}' has no parameter type`);
	}
	fnNode.nodeType.typeChildren[0] = source;
	fnNode.nodeType.typeReturn = target;
	sym.symbolType = fnNode.nodeType;
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
			? makeReturn(slotConv(slotConv(read(valueSym, source, loc), member, vi), target, slots[vi]), loc)
			: memberMissing(source, target, vi, ctx, loc);
		if (k == order.length - 1) {
			stmts.push(arm);
		} else {
			stmts.push(makeIf(holdsMember(source, valueSym, vi, ctx, loc), makeBlock([arm], loc), null, loc));
		}
	}
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

function armOrder(source: Type, ctx: TransformContext, loc: SourceLocation): int32[] {
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

function holdsMember(source: Type, valueSym: Symbol, vi: int32, ctx: TransformContext, loc: SourceLocation): Node {
	const member = source.typeChildren[vi];
	let test: Node;
	if (testsByTag(source, ctx)) {
		const tag = makeMember(read(valueSym, source, loc), ctx.jsBackend || ctx.raiserBackend ? "$tag" : "_tag", loc);
		tag.nodeType = int32Type();
		test = makeBinary(tag, "==", makeIntNumber(vi as int64, loc), loc);
	} else if (valueKind(member) == "class") {
		const cls = runtimeClassSym(member.typeReturn);
		if (cls == null) throw new Error(`internal: the class member '${typeDisplayName(member)}' of '${typeDisplayName(source)}' has no runtime class`);
		const ref = makeIdentResolved(cls, loc);
		ref.nodeType = cls.symbolType;
		test = makeBinary(read(valueSym, source, loc), "instanceof", ref, loc);
	} else {
		const kind = makeUnary("typeof", read(valueSym, source, loc), loc);
		kind.nodeType = stringType();
		const want = makeString(valueKind(member), loc);
		test = makeBinary(kind, "===", want, loc);
	}
	test.nodeType = booleanType();
	return test;
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
