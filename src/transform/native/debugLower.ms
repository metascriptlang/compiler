// Debug Lowering — rewrite console.log (Echo builtin) to msPrintln + string coercion
//
// Rewrites console.log(arg1, arg2, ...) → msPrintln(toString(arg1) + " " + toString(arg2) + ...)
// Each arg is coerced to string here. Primitives use direct calls, structs use JSON.stringify,
// and stringOpLower handles any remaining coercion for + operators.
//
// C code generation for colored struct output delegated to codegen/c/json.ms.

import {
	Node, NodeKind, SourceLocation,
	CallExprData,
} from "../../ast/node";
import { Type, TypeKind, isNumeric, stringType, unwrapRef } from "../../checker/types";
import { TransformContext, hasEmitted } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { findExtension } from "../../checker/context";
import { makeIdent, makeCall, makeString, makeBinary, makeMember, enumToStringName } from "../util";
import { makeEmitNode, generateJsonStringifyColoredC, registerHelper } from "../../codegen/c/json";

// Resolve the struct type for a type name string (e.g., "Person" → struct type with fields).
// Shared by echo coercion and JSON builtin rewriting.
export function resolveJsonTargetType(typeArgStr: string, ctx: TransformContext): Type {
	if (ctx.checkerCtx === null) return null;
	const sym = lookupSymbol(ctx.checkerCtx.table, typeArgStr);
	if (sym === null) return null;
	if (sym.symbolType === null) return null;
	const unwrapped = unwrapRef(sym.symbolType);
	if (unwrapped.kind === TypeKind.Struct) return unwrapped;
	return null;
}

function echoCoerceArg(arg: Node, loc: SourceLocation, ctx: TransformContext): Node {
	if (arg.nodeType === null) return arg;
	const t = arg.nodeType;
	// String: as-is
	if (t.kind === TypeKind.String || arg.kind === NodeKind.StringLiteral) return arg;
	// Number/int → msNumberToString
	if (isNumeric(t)) {
		const call = makeCall(makeIdent("msNumberToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Boolean → msBoolToString
	if (t.kind === TypeKind.Boolean) {
		const call = makeCall(makeIdent("msBoolToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Struct/Class → check toString() extension first, then fall back to JSON debug format
	const inner = unwrapRef(t);
	if (inner.kind === TypeKind.Struct && inner.typeName !== "") {
		const typeName = inner.typeName;
		// Priority 1: user-defined toString() extension method
		if (ctx.checkerCtx !== null && typeName !== "JsonValue") {
			const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, "toString");
			if (ext !== null && ext.sym !== null) {
				if (ext.sym.nativeName !== "") {
					// Extern toString → call native C function directly
					const ident = makeIdent(ext.sym.nativeName, loc);
					ident.resolvedSym = ext.sym;
					const call = makeCall(ident, [arg], loc);
					call.nodeType = stringType();
					return call;
				}
				// Pure-MS toString → call the function directly with receiver as first arg
				const ident = makeIdent(ext.sym.name, loc);
				ident.resolvedSym = ext.sym;
				const call = makeCall(ident, [arg], loc);
				call.nodeType = stringType();
				return call;
			}
		}
		// JsonValue → "Json { ... }" with magenta prefix
		if (typeName === "JsonValue") {
			const jHelperName = "__jsonDbg_JsonValue";
			if (!hasEmitted(ctx, jHelperName)) {
				// Emit a small wrapper: prefix "Json " in magenta + msJsonStringifyColored(value)
				let jc = "/*INCLUDESECTION*/#include \"core/json.h\"\n";
				jc = jc + "static msString " + jHelperName + "(JsonValue* value) {\n";
				jc = jc + "  msString __body = msJsonStringifyColored(value);\n";
				jc = jc + "  char __pbuf[64];\n";
				jc = jc + "  int __plen;\n";
				jc = jc + "  if (msColorsEnabled()) {\n";
				jc = jc + "    __plen = snprintf(__pbuf, sizeof(__pbuf), \"\\x1b[35mJson \\x1b[0m\");\n";
				jc = jc + "  } else {\n";
				jc = jc + "    __plen = snprintf(__pbuf, sizeof(__pbuf), \"Json \");\n";
				jc = jc + "  }\n";
				jc = jc + "  msString __prefix = msStringNew(__pbuf, __plen);\n";
				jc = jc + "  return msStringConcat(__prefix, __body);\n";
				jc = jc + "}\n";
				registerHelper(jHelperName, makeEmitNode(jc, loc), ctx);
			}
			const call = makeCall(makeIdent(jHelperName, loc), [arg], loc);
			call.nodeType = stringType();
			return call;
		}
		// Named struct → __jsonDbg_T (colored debug format for console.log)
		// Try symbol table first; fall back to type directly if it has field metadata
		// (synthesized anonymous types like __anon... have no symbol table entry)
		let structType = resolveJsonTargetType(typeName, ctx);
		if (structType === null && inner.typeNames !== null && inner.typeChildren !== null) {
			structType = inner;
		}
		if (structType !== null) {
			const isClass = t.kind === TypeKind.Ref;
			const isAnon = typeName.length > 6 && typeName.slice(0, 6) === "__anon";
			const displayName = isAnon ? "Object " : isClass ? "class " + typeName + " " : typeName + " ";
			const dbgColor = isAnon ? "\\x1b[36m" : isClass ? "\\x1b[32m" : "\\x1b[34m";
			const helperName = "__jsonDbg_" + typeName;
			if (!hasEmitted(ctx, helperName)) {
				const emitNode = generateJsonStringifyColoredC(helperName, typeName, structType, displayName, dbgColor, loc);
				if (emitNode === null) return arg;  // unsupported field type — pass through
				registerHelper(helperName, emitNode, ctx);
			}
			const call = makeCall(makeIdent(helperName, loc), [arg], loc);
			call.nodeType = stringType();
			return call;
		}
	}
	// Enum → EnumName_toString(value) (generated by enumToStringLower)
	if (t.kind === TypeKind.Enum && t.typeName !== "") {
		const call = makeCall(makeIdent(enumToStringName(t.typeName), loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Fallback for enums without typeName
	if (t.kind === TypeKind.Enum) {
		const call = makeCall(makeIdent("msIntToString", loc), [arg], loc);
		call.nodeType = stringType();
		return call;
	}
	// Fallback: emit type name as placeholder string (safe — no C compile error)
	const typeName = t.typeName !== null && t.typeName !== "" ? t.typeName : "object";
	const placeholder = makeString("<" + typeName + ">", loc);
	placeholder.nodeType = stringType();
	return placeholder;
}

export function rewriteEcho(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	// No args → msPrintln("")
	if (cd.arguments.length === 0) {
		return makeCall(makeIdent("msPrintln", loc), [makeString("", loc)], loc);
	}
	// Coerce all args to string
	const coerced: Node[] = [];
	let ci = 0;
	while (ci < cd.arguments.length) {
		coerced.push(echoCoerceArg(cd.arguments[ci], loc, ctx));
		ci = ci + 1;
	}
	// Single arg → msPrintln(coerced)
	if (coerced.length === 1) {
		return makeCall(makeIdent("msPrintln", loc), [coerced[0]], loc);
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
	return makeCall(makeIdent("msPrintln", loc), [result], loc);
}
