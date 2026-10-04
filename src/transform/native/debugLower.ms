// Debug Lowering — rewrite console.log (Echo builtin) to msPrintln + string coercion
//
// Rewrites console.log(arg1, arg2, ...) → msPrintln(toString(arg1) + " " + toString(arg2) + ...)
// Each arg is coerced to string here. Primitives use direct calls, structs use
// json builders (jsonObject/jsonString/jsonNumber/jsonBool) + stringify from std/core/json.

import { Node, NodeKind, SourceLocation, CallExprData, Type, TypeKind, Symbol, createNode } from "../../ast/node";
import { isNumeric, isWideInteger, stringType, booleanType, createPtr, voidType, createArray, unwrapRef, isMaybeType, unwrapMaybeType, peelTransparentInstance, literalBase, int32Type } from "../../checker/types";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { findExtension } from "../../checker/context";
import { makeIdentResolved, makeTypedIdentResolved, compilerFuncSym, makeCall, makeString, makeBool, makeBinary, makeMember, makeConditional, enumToStringSym, typeHelperName, syntheticToken, makeNull, makeBlock, makeReturn, makeIf, makeFnDecl, runtimeRef, makeNumber } from "../util";
import { anonTypeName, isAnonTypeName, hashToBase36, typeKey } from "../../codegen/c/types";
import { isSlotUnion, projectTagUnionMember } from "../../checker/fit";
import { charToString } from "./stringOpLower";
import { SymbolKind } from "../../ast/node";

// Resolve the struct type for a type name string (e.g., "Person" → struct type with fields).
function resolveJsonTargetType(typeArgStr: string, ctx: TransformContext): Type | null {
	if (ctx.checkerCtx == null) return null;
	const sym = lookupSymbol(ctx.checkerCtx.table, typeArgStr);
	if (sym == null) return null;
	if (sym.symbolType == null) return null;
	const unwrapped = unwrapRef(sym.symbolType);
	if (unwrapped.kind == TypeKind.Struct) return unwrapped;
	return null;
}

function echoCoerceArg(arg: Node, loc: SourceLocation, ctx: TransformContext): Node {
	if (arg.nodeType == null) return arg;
	const t = literalBase(peelTransparentInstance(arg.nodeType));
	// String: as-is
	if (t.kind == TypeKind.String || arg.kind == NodeKind.StringLiteral) return arg;
	if (t.kind == TypeKind.Char) return charToString(arg, loc);
	// Number/int → msNumberToString; 64-bit integers need the exact formatter
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
	// bigint → digits + "n", matching what node prints for console.log(255n).
	// Interpolation and concat drop the suffix; that split is TS behaviour, not ours.
	if (t.kind == TypeKind.BigInt && !ctx.jsBackend) {
		const call = makeCall(runtimeRef("msBigIntToDebugString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Boolean → msBoolToString
	if (t.kind == TypeKind.Boolean) {
		const call = makeCall(runtimeRef("msBoolToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Value-carried nullable → the payload, or "null" when absent. Without this the
	// carrier itself reaches the struct dump and the Maybe fields leak to stdout.
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
	if (isSlotUnion(t) && !hasToStringExtension(t, ctx)) return ctx.jsBackend ? arg : buildUnionText(arg, t, "msUnionDebug_", (v: Node): Node => echoCoerceArg(v, loc, ctx), loc, ctx);
	// Struct/Class/Union → check toString() extension first, then fall back to JSON debug format
	const inner = unwrapRef(t);
	if ((inner.kind == TypeKind.Struct || inner.kind == TypeKind.Union) && inner.typeName != "") {
		const typeName = inner.typeName;
		// Priority 1: user-defined toString() extension method
		if (ctx.checkerCtx != null && typeName != "JsonValue") {
			const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, "toString");
			if (ext != null && ext.sym != null) {
				const call = makeCall(makeTypedIdentResolved(ext.sym, null, loc), [arg], loc);
				call.nodeType = stringType();
				return call;
			}
		}
		// JsonValue → "\x1b[35mJson \x1b[0m" + stringify(value)
		if (typeName == "JsonValue" || typeName == "JsonValueData") {
			return buildJsonValueDebug(arg, loc, ctx);
		}
		// Named struct/class → "\x1b[34mTypeName \x1b[0m" + stringify(jsonObject(...))
		let structType = resolveJsonTargetType(typeName, ctx);
		if (structType == null && inner.typeNames != null && inner.typeChildren != null) {
			structType = inner;
		}
		if (structType != null) {
			const isClass = t.kind == TypeKind.Ref;
			const isAnon = typeName.length > 6 && typeName.slice(0, 6) == "__anon";
			return buildStructDebugString(arg, typeName, structType, isClass, isAnon, loc, ctx);
		}
	}
	// Enum → EnumName_toString(value) (generated by enumToStringLower)
	if (t.kind == TypeKind.Enum && t.typeName != "") {
		const call = makeCall(makeTypedIdentResolved(enumToStringSym(ctx, t), null, loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Fallback for enums without typeName
	if (t.kind == TypeKind.Enum) {
		const call = makeCall(runtimeRef("msIntToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Fallback: emit type name as placeholder string (safe — no C compile error)
	// Use explicit local to avoid DRC ternary+member-access issue
	let fallbackName = "object";
	if (t.typeName != null && t.typeName != "") {
		fallbackName = t.typeName;
	}
	const placeholder = makeString("<" + fallbackName + ">", loc);
	placeholder.nodeType = stringType();
	return placeholder;
}

function hasToStringExtension(t: Type, ctx: TransformContext): boolean {
	return ctx.checkerCtx != null && t.typeName != "" && findExtension(ctx.checkerCtx.extensionRegistry, t.typeName, "toString") != null;
}

// A tagged union stringifies the member its tag selects, one generated helper per union
// type, the way a case object's fields are visited through a case on its discriminator.
export function buildUnionText(arg: Node, ut: Type, prefix: string, memberText: (v: Node) => Node, loc: SourceLocation, ctx: TransformContext): Node {
	const call = makeCall(makeTypedIdentResolved(ensureUnionTextFn(ut, prefix, memberText, ctx, loc), null, loc), [arg], loc);
	call.nodeType = stringType();
	return call;
}

function ensureUnionTextFn(ut: Type, prefix: string, memberText: (v: Node) => Node, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = prefix + hashToBase36(typeKey(ut));
	const existing = existingDumpFn(name);
	if (existing != null) return existing;
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_dumpFnNames.push(name);
	_dumpFnSyms.push(sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", ut);
	const stmts: Node[] = [];
	const last = ut.typeChildren.length - 1;
	for (let vi = 0; vi <= last; vi += 1) {
		const member = ut.typeChildren[vi];
		const read = makeIdentResolved(valueSym, loc);
		read.nodeType = ut;
		const ret = makeReturn(memberText(projectTagUnionMember(read, ut, member)), loc);
		if (vi == last) { stmts.push(ret); continue; }
		const tag = makeMember(makeIdentResolved(valueSym, loc), "_tag", loc);
		tag.nodeType = int32Type();
		const isSlot = makeBinary(tag, "==", makeNumber(vi, loc), loc);
		isSlot.nodeType = booleanType();
		stmts.push(makeIf(isSlot, makeBlock([ret], loc), null, loc));
	}
	const fnNode = makeFnDecl(name, [valueSym], ["unknown"], makeBlock(stmts, loc), "", "string", loc);
	if (fnNode.nodeType != null && fnNode.nodeType.typeChildren != null && fnNode.nodeType.typeChildren.length > 0) {
		fnNode.nodeType.typeChildren[0] = ut;
	}
	if (fnNode.nodeType != null) sym.symbolType = fnNode.nodeType;
	fnNode.resolvedSym = sym;
	_dumpFnDecls.push(fnNode);
	return sym;
}

function resolveDbgIdent(name: string, ctx: TransformContext, loc: SourceLocation): Node {
	const sym = compilerFuncSym(name);
	if (sym == null) {
		throw new Error(`internal: debug lowering asked for compiler routine '${name}' that the prelude does not declare (@compilerFunc)`);
	}
	return makeIdentResolved(sym, loc);
}

// Wrap a field access node in the appropriate json builder call.
// Handles primitives, nested structs, and arrays recursively.
let _dumpFnNames: string[] = [];
let _dumpFnSyms: Symbol[] = [];
let _dumpFnDecls: Node[] = [];

export function resetStructDumpFns(): void {
	_dumpFnNames = [];
	_dumpFnSyms = [];
	_dumpFnDecls = [];
}

export function takeStructDumpFns(): Node[] {
	const out = _dumpFnDecls;
	_dumpFnNames = [];
	_dumpFnSyms = [];
	_dumpFnDecls = [];
	return out;
}

function dumpFnBareName(structType: Type): string {
	const n = structType.typeName;
	return (n != "" && !isAnonTypeName(n) ? n : anonTypeName(structType)) + "_msDbgJson";
}

function dumpFnNameFor(structType: Type): string {
	const n = structType.typeName;
	if (n != "" && !isAnonTypeName(n)) return typeHelperName(structType, dumpFnBareName(structType));
	return dumpFnBareName(structType);
}

function existingDumpFn(name: string): Symbol | null {
	let i = 0;
	while (i < _dumpFnNames.length) {
		if (_dumpFnNames[i] == name) return _dumpFnSyms[i];
		i = i + 1;
	}
	return null;
}

function jsonValueType(ctx: TransformContext, loc: SourceLocation): Type | null {
	const ident = resolveDbgIdent("jsonObject", ctx, loc);
	const ft = ident.nodeType;
	if (ft == null) return null;
	return ft.typeReturn;
}

// One dump function per canonical type; the recursive edge is a CALL, so depth
// follows the data instead of being fixed when the AST is built.
// Reference: Nim repr_v2.nim:152 (`if isNil(x): return "nil"` then per-field repr).
function ensureDumpFn(outerType: Type, structType: Type, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = dumpFnNameFor(structType);
	const existing = existingDumpFn(name);
	if (existing != null) return existing;
	const sym = mintSym(ctx, SymbolKind.Function, dumpFnBareName(structType), null);
	_dumpFnNames.push(name);
	_dumpFnSyms.push(sym);

	const stmts: Node[] = [];
	const isRef = outerType.kind == TypeKind.Ref;
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", outerType);
	if (isRef) {
		const cmp = makeBinary(makeIdentResolved(valueSym, loc), "===", makeNull(loc), loc);
		const nullRet = makeReturn(makeCall(resolveDbgIdent("jsonNull", ctx, loc), [], loc), loc);
		stmts.push(makeIf(cmp, makeBlock([nullRet], loc), null, loc));
	}
	stmts.push(makeReturn(buildJsonObjectFor(makeIdentResolved(valueSym, loc), structType, loc, ctx), loc));

	const fnNode = makeFnDecl(sym.name, [valueSym], [structType.typeName], makeBlock(stmts, loc), "", "JsonValue", loc);
	if (fnNode.nodeType != null && fnNode.nodeType.typeChildren != null
		&& fnNode.nodeType.typeChildren.length > 0) {
		fnNode.nodeType.typeChildren[0] = outerType;
	}
	const jv = jsonValueType(ctx, loc);
	if (fnNode.nodeType != null && jv != null) fnNode.nodeType.typeReturn = jv;
	if (fnNode.nodeType != null) sym.symbolType = fnNode.nodeType;
	fnNode.resolvedSym = sym;
	_dumpFnDecls.push(fnNode);
	return sym;
}

function callDumpFn(dumpSym: Symbol, arg: Node, ctx: TransformContext, loc: SourceLocation): Node {
	const call = makeCall(makeTypedIdentResolved(dumpSym, null, loc), [arg], loc);
	const jv = jsonValueType(ctx, loc);
	if (jv != null) call.nodeType = jv;
	return call;
}

function wrapFieldAsJson(fieldAccess: Node, ftype: Type, loc: SourceLocation, ctx: TransformContext): Node {
	if (ftype == null) return makeCall(resolveDbgIdent("jsonNull", ctx, loc), [], loc);

	// Primitives
	const primWrapper = match (ftype.kind) {
		TypeKind.String => "jsonString",
		TypeKind.Boolean => "jsonBool",
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "jsonNumber",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Enum => "jsonInt",
		_ => "",
	};
	if (primWrapper != "") return makeCall(resolveDbgIdent(primWrapper, ctx, loc), [fieldAccess], loc);

	// Nested struct → recursive jsonObject
	const inner = unwrapRef(ftype);
	if (inner.kind == TypeKind.Struct && inner.typeNames != null && inner.typeChildren != null) {
		return callDumpFn(ensureDumpFn(ftype, inner, ctx, loc), fieldAccess, ctx, loc);
	}

	// Fallback: jsonNull
	return makeCall(resolveDbgIdent("jsonNull", ctx, loc), [], loc);
}

// The values array must carry the element type `jsonObject` declares. A raw
// pointer element drops JsonValue's reference semantics, so the array reaches
// stringify holding addresses that were never JsonValues.
function jsonObjectParamType(ctx: TransformContext, loc: SourceLocation, index: int32): Type | null {
	const ident = resolveDbgIdent("jsonObject", ctx, loc);
	const ft = ident.nodeType;
	if (ft == null || ft.typeChildren == null || ft.typeChildren.length < 2) return null;
	return ft.typeChildren[index];
}

// Build jsonObject(keys, vals) for a nested struct field
function buildJsonObjectFor(obj: Node, structType: Type | null, loc: SourceLocation, ctx: TransformContext): Node {
	const keyNodes: Node[] = [];
	const valNodes: Node[] = [];
	if (structType == null) {
		const keysArrEmpty = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, syntheticToken(loc));
		const keysTypeEmpty = jsonObjectParamType(ctx, loc, 0);
		keysArrEmpty.nodeType = keysTypeEmpty != null ? keysTypeEmpty : createArray(stringType());
		const valsArrEmpty = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, syntheticToken(loc));
		const valsTypeEmpty = jsonObjectParamType(ctx, loc, 1);
		valsArrEmpty.nodeType = valsTypeEmpty != null ? valsTypeEmpty : createArray(createPtr(voidType()));
		return makeCall(resolveDbgIdent("jsonObject", ctx, loc), [keysArrEmpty, valsArrEmpty], loc);
	}
	let fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		keyNodes.push(makeString(fname, loc));
		const fa = makeMember(obj, fname, loc);
		// Codegen reads the node's type to pick `.` vs `->`; a synthesized access
		// with no type reads a Ref field as a value.
		fa.nodeType = ftype;
		valNodes.push(wrapFieldAsJson(fa, ftype, loc, ctx));
		fi = fi + 1;
	}
	const keysArr = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, syntheticToken(loc));
	const keysType = jsonObjectParamType(ctx, loc, 0);
	keysArr.nodeType = keysType != null ? keysType : createArray(stringType());
	const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, syntheticToken(loc));
	const valsType = jsonObjectParamType(ctx, loc, 1);
	valsArr.nodeType = valsType != null ? valsType : createArray(createPtr(voidType()));
	return makeCall(resolveDbgIdent("jsonObject", ctx, loc), [keysArr, valsArr], loc);
}

// Build: "\x1b[35mJson \x1b[0m" + stringify(value, true)
function buildJsonValueDebug(arg: Node, loc: SourceLocation, ctx: TransformContext): Node {
	const prefix = makeString("\x1b[35mJson \x1b[0m", loc);
	prefix.nodeType = stringType();
	const strCall = makeCall(resolveDbgIdent("stringify", ctx, loc), [arg, makeBool(true, loc)], loc);
	strCall.nodeType = stringType();
	let result = makeBinary(prefix, "+", strCall, loc);
	result.nodeType = stringType();
	return result;
}

// Build: "\x1b[34mTypeName \x1b[0m" + stringify(jsonObject(keys, vals))
function buildStructDebugString(arg: Node, typeName: string, structType: Type | null, isClass: boolean, isAnon: boolean, loc: SourceLocation, ctx: TransformContext): Node {
	if (structType == null || structType.typeNames == null || structType.typeChildren == null) return arg;

	// Color prefix: blue for struct, green for class, cyan for anon
	const color = isAnon ? "\x1b[36m" : isClass ? "\x1b[32m" : "\x1b[34m";
	const label = isAnon ? "Object " : isClass ? typeName + " " : typeName + " ";
	const prefix = makeString(color + label + "\x1b[0m", loc);
	prefix.nodeType = stringType();

	const outerT = arg.nodeType != null ? arg.nodeType : structType;
	const objCall = callDumpFn(ensureDumpFn(outerT, structType, ctx, loc), arg, ctx, loc);

	// stringify(obj, true) — colored console output
	const strCall = makeCall(resolveDbgIdent("stringify", ctx, loc), [objCall, makeBool(true, loc)], loc);
	strCall.nodeType = stringType();

	// prefix + stringify result
	let result = makeBinary(prefix, "+", strCall, loc);
	result.nodeType = stringType();
	return result;
}

// Plain struct/class → string for `.toString()` — the JSON payload without the
// debug color prefix/type label. Reuses the same json-object + stringify path
// console.log uses, so struct toString actually yields a string (not a passthrough).
export function buildStructToString(arg: Node, inner: Type, loc: SourceLocation, ctx: TransformContext): Node {
	let structType = resolveJsonTargetType(inner.typeName, ctx);
	if (structType == null && inner.typeNames != null && inner.typeChildren != null) {
		structType = inner;
	}
	if (structType == null) return arg;
	const outerT = arg.nodeType != null ? arg.nodeType : structType;
	const objCall = callDumpFn(ensureDumpFn(outerT, structType, ctx, loc), arg, ctx, loc);
	const strCall = makeCall(resolveDbgIdent("stringify", ctx, loc), [objCall, makeBool(false, loc)], loc);
	strCall.nodeType = stringType();
	return strCall;
}

export function rewriteEcho(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	// No args → msPrintln("")
	if (cd.arguments.length == 0) {
		return makeCall(runtimeRef("msPrintln", loc), [makeString("", loc)], loc);
	}
	// Coerce all args to string
	const coerced: Node[] = [];
	let ci = 0;
	while (ci < cd.arguments.length) {
		coerced.push(echoCoerceArg(cd.arguments[ci], loc, ctx));
		ci = ci + 1;
	}
	// Single arg → msPrintln(coerced)
	if (coerced.length == 1) {
		return makeCall(runtimeRef("msPrintln", loc), [coerced[0]], loc);
	}
	// Multi-arg: build "coerced[0] + " " + coerced[1] + ..." chain
	let result = coerced[0];
	let i = 1;
	while (i < coerced.length) {
		const space = makeString(" ", loc);
		space.nodeType = stringType();
		result = makeBinary(result, "+", space, loc);
		result.nodeType = stringType();
		result = makeBinary(result, "+", coerced[i], loc);
		result.nodeType = stringType();
		i = i + 1;
	}
	result.nodeType = stringType();
	return makeCall(runtimeRef("msPrintln", loc), [result], loc);
}
