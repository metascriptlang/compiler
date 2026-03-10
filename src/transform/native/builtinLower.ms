// Builtin Lowering — rewrite @builtin calls + MemberExpr→direct call for extensions
//
// Runs post-analyzer, pre-codegen. Reads metadata from Symbol
// (nativeName from 'extern ... from', builtinKind from @builtin decorator).
//
// extern function ... from "c_name" → nativeName on Symbol, codegen emits C call
// @builtin("Name")                  → inline expansion for known builtins
// MemberExpr callee                 → Identifier callee (move receiver to first arg)
//
// This is an AST-to-AST transform — codegen sees only plain calls.
//
// Typed JSON (JsonParse/JsonStringify): delegates C code generation to
// codegen/c/json.ms for clean separation of concerns.

import {
	Node, NodeKind, NodeFlag, DeclKind, ProgramData, SourceLocation,
	CallExprData, MemberExprData, IdentifierData,
} from "../../ast/node";
import { Type, TypeKind, isNumeric, createResult, createArray, createPrimitive, stringType, booleanType, numberType, unknownType, unwrapRef, typeNameOf } from "../../checker/types";
import { findExtension } from "../../checker/context";
import { TransformContext, hasEmitted } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall, makeString,
	makeObjectLiteral, makeBool, makeHiddenStdConv,
	makeExprStmt, enumToStringName,
} from "../util";
import { findCallTypeArg } from "../../parser/context";
import { generateJsonParseC, generateJsonStringifyC, makeEmitNode, ensureJsonInclude, registerHelper } from "../../codegen/c/json";
import { rewriteEcho, resolveJsonTargetType } from "./debugLower";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerBuiltins(program: Node, ctx: TransformContext): Node {
	const result = walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.CallExpr) {
			return lowerCallExpr(node, ctx);
		}
		return node;
	});
	// Append generated @emit nodes (JSON helpers)
	if (ctx.pendingDecls.length > 0) {
		const pd = result.data as ProgramData;
		for (const decl of ctx.pendingDecls) {
			pd.programStmts.push(decl);
		}
	}
	return result;
}

// ===== Call Expression Lowering =====

function lowerCallExpr(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	const sym = node.resolvedSym;
	if (sym !== null) {
		// @builtin("Name") → inline expansion
		if (sym.builtinKind !== "") {
			return lowerBuiltinCall(node, sym.builtinKind, ctx);
		}
	}
	// Check callee resolvedSym for builtins the call node missed
	if (cd.callee.resolvedSym !== null && cd.callee.resolvedSym.builtinKind !== "") {
		return lowerBuiltinCall(node, cd.callee.resolvedSym.builtinKind, ctx);
	}
	// C-only: universal .toString() resolution
	// Every type has a compiler-provided default. User extensions take priority.
	if (!ctx.jsBackend) {
		if (cd.callee.kind === NodeKind.MemberExpr) {
			const me2 = cd.callee.data as MemberExprData;
			if (me2.property === "toString" && me2.object.nodeType !== null) {
				return lowerToString(node, me2.object, me2.object.nodeType, loc, ctx);
			}
		}
	}

	return node;
}

// ===== Universal .toString() =====
// Every type has a compiler-provided default. User extensions take priority.
// Resolution: user extension > number > boolean > enum > string > struct/class > array > fallback

function lowerToString(callNode: Node, obj: Node, objType: Type, loc: SourceLocation, ctx: TransformContext): Node {
	// Priority 1: user-defined toString extension → leave for extensionMethodLower
	if (ctx.checkerCtx !== null) {
		const tn = typeNameOf(objType);
		if (tn !== "") {
			const ext = findExtension(ctx.checkerCtx.extensionRegistry, tn, "toString");
			if (ext !== null) return callNode;
		}
	}
	// Priority 2: compiler defaults
	const tk = objType.kind;
	// Number/int/float → msNumberToString
	if (isNumeric(objType)) {
		const call = makeCall(makeIdent("msNumberToString", loc), [obj], loc);
		call.nodeType = stringType();
		return call;
	}
	// Boolean → msBoolToString
	if (tk === TypeKind.Boolean) {
		const call = makeCall(makeIdent("msBoolToString", loc), [obj], loc);
		call.nodeType = stringType();
		return call;
	}
	// Enum → EnumName_toString
	if (tk === TypeKind.Enum && objType.typeName !== "") {
		const call = makeCall(makeIdent(enumToStringName(objType.typeName), loc), [obj], loc);
		call.nodeType = stringType();
		return call;
	}
	// String → identity (return self)
	if (tk === TypeKind.String) {
		return obj;
	}
	// Struct/Class → JSON debug format (same as console.log default)
	const inner = unwrapRef(objType);
	if (inner.kind === TypeKind.Struct && inner.typeName !== "") {
		let structType = resolveJsonTargetType(inner.typeName, ctx);
		if (structType === null && inner.typeNames !== null && inner.typeChildren !== null) {
			structType = inner;
		}
		if (structType !== null) {
			const helperName = "__toString_" + inner.typeName;
			if (!hasEmitted(ctx, helperName)) {
				const emitNode = generateToStringC(helperName, inner.typeName, structType, loc);
				if (emitNode !== null) {
					registerHelper(helperName, emitNode, ctx);
				}
			}
			const call = makeCall(makeIdent(helperName, loc), [obj], loc);
			call.nodeType = stringType();
			return call;
		}
	}
	// Array → msArrayToString (runtime helper)
	if (tk === TypeKind.Array) {
		const call = makeCall(makeIdent("msArrayToString", loc), [obj], loc);
		call.nodeType = stringType();
		return call;
	}
	// Null → "null"
	if (tk === TypeKind.Null) {
		const s = makeString("null", loc);
		s.nodeType = stringType();
		return s;
	}
	// Function/Closure → "<function>"
	if (tk === TypeKind.Function) {
		const s = makeString("<function>", loc);
		s.nodeType = stringType();
		return s;
	}
	// Fallback: "<TypeName>" or "<object>"
	const fallbackName = objType.typeName !== "" ? objType.typeName : "object";
	const s = makeString("<" + fallbackName + ">", loc);
	s.nodeType = stringType();
	return s;
}

// Generate a plain (non-colored) struct toString C helper via @emit
function generateToStringC(helperName: string, typeName: string, structType: Type, loc: SourceLocation): Node {
	if (structType.typeNames === null || structType.typeChildren === null) return null as unknown as Node;
	const isAnon = typeName.length > 6 && typeName.slice(0, 6) === "__anon";
	let c = "static msString " + helperName + "(" + typeName + "* self) {\n";
	c = c + "  char __buf[4096];\n";
	c = c + "  int __pos = 0;\n";
	// Opening: "{ " or "TypeName { "
	if (isAnon) {
		c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"{ \");\n";
	} else {
		c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"" + typeName + " { \");\n";
	}
	let fi = 0;
	while (fi < structType.typeNames.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		const sep = fi > 0 ? ", " : "";
		if (ftype.kind === TypeKind.String) {
			c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"" + sep + fname + ": \\\"%.*s\\\"\", (int)self->" + fname + ".len, self->" + fname + ".data);\n";
		} else if (isNumeric(ftype)) {
			c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"" + sep + fname + ": %g\", self->" + fname + ");\n";
		} else if (ftype.kind === TypeKind.Boolean) {
			c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"" + sep + fname + ": %s\", self->" + fname + " ? \"true\" : \"false\");\n";
		} else {
			// Unknown field type — print as placeholder
			c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \"" + sep + fname + ": <...>\");\n";
		}
		fi = fi + 1;
	}
	c = c + "  __pos += snprintf(__buf + __pos, sizeof(__buf) - __pos, \" }\");\n";
	c = c + "  return msStringNew(__buf, __pos);\n";
	c = c + "}\n";
	return makeEmitNode(c, loc);
}

// ===== Builtin Inline Expansion =====
// Handles @builtin("Name") — known compiler builtins get inline C patterns.

function lowerBuiltinCall(node: Node, builtinKind: string, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	if (builtinKind === "LengthStr" && cd.arguments.length === 1) {
		return makeCall(makeIdent("msStringLength", loc), cd.arguments, loc);
	}

	if (builtinKind === "AsBytes") {
		return rewriteZeroCopyBridge(node, true);
	}
	if (builtinKind === "AsString") {
		return rewriteZeroCopyBridge(node, false);
	}

	if (builtinKind === "msResultOk") {
		return rewriteResultToLiteral(node, true, ctx);
	}
	if (builtinKind === "msResultErr") {
		return rewriteResultToLiteral(node, false, ctx);
	}

	if (builtinKind === "JsonParse") {
		return rewriteJsonParse(node, ctx);
	}
	if (builtinKind === "JsonStringify") {
		return rewriteJsonStringify(node, ctx);
	}

	if (builtinKind === "Echo") {
		return rewriteEcho(node, ctx);
	}

	return node;
}

// Zero-copy string ↔ uint8[] bridge: rewrite call to HiddenStdConv with Cursor flag.
// AsBytes: string → uint8[] (bit-cast, same memory layout)
// AsString: uint8[] → string (bit-cast, same memory layout)
// The Cursor flag tells DRC to skip destroy on the result (it's a borrow).
function rewriteZeroCopyBridge(node: Node, toBytes: boolean): Node {
	const cd = node.data as CallExprData;
	if (cd.arguments.length < 1) return node;
	const receiver = cd.arguments[0];
	const loc = node.location;
	const targetType = toBytes
		? createArray(createPrimitive(TypeKind.Uint8))
		: stringType();
	const conv = makeHiddenStdConv(receiver, targetType, loc);
	conv.flags = conv.flags | NodeFlag.Cursor;
	return conv;
}

function rewriteResultToLiteral(node: Node, isOk: boolean, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	let resType = node.nodeType;
	// Fallback: infer Result type from argument when nodeType is missing
	if (resType === null || resType.kind !== TypeKind.Result) {
		if (cd.arguments.length > 0 && cd.arguments[0].nodeType !== null) {
			if (isOk) {
				resType = createResult(cd.arguments[0].nodeType, stringType());
			} else {
				resType = createResult(unknownType(), cd.arguments[0].nodeType);
			}
			node.nodeType = resType;
		}
		if (resType === null || resType.kind !== TypeKind.Result) {
			return node;
		}
	}

	const keys: string[] = ["ok"];
	const values: Node[] = [makeBool(isOk, loc)];

	if (isOk) {
		// Only add value if T is not void
		if (resType.typeReturn.kind !== TypeKind.Void) {
			keys.push("value");
			values.push(cd.arguments[0]);
		}
	} else {
		// Only add error if E is not void
		if (resType.typeExtra.kind !== TypeKind.Void) {
			keys.push("error");
			values.push(cd.arguments[0]);
		}
	}

	const literal = makeObjectLiteral(keys, values, loc);
	// V4: CRITICAL — preserve the monomorphized Result type from the call node
	literal.nodeType = resType;
	return literal;
}

// ===== Typed JSON — @builtin("JsonParse") / @builtin("JsonStringify") =====
// AST rewriting only — C code generation delegated to codegen/c/json.ms

// Dedup check — prevents generating the same helper twice.
// Uses ctx.emittedHelpers (per-compilation) instead of module-level state.

function rewriteJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	const typeArgStr = findCallTypeArg(node);
	// No explicit type arg → untyped JSON.parse(str) returning JsonValue
	if (typeArgStr === "") {
		return rewriteUntypedJsonParse(node, ctx);
	}

	const structType = resolveJsonTargetType(typeArgStr, ctx);
	if (structType === null) return node;

	const helperName = "__jsonParse_" + typeArgStr;
	const resultType = createResult(structType, stringType());

	if (!hasEmitted(ctx, helperName)) {
		const emitNode = generateJsonParseC(helperName, typeArgStr, structType, loc);
		if (emitNode === null) return node;
		registerHelper(helperName, emitNode, ctx);
	}

	const newCallee = makeIdent(helperName, loc);
	const result = makeCall(newCallee, cd.arguments, loc);
	result.nodeType = resultType;
	return result;
}

// Untyped JSON.parse(str) — returns MsJsonValue* (JsonValue class type)
function rewriteUntypedJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	if (cd.arguments.length < 1) return node;

	// Look up JsonValue type from checker
	if (ctx.checkerCtx === null) return node;
	const jvSym = lookupSymbol(ctx.checkerCtx.table, "JsonValue");
	if (jvSym === null || jvSym.symbolType === null) return node;
	const jvType = jvSym.symbolType;  // Ref<Struct("JsonValue", ...)>

	ensureJsonInclude(ctx, loc);

	const call = makeCall(makeIdent("msJsonParse", loc), cd.arguments, loc);
	call.nodeType = jvType;
	return call;
}

function rewriteJsonStringify(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	let typeArgStr = findCallTypeArg(node);
	// Infer T from argument type when no explicit type arg (e.g., JSON.stringify(person))
	if (typeArgStr === "" && cd.arguments.length > 0 && cd.arguments[0].nodeType !== null) {
		const argType = unwrapRef(cd.arguments[0].nodeType);
		if (argType.kind === TypeKind.Struct && argType.typeName !== "") {
			typeArgStr = argType.typeName;
		}
	}
	if (typeArgStr === "") return node;

	let structType = resolveJsonTargetType(typeArgStr, ctx);
	// Anonymous struct types have no symbol — use argument's type directly
	if (structType === null && cd.arguments.length > 0 && cd.arguments[0].nodeType !== null) {
		const argInner = unwrapRef(cd.arguments[0].nodeType);
		if (argInner.kind === TypeKind.Struct && argInner.typeName === typeArgStr) {
			structType = argInner;
		}
	}
	if (structType === null) return node;

	const helperName = "__jsonStringify_" + typeArgStr;

	if (!hasEmitted(ctx, helperName)) {
		const emitNode = generateJsonStringifyC(helperName, typeArgStr, structType, loc);
		if (emitNode === null) return node;
		registerHelper(helperName, emitNode, ctx);
	}

	const newCallee = makeIdent(helperName, loc);
	const result = makeCall(newCallee, cd.arguments, loc);
	result.nodeType = stringType();
	return result;
}

// ===== Tests =====

import { runThreePasses } from "../../checker/checkPass";
import { createContext } from "../../checker/context";
import { openScope, ScopeKind } from "../../checker/symbol";
import { createTransformContextWithChecker } from "../context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { ProgramData, ExprStmtData } from "../../ast/node";

// Simulate the full prelude → check → builtinLower pipeline.
// Returns the callee name of the first CallExpr in user code after lowering.
function preludeLowerCallee(preludeSrc: string, userSrc: string): string {
	const ctx = createContext();
	const ppr = parseSource(preludeSrc);
	if (!ppr.ok) return "PRELUDE_PARSE_ERR";
	runThreePasses(ctx, ppr.value);

	openScope(ctx.table, ScopeKind.Module);
	const upr = parseSource(userSrc);
	if (!upr.ok) return "USER_PARSE_ERR";
	runThreePasses(ctx, upr.value);

	const tctx = createTransformContextWithChecker(ctx);
	const lowered = lowerBuiltins(upr.value, tctx);

	const pd = lowered.data as ProgramData;
	if (pd.programStmts.length === 0) return "NO_STMTS";
	const stmt = pd.programStmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return "NOT_EXPR";
	const es = stmt.data as ExprStmtData;
	if (es.expr.kind !== NodeKind.CallExpr) return "NOT_CALL";
	const cd = es.expr.data as CallExprData;
	if (cd.callee.kind === NodeKind.Identifier) {
		const id = cd.callee.data as IdentifierData;
		return id.name;
	}
	if (cd.callee.kind === NodeKind.MemberExpr) return "STILL_MEMBER";
	return "OTHER_KIND";
}

test "passthrough non-call" { assert stmtCountAfter("const x = 1;", lowerBuiltins) === 1; }

test "passthrough plain call" { assert firstExprKindAfter("foo();", lowerBuiltins) === NodeKind.CallExpr; }

test "passthrough function decl" { assert firstStmtKindAfter("function foo() {}", lowerBuiltins) === NodeKind.FunctionDecl; }

test "passthrough if stmt" { assert firstStmtKindAfter("if (x) {}", lowerBuiltins) === NodeKind.IfStmt; }

// Returns the NodeKind of the first ExprStmt's expression after lowering.
function preludeLowerExprKind(preludeSrc: string, userSrc: string): NodeKind {
	const ctx = createContext();
	const ppr = parseSource(preludeSrc);
	if (!ppr.ok) return NodeKind.NumberLiteral;
	runThreePasses(ctx, ppr.value);
	openScope(ctx.table, ScopeKind.Module);
	const upr = parseSource(userSrc);
	if (!upr.ok) return NodeKind.NumberLiteral;
	runThreePasses(ctx, upr.value);
	const tctx = createTransformContextWithChecker(ctx);
	const lowered = lowerBuiltins(upr.value, tctx);
	const pd = lowered.data as ProgramData;
	if (pd.programStmts.length === 0) return NodeKind.NumberLiteral;
	const stmt = pd.programStmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return NodeKind.NumberLiteral;
	const es = stmt.data as ExprStmtData;
	return es.expr.kind;
}

test "@builtin on extern function rewrites to object literal" {
	const prelude = "@builtin(\"msResultOk\") extern function ok(val: number): number;";
	const kind = preludeLowerExprKind(prelude, "ok(42);");
	assert kind === NodeKind.ObjectLiteral;
}

test "extern from identifier callee left for codegen" {
	const prelude = "extern function parseInt(s: string): number from \"msStringParseInt\";";
	const result = preludeLowerCallee(prelude, "parseInt(\"42\");");
	assert result === "parseInt";
}

test "anonymous object stringify basic" {
	const prelude = "@builtin(\"JsonStringify\") extern function jsonStringify(value: number): string;";
	const result = preludeLowerCallee(prelude, "jsonStringify({ x: 1, y: 2 });");
	assert result === "__jsonStringify___anon2__xn__yn";
}

test "anonymous object stringify string field" {
	const prelude = "@builtin(\"JsonStringify\") extern function jsonStringify(value: number): string;";
	const result = preludeLowerCallee(prelude, "jsonStringify({ name: \"hi\" });");
	assert result === "__jsonStringify___anon1__names";
}

test "anonymous object stringify mixed types" {
	const prelude = "@builtin(\"JsonStringify\") extern function jsonStringify(value: number): string;";
	const result = preludeLowerCallee(prelude, "jsonStringify({ a: 1, b: \"x\" });");
	assert result === "__jsonStringify___anon2__an__bs";
}
