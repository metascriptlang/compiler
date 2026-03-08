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
// Typed JSON (JsonParse/JsonStringify): generates per-type helper functions at
// compile time. Equivalent to macro-based expansion in other compilers — uses
// @builtin + struct field metadata instead since we lack a macro system.

import {
	Node, NodeKind, NodeFlag, DeclKind, ProgramData, SourceLocation,
	CallExprData, MemberExprData, IdentifierData,
} from "../../ast/node";
import { Type, TypeKind, isNumeric, createResult, createArray, createPrimitive, stringType, booleanType, numberType, unknownType } from "../../checker/types";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall, makeIdentResolved, makeCallResolved,
	makeObjectLiteral, makeTypedObjectLiteral, makeBool, makeHiddenStdConv,
	makeVarDecl, makeBlock, makeReturn, makeIf, makeBinary, makeUnary,
	makeMember, makeString, makeNumber, makeFnDecl, makeExprStmt,
} from "../util";
import { findCallTypeArg } from "../../parser/context";
import { JsonKind } from "../../../std/core/json/types";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerBuiltins(program: Node, ctx: TransformContext): Node {
	const result = walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.CallExpr) {
			return lowerCallExpr(node, ctx);
		}
		return node;
	});
	// Append generated helper functions (e.g. __jsonParse_Person)
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
	// C-only: primitive .toString() → msNumberToString(obj) / msBoolToString(obj)
	// NOTE: All other MemberExpr UFCS rewrites (instance extensions, static class methods)
	// are handled by extensionMethodLower — the single canonical UFCS converter.
	// nativeName resolution happens at codegen (reads resolvedSym.nativeName).
	if (!ctx.jsBackend) {
		if (cd.callee.kind === NodeKind.MemberExpr) {
			const me2 = cd.callee.data as MemberExprData;
			if (me2.property === "toString" && me2.object.nodeType !== null) {
				const tk = me2.object.nodeType.kind;
				if (isNumeric(me2.object.nodeType)) {
					const call = makeCall(makeIdent("msNumberToString", loc), [me2.object], loc);
					call.nodeType = node.nodeType;
					return call;
				}
				if (tk === TypeKind.Boolean) {
					const call = makeCall(makeIdent("msBoolToString", loc), [me2.object], loc);
					call.nodeType = node.nodeType;
					return call;
				}
			}
		}
	}

	return node;
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
// Generates per-type deserializer/serializer functions at compile time.
// Reads explicit type arg from parser side-channel, looks up struct fields from checker.

// JsonKind enum imported from std/core/json/types.ms

// Resolve the struct type for the explicit type arg (e.g., "Person" → struct type with fields).
function resolveJsonTargetType(typeArgStr: string, ctx: TransformContext): Type {
	if (ctx.checkerCtx === null) return null as unknown as Type;
	const sym = lookupSymbol(ctx.checkerCtx.table, typeArgStr);
	if (sym === null) return null as unknown as Type;
	if (sym.symbolType === null) return null as unknown as Type;
	// Must be a struct (interface) type
	if (sym.symbolType.kind === TypeKind.Struct) return sym.symbolType;
	// Could be Ref<Struct> (class) — unwrap
	if (sym.symbolType.kind === TypeKind.Ref && sym.symbolType.typeReturn !== null) {
		if (sym.symbolType.typeReturn.kind === TypeKind.Struct) return sym.symbolType.typeReturn;
	}
	return null as unknown as Type;
}

// Map a field type to JsonKind constant and accessor field name on JsonValue.
// Returns [jsonKind, accessorName] or [-1, ""] if unsupported.
function jsonFieldMapping(fieldType: Type): number {
	if (fieldType === null) return -1;
	return match (fieldType.kind) {
		TypeKind.String => JsonKind.String,
		TypeKind.Number | TypeKind.Float64 => JsonKind.Number,
		TypeKind.Boolean => JsonKind.Bool,
		_ => -1,
	};
}

function jsonFieldAccessor(fieldType: Type): string {
	if (fieldType === null) return "";
	return match (fieldType.kind) {
		TypeKind.String => "strVal",
		TypeKind.Number | TypeKind.Float64 => "numVal",
		TypeKind.Boolean => "boolVal",
		_ => "",
	};
}

// Build a Result error return: { ok: false, error: "msg" }
function makeResultErr(msg: string, resultType: Type, loc: SourceLocation): Node {
	const keys: string[] = ["ok", "error"];
	const vals: Node[] = [makeBool(false, loc), makeString(msg, loc)];
	const lit = makeTypedObjectLiteral(keys, vals, resultType, loc);
	return makeReturn(lit, loc);
}

// Build a Result ok return: { ok: true, value: expr }
function makeResultOkReturn(valueExpr: Node, resultType: Type, loc: SourceLocation): Node {
	const keys: string[] = ["ok", "value"];
	const vals: Node[] = [makeBool(true, loc), valueExpr];
	const lit = makeTypedObjectLiteral(keys, vals, resultType, loc);
	return makeReturn(lit, loc);
}

// Check if a helper function name already exists in pendingDecls.
function hasPendingDecl(ctx: TransformContext, name: string): boolean {
	let i = 0;
	while (i < ctx.pendingDecls.length) {
		const decl = ctx.pendingDecls[i];
		if (decl.kind === NodeKind.FunctionDecl) {
			const fd = decl.data as { fnName: string };
			if (fd.fnName === name) return true;
		}
		i = i + 1;
	}
	return false;
}

function rewriteJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	// Read explicit type arg from parser side-channel
	const typeArgStr = findCallTypeArg(node);
	if (typeArgStr === "") return node;  // no explicit type arg, can't generate

	// Resolve struct type
	const structType = resolveJsonTargetType(typeArgStr, ctx);
	if (structType === null) return node;  // unknown type, leave as-is

	// Build helper function name
	const helperName = "__jsonParse_" + typeArgStr;
	const resultType = createResult(structType, stringType());

	// Generate helper if not already generated
	if (!hasPendingDecl(ctx, helperName)) {
		const helperFn = generateJsonParseHelper(helperName, typeArgStr, structType, resultType, node);
		if (helperFn !== null) {
			ctx.pendingDecls.push(helperFn);
		}
	}

	// Replace call: jsonParse<Person>(input) → __jsonParse_Person(input)
	const newCallee = makeIdent(helperName, loc);
	const result = makeCall(newCallee, cd.arguments, loc);
	result.nodeType = resultType;
	return result;
}

function generateJsonParseHelper(
	helperName: string, typeName: string, structType: Type, resultType: Type, refNode: Node
): Node {
	const loc = refNode.location;
	const stmts: Node[] = [];

	// const $jr = parseJson(input);
	const inputIdent = makeIdent("input", loc);
	const parseCall = makeCall(makeIdent("parseJson", loc), [inputIdent], loc);
	parseCall.nodeType = resultType;  // approximate — parseJson returns Result<JsonValue, string>
	stmts.push(makeVarDecl("$jr", parseCall, DeclKind.Const, loc));

	// if (!$jr.ok) { return { ok: false, error: $jr.error }; }
	const jrOk = makeMember(makeIdent("$jr", loc), "ok", loc);
	jrOk.nodeType = booleanType();
	const notOk = makeUnary("!", jrOk, loc);
	const jrError = makeMember(makeIdent("$jr", loc), "error", loc);
	jrError.nodeType = stringType();
	const errKeys1: string[] = ["ok", "error"];
	const errVals1: Node[] = [makeBool(false, loc), jrError];
	const errLit1 = makeTypedObjectLiteral(errKeys1, errVals1, resultType, loc);
	const errReturn1 = makeReturn(errLit1, loc);
	stmts.push(makeIf(notOk, makeBlock([errReturn1], loc), makeBlock([], loc), loc));

	// const $jv = $jr.value;
	const jrValue = makeMember(makeIdent("$jr", loc), "value", loc);
	stmts.push(makeVarDecl("$jv", jrValue, DeclKind.Const, loc));

	// if ($jv.kind !== JsonKind.Object) { return { ok: false, error: "expected object" }; }
	const jvKind = makeMember(makeIdent("$jv", loc), "kind", loc);
	jvKind.nodeType = numberType();
	const kindCheck = makeBinary(jvKind, "!==", makeNumber(JsonKind.Object as number, loc), loc);
	const errReturn2 = makeResultErr("expected object", resultType, refNode.location);
	stmts.push(makeIf(kindCheck, makeBlock([errReturn2], loc), makeBlock([], loc), loc));

	// Per-field extraction
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	const okKeys: string[] = [];
	const okVals: Node[] = [];

	let fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];
		const jsonKind = jsonFieldMapping(ftype);
		const accessor = jsonFieldAccessor(ftype);
		if (jsonKind < 0 || accessor === "") {
			return null as unknown as Node;  // unsupported field type — bail out entirely
		}

		const varName = "$f" + fi.toString();

		// const $fN = get($jv, "fieldName");
		const getCall = makeCall(makeIdent("get", loc), [makeIdent("$jv", loc), makeString(fname, loc)], loc);
		stmts.push(makeVarDecl(varName, getCall, DeclKind.Const, loc));

		// if ($fN.kind !== expectedKind) { return { ok: false, error: "field 'name': expected type" }; }
		const fKind = makeMember(makeIdent(varName, loc), "kind", loc);
		fKind.nodeType = numberType();
		const expectedKindName = match (jsonKind) {
			JsonKind.String => "string",
			JsonKind.Number => "number",
			JsonKind.Bool => "boolean",
			_ => "unknown",
		};
		const fCheck = makeBinary(fKind, "!==", makeNumber(jsonKind, loc), loc);
		const errMsg = "field '" + fname + "': expected " + expectedKindName;
		const errReturnF = makeResultErr(errMsg, resultType, refNode.location);
		stmts.push(makeIf(fCheck, makeBlock([errReturnF], loc), makeBlock([], loc), loc));

		// Build value accessor: $fN.strVal / $fN.numVal / $fN.boolVal
		const fVal = makeMember(makeIdent(varName, loc), accessor, loc);
		fVal.nodeType = ftype;
		okKeys.push(fname);
		okVals.push(fVal);

		fi = fi + 1;
	}

	// return { ok: true, value: { field1: $f0.strVal, field2: $f1.numVal, ... } };
	const innerObj = makeTypedObjectLiteral(okKeys, okVals, structType, loc);
	const okReturn = makeResultOkReturn(innerObj, resultType, refNode.location);
	stmts.push(okReturn);

	// Build function: function __jsonParse_Person(input: string): Result<Person, string> { ... }
	const paramNames: string[] = ["input"];
	const paramTypes: string[] = ["string"];
	const body = makeBlock(stmts, loc);
	const fn = makeFnDecl(helperName, paramNames, paramTypes, body, "", "Result", loc);
	fn.nodeType = null as unknown as Type;  // let codegen infer from body
	return fn;
}

function rewriteJsonStringify(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	// Read explicit type arg from parser side-channel
	const typeArgStr = findCallTypeArg(node);
	if (typeArgStr === "") return node;

	// Resolve struct type
	const structType = resolveJsonTargetType(typeArgStr, ctx);
	if (structType === null) return node;

	// Build helper function name
	const helperName = "__jsonStringify_" + typeArgStr;

	// Generate helper if not already generated
	if (!hasPendingDecl(ctx, helperName)) {
		const helperFn = generateJsonStringifyHelper(helperName, typeArgStr, structType, node);
		if (helperFn !== null) {
			ctx.pendingDecls.push(helperFn);
		}
	}

	// Replace call: jsonStringify<Person>(value) → __jsonStringify_Person(value)
	const newCallee = makeIdent(helperName, loc);
	const result = makeCall(newCallee, cd.arguments, loc);
	result.nodeType = stringType();
	return result;
}

function generateJsonStringifyHelper(
	helperName: string, typeName: string, structType: Type, refNode: Node
): Node {
	const loc = refNode.location;
	const stmts: Node[] = [];

	// const $o = jsonObject();
	const objCall = makeCall(makeIdent("jsonObject", loc), [], loc);
	stmts.push(makeVarDecl("$o", objCall, DeclKind.Const, loc));

	// Per-field: set($o, "fieldName", jsonString/jsonNumber/jsonBool(value.field))
	const fieldNames = structType.typeNames;
	const fieldTypes = structType.typeChildren;
	if (fieldNames === null || fieldTypes === null) return null as unknown as Node;

	let fi = 0;
	while (fi < fieldNames.length) {
		const fname = fieldNames[fi];
		const ftype = fieldTypes[fi];

		// Determine JSON constructor function name
		const jsonCtorName = match (ftype.kind) {
			TypeKind.String => "jsonString",
			TypeKind.Number | TypeKind.Float64 => "jsonNumber",
			TypeKind.Boolean => "jsonBool",
			_ => "",
		};
		if (jsonCtorName === "") {
			return null as unknown as Node;  // unsupported field type — bail out entirely
		}

		// value.fieldName
		const fieldAccess = makeMember(makeIdent("value", loc), fname, loc);
		fieldAccess.nodeType = ftype;

		// jsonString(value.fieldName) / jsonNumber(...) / jsonBool(...)
		const wrappedVal = makeCall(makeIdent(jsonCtorName, loc), [fieldAccess], loc);

		// set($o, "fieldName", wrappedValue)
		const setCall = makeCall(makeIdent("set", loc), [makeIdent("$o", loc), makeString(fname, loc), wrappedVal], loc);
		stmts.push(makeExprStmt(setCall, loc));

		fi = fi + 1;
	}

	// return stringify($o);
	const stringifyCall = makeCall(makeIdent("stringify", loc), [makeIdent("$o", loc)], loc);
	stringifyCall.nodeType = stringType();
	stmts.push(makeReturn(stringifyCall, loc));

	// Build function: function __jsonStringify_Person(value: Person): string { ... }
	const paramNames: string[] = ["value"];
	const paramTypes: string[] = [typeName];
	const body = makeBlock(stmts, loc);
	return makeFnDecl(helperName, paramNames, paramTypes, body, "", "string", loc);
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
	// 1. Create checker context, parse+check prelude in Global scope
	const ctx = createContext();
	const ppr = parseSource(preludeSrc);
	if (!ppr.ok) return "PRELUDE_PARSE_ERR";
	runThreePasses(ctx, ppr.value);

	// 2. Open Module scope, parse+check user code
	openScope(ctx.table, ScopeKind.Module);
	const upr = parseSource(userSrc);
	if (!upr.ok) return "USER_PARSE_ERR";
	runThreePasses(ctx, upr.value);

	// 3. Run builtinLower on user AST with checker context
	const tctx = createTransformContextWithChecker(ctx);
	const lowered = lowerBuiltins(upr.value, tctx);

	// 4. Extract callee name from first ExprStmt's CallExpr
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
	// @builtin("msResultOk") should rewrite call → ObjectLiteral via inline expansion
	assert kind === NodeKind.ObjectLiteral;
}

test "extern from identifier callee left for codegen" {
	const prelude = "extern function parseInt(s: string): number from \"msStringParseInt\";";
	const result = preludeLowerCallee(prelude, "parseInt(\"42\");");
	// extern from on identifier callee is NOT rewritten — genCallExpr handles it
	assert result === "parseInt";
}
