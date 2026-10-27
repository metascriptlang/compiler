// console.log(a, b) becomes msPrintln(str(a) + " " + str(b)); a value type or class
// arrives already converted by the checker's std dump call.

import { Node, NodeKind, SourceLocation, CallExprData, Type, TypeKind, Symbol, SymbolKind } from "../../ast/node";
import { getBuiltinKind, isNumeric, isWideInteger, stringType, booleanType, unwrapRef, isMaybeType, unwrapMaybeType, peelTransparentInstance, literalBase, isStringLike, isNullableBigInt, createFunction, unwrapRefNullUnion } from "../../checker/types";
import { TransformContext, mintSym } from "../context";
import { makeIdentResolved, makeTypedIdentResolved, compilerFuncSym, makeCall, makeString, makeBool, makeBinary, makeMember, makeConditional, enumToStringSym, runtimeRef, makeFnDecl, makeBlock, makeReturn, makeNull } from "../util";
import { charToString } from "./stringOpLower";

function echoCoerceArg(arg: Node, loc: SourceLocation, ctx: TransformContext): Node {
	if (arg.nodeType == null) return arg;
	const t = literalBase(peelTransparentInstance(arg.nodeType));
	if (isStringLike(t) || arg.kind == NodeKind.StringLiteral) return arg;
	if (t.kind == TypeKind.Char) return charToString(arg, loc);
	if (isWideInteger(t)) {
		const fn = t.kind == TypeKind.Uint64 ? "msUint64ToString" : "msIntToString";
		const call = makeCall(runtimeRef(fn, loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (isNumeric(t)) {
		const call = makeCall(runtimeRef("msNumberToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// console.log(255n) prints the "n" suffix; interpolation and concat drop it.
	if (t.kind == TypeKind.BigInt && !ctx.jsBackend) {
		const call = makeCall(runtimeRef("msBigIntToDebugString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (t.kind == TypeKind.BigInt || isNullableBigInt(t)) {
		const call = makeCall(runtimeRef("msBigIntDebugText", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (t.kind == TypeKind.Boolean) {
		const call = makeCall(runtimeRef("msBoolToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (isMaybeType(t)) {
		const payload = unwrapMaybeType(t);
		const val = makeMember(arg, "value", loc);
		val.nodeType = payload;
		const present = makeMember(arg, "present", loc);
		present.nodeType = booleanType();
		const absent = makeString("null", loc);
		absent.nodeType = stringType();
		const cond = makeConditional(present, echoCoerceArg(val, loc, ctx), absent, loc);
		cond.nodeType = stringType();
		return cond;
	}
	const inner = unwrapRef(t);
	if (inner.kind == TypeKind.Union && inner.typeName != "" && isJsonValueData(inner)) {
		return buildJsonValueDebug(arg, loc);
	}
	if (t.kind == TypeKind.Enum && t.typeName != "") {
		const call = makeCall(makeTypedIdentResolved(enumToStringSym(ctx, t), null, loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (t.kind == TypeKind.Enum) {
		const call = makeCall(runtimeRef("msIntToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	if (t.kind == TypeKind.Null) return evaluatedPlaceholder(arg, t, "null", loc, ctx);
	return evaluatedPlaceholder(arg, t, "<" + (t.typeName != "" ? t.typeName : "object") + ">", loc, ctx);
}

let _placeholderFnDecls: Node[] = [];

export function takePlaceholderFns(): Node[] {
	const out = _placeholderFnDecls;
	_placeholderFnDecls = [];
	return out;
}

function nullableSlotType(arg: Node, t: Type): Type {
	const declared = t.kind == TypeKind.Null && arg.resolvedSym != null ? arg.resolvedSym.symbolType : t;
	return declared != null && declared.kind == TypeKind.Union && unwrapRefNullUnion(declared) != null ? declared : t;
}

export function evaluatedPlaceholder(arg: Node, t: Type, text: string, loc: SourceLocation, ctx: TransformContext): Node {
	if (t.kind == TypeKind.Void || t.kind == TypeKind.Never) {
		const unevaluated = makeString(text, loc);
		unevaluated.nodeType = stringType();
		return unevaluated;
	}
	const slotType = nullableSlotType(arg, t);
	const sym = mintSym(ctx, SymbolKind.Function, "$placeholder" + _placeholderFnDecls.length.toString(), null);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", slotType);
	let placeholder = makeString(text, loc);
	placeholder.nodeType = stringType();
	if (t.kind != TypeKind.Null && slotType.kind == TypeKind.Union) {
		const absent = makeString("null", loc);
		absent.nodeType = stringType();
		placeholder = makeConditional(makeBinary(makeTypedIdentResolved(valueSym, slotType, loc), "==", makeNull(loc), loc), absent, placeholder, loc);
		placeholder.nodeType = stringType();
	}
	const fnNode = makeFnDecl(sym.name, [valueSym], ["unknown"], makeBlock([makeReturn(placeholder, loc)], loc), "", "string", loc);
	fnNode.nodeType = createFunction([slotType], ["x"], stringType());
	sym.symbolType = fnNode.nodeType;
	fnNode.resolvedSym = sym;
	_placeholderFnDecls.push(fnNode);
	const call = makeCall(makeTypedIdentResolved(sym, fnNode.nodeType, loc), [arg], loc);
	call.nodeType = stringType();
	return call;
}

function isJsonValueData(t: Type): boolean {
	return getBuiltinKind(t) == "JsonValueData";
}

function resolveDbgIdent(name: string, loc: SourceLocation): Node {
	const sym = compilerFuncSym(name);
	if (sym == null) {
		throw new Error(`internal: debug lowering asked for compiler routine '${name}' that the prelude does not declare (@compilerFunc)`);
	}
	return makeIdentResolved(sym, loc);
}

function buildJsonValueDebug(arg: Node, loc: SourceLocation): Node {
	const prefix = makeString("\x1b[35mJson \x1b[0m", loc);
	prefix.nodeType = stringType();
	const strCall = makeCall(resolveDbgIdent("stringify", loc), [arg, makeBool(true, loc)], loc);
	strCall.nodeType = stringType();
	let result = makeBinary(prefix, "+", strCall, loc);
	result.nodeType = stringType();
	return result;
}

function echoSym(node: Node): Symbol | null {
	if (node.resolvedSym != null && node.resolvedSym.builtinKind == "Echo") return node.resolvedSym;
	const callee = (node.data as CallExprData).callee;
	return callee.resolvedSym != null && callee.resolvedSym.builtinKind == "Echo" ? callee.resolvedSym : null;
}

export function rewriteEcho(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	const echo = echoSym(node);
	const sink = echo != null && echo.nativeName != "" ? echo.nativeName : "msPrintln";
	if (cd.arguments.length == 0) {
		return makeCall(runtimeRef(sink, loc), [makeString("", loc)], loc);
	}
	const coerced: Node[] = [];
	for (const arg of cd.arguments) coerced.push(echoCoerceArg(arg, loc, ctx));
	if (coerced.length == 1) {
		return makeCall(runtimeRef(sink, loc), [coerced[0]], loc);
	}
	let result = coerced[0];
	for (let i = 1; i < coerced.length; i += 1) {
		const space = makeString(" ", loc);
		space.nodeType = stringType();
		result = makeBinary(result, "+", space, loc);
		result.nodeType = stringType();
		result = makeBinary(result, "+", coerced[i], loc);
		result.nodeType = stringType();
	}
	return makeCall(runtimeRef(sink, loc), [result], loc);
}
