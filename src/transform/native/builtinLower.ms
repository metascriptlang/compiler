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
// Typed JSON (JsonParse/JsonStringify): specialization handled in checker phase
// (generateJsonParseInstance/generateJsonStringifyInstance). Transform handles untyped + primitives.

import { Node, NodeKind, NodeFlag, ProgramData, SourceLocation, CallExprData, MemberExprData, IdentifierData, BinaryExprData, NewExprData, Type, TypeKind } from "../../ast/node";
import { isNumeric, createResult, createArray, createPrimitive, stringType, unknownType, unwrapRef, typeNameOf, isResult, isPromise, getPromiseInner, getResultOkType, getResultErrType } from "../../checker/types";
import { findExtension } from "../../checker/context";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall, makeString, makeNumber, makeMember, makeUnary,
	makeObjectLiteral, makeBool, makeNull, makeHiddenStdConv, enumToStringName,
} from "../util";
import { findCallTypeArg } from "../../parser/context";
import { rewriteEcho } from "./debugLower";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerBuiltins(program: Node, ctx: TransformContext): Node {
	const result = walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.CallExpr) {
			return lowerCallExpr(node, ctx);
		}
		// new Promise(executor) → msPromiseNew(executor)
		if (node.kind === NodeKind.NewExpr) {
			return lowerNewPromise(node);
		}
		// arr.length = n → msXxxArraySetLen(&arr, n)
		if (node.kind === NodeKind.BinaryExpr) {
			return lowerLengthAssign(node, ctx);
		}
		return node;
	});
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
			if (me2.property === "toString") {
				if (me2.object.nodeType !== null) {
					return lowerToString(node, me2.object, me2.object.nodeType, loc, ctx);
				}
				// Fallback: NumberLiteral/BooleanLiteral may not have nodeType stamped by checker
				if (me2.object.kind === NodeKind.NumberLiteral) {
					const call = makeCall(makeIdent("msNumberToString", loc), [me2.object], loc);
					call.nodeType = stringType();
					return call;
				}
				if (me2.object.kind === NodeKind.BooleanLiteral) {
					const call = makeCall(makeIdent("msBoolToString", loc), [me2.object], loc);
					call.nodeType = stringType();
					return call;
				}
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
	// Number/int/float → msNumberToStringRadix(value, radix) — radix defaults to 10
	if (isNumeric(objType)) {
		const cd2 = callNode.data as CallExprData;
		const radixArg = cd2.arguments.length > 0 ? cd2.arguments[0] : makeNumber(10, loc);
		const call = makeCall(makeIdent("msNumberToStringRadix", loc), [obj, radixArg], loc);
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
	// Struct/Class → JSON stringify (same as console.log default)
	const inner = unwrapRef(objType);
	if (inner.kind === TypeKind.Struct && inner.typeName !== "") {
		// Use JSON.stringify which is already handled by the checker
		// For .toString() fallback, just pass through — the caller handles it
		return obj;
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


// ===== Builtin Inline Expansion =====
// Handles @builtin("Name") — known compiler builtins get inline C patterns.

// Type tag for typed Promise.then/catch dispatch (matches MS_TYPETAG_* in combinator.h)
function typeTagFor(t: Type): number {
	if (t === null) return 0;
	return match (t.kind) {
		TypeKind.Void | TypeKind.Unknown => 0,
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => 2,
		TypeKind.String => 3,
		TypeKind.Struct | TypeKind.Ref | TypeKind.Ptr | TypeKind.Array => 0,
		_ => 1,  // int8-64, uint8-64, bool, enum — all fit in void*
	};
}

// Box a value for void* storage in msFuture (Promise.resolve, spawn return)
function boxValueForFuture(node: Node, loc: SourceLocation): Node {
	if (node === null) return makeNull(loc);
	if (node.nodeType === null) return node;
	return match (node.nodeType.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(makeIdent("msBoxDouble", loc), [node], loc),
		TypeKind.Boolean => makeCall(makeIdent("msBoxBool", loc), [node], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 |
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => makeCall(makeIdent("msBoxInt32", loc), [node], loc),
		_ => node,
	};
}

function unboxFnForType(t: Type): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msUnboxDouble",
		TypeKind.Boolean => "msUnboxBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "msUnboxInt32",
		TypeKind.String => "msUnboxString",
		_ => "",
	};
}

// Typed future readers — msFutureReadT handles both boxed (isBoxed=true, from spawn)
// and typed (isBoxed=false, from async) paths internally. Replaces the
// msUnboxT(msWaitFor(fut)) chain with a single call. See future.h per-type readers.
export function typedFutureReadFn(t: Type): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msFutureReadDouble",
		TypeKind.Boolean => "msFutureReadBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "msFutureReadInt32",
		_ => "",
	};
}

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

	if (builtinKind === "ResultOk") {
		return rewriteResultToLiteral(node, true, ctx);
	}
	if (builtinKind === "ResultErr") {
		return rewriteResultToLiteral(node, false, ctx);
	}

	// Promise.then/catch/finally — rewrite to typed C runtime calls
	if (builtinKind === "PromiseThen" || builtinKind === "PromiseCatch" || builtinKind === "PromiseFinally") {
		if (cd.callee.kind === NodeKind.MemberExpr && cd.arguments.length >= 1) {
			const me = cd.callee.data as MemberExprData;
			if (builtinKind === "PromiseThen") {
				// Determine type tag from Promise<T>'s inner type
				const innerType = getPromiseInner(me.object.nodeType);
				const tag = typeTagFor(innerType);
				const args: Node[] = [me.object, cd.arguments[0], makeNumber(tag, loc)];
				const newCall = makeCall(makeIdent("msFutureThenTyped", loc), args, loc);
				newCall.nodeType = node.nodeType;
				return newCall;
			} else if (builtinKind === "PromiseCatch") {
				// Error is always string in MetaScript
				const args: Node[] = [me.object, cd.arguments[0], makeNumber(3, loc)];
				const newCall = makeCall(makeIdent("msFutureCatchTyped", loc), args, loc);
				newCall.nodeType = node.nodeType;
				return newCall;
			} else {
				// PromiseFinally — no value, no type tag needed
				const args: Node[] = [me.object];
				for (const a of cd.arguments) { args.push(a); }
				const newCall = makeCall(makeIdent("msFutureFinally", loc), args, loc);
				newCall.nodeType = node.nodeType;
				return newCall;
			}
		}
		return node;
	}

	// Promise.resolve(val) — box the value for void* storage
	if (builtinKind === "PromiseResolve") {
		if (cd.arguments.length >= 1) {
			const valArg = cd.arguments[0];
			const boxed = boxValueForFuture(valArg, loc);
			const resolveCall = makeCall(makeIdent("msPromiseResolve", loc), [boxed], loc);
			resolveCall.nodeType = node.nodeType;
			return resolveCall;
		}
		return node;
	}

	if (builtinKind === "PromiseSpawn") {
		// Rewrite spawn(fn) → msSpawn(fn)
		const spawnCall = makeCall(makeIdent("msSpawn", loc), cd.arguments, loc);
		spawnCall.nodeType = node.nodeType;
		return spawnCall;
	}

	if (builtinKind === "WaitFor") {
		// waitFor(fut) → msUnboxT(msWaitFor(fut))
		// msWaitFor blocks + returns void* (boxed). Wrap with unbox for the return type.
		// Note: builtinLower operates at expression level (single node replacement),
		// so we can't use the msWaitForReady + msFutureReadT two-statement pattern
		// here. That pattern is used by awaitLower (statement-level expansion).
		const waitCall = makeCall(makeIdent("msWaitFor", loc), cd.arguments, loc);
		const retType = node.nodeType;
		if (retType === null || retType.kind === TypeKind.Void) return waitCall;
		const unboxFn = unboxFnForType(retType);
		if (unboxFn !== "") {
			const unboxCall = makeCall(makeIdent(unboxFn, loc), [waitCall], loc);
			unboxCall.nodeType = retType;
			return unboxCall;
		}
		// Struct types: codegen expands msUnboxStruct(ptr) → copy out + free shell
		const unboxCall = makeCall(makeIdent("msUnboxStruct", loc), [waitCall], loc);
		unboxCall.nodeType = retType;
		return unboxCall;
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

	// String(x) → x.toString() → leverages existing .toString() infrastructure
	if (builtinKind === "ToString" && cd.arguments.length === 1) {
		const arg = cd.arguments[0];
		const argType = arg.nodeType;
		// String identity: String("hello") → "hello"
		if (argType !== null && argType.kind === TypeKind.String) return arg;
		// Delegate to .toString() which handles number, boolean, enum, struct, array
		const toStringCall = makeCall(makeMember(arg, "toString", loc), [], loc);
		toStringCall.nodeType = stringType();
		if (argType !== null) {
			return lowerToString(toStringCall, arg, argType, loc, ctx);
		}
		return toStringCall;
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
	if (resType === null || !isResult(resType)) {
		if (cd.arguments.length > 0 && cd.arguments[0].nodeType !== null) {
			if (isOk) {
				resType = createResult(cd.arguments[0].nodeType, stringType());
			} else {
				resType = createResult(unknownType(), cd.arguments[0].nodeType);
			}
			node.nodeType = resType;
		}
		if (resType === null || !isResult(resType)) {
			return node;
		}
	}

	const keys: string[] = ["ok"];
	const values: Node[] = [makeBool(isOk, loc)];

	if (isOk) {
		const okType = getResultOkType(resType);
		if (okType !== null && okType.kind !== TypeKind.Void) {
			keys.push("value");
			values.push(cd.arguments[0]);
		}
	} else {
		const errType = getResultErrType(resType);
		if (errType !== null && errType.kind !== TypeKind.Void) {
			keys.push("error");
			values.push(cd.arguments[0]);
		}
	}

	const literal = makeObjectLiteral(keys, values, loc);
	literal.nodeType = resType;
	return literal;
}

// ===== Typed JSON — @builtin("JsonParse") / @builtin("JsonStringify") =====
// Typed struct paths handled by checker. This handles untyped parse + primitive stringify.

function rewriteJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	const typeArgStr = findCallTypeArg(node);
	// No explicit type arg → untyped JSON.parse(str) returning JsonValue
	if (typeArgStr === "") {
		return rewriteUntypedJsonParse(node, ctx);
	}

	// Typed path: already handled by checker (generateJsonParseInstance)
	return node;
}

// Untyped JSON.parse(str) — returns Result<JsonValue, string>
// Rewrites to parseJson(str) from std/core/json/parser.ms.
function rewriteUntypedJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	if (cd.arguments.length < 1) return node;

	// Pure MetaScript: JSON.parse(str) → parseJson(str)
	// Resolve symbol so codegen emits the correct mangled name
	const parseIdent = makeIdent("parseJson", loc);
	if (ctx.checkerCtx !== null) {
		const parseSym = lookupSymbol(ctx.checkerCtx.table, "parseJson");
		if (parseSym !== null) {
			parseIdent.resolvedSym = parseSym;
			if (parseSym.symbolType !== null) parseIdent.nodeType = parseSym.symbolType;
		}
	}
	const call = makeCall(parseIdent, cd.arguments, loc);
	if (ctx.checkerCtx !== null) {
		const jvSym = lookupSymbol(ctx.checkerCtx.table, "JsonValue");
		if (jvSym !== null && jvSym.symbolType !== null && jvSym.symbolType.kind !== TypeKind.Unknown) {
			call.nodeType = createResult(jvSym.symbolType, stringType());
		}
	}
	return call;
}

function rewriteJsonStringify(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	// Infer argument type
	if (cd.arguments.length === 0) return node;
	const argType = cd.arguments[0].nodeType !== null ? unwrapRef(cd.arguments[0].nodeType) : null;
	if (argType === null) return node;

	// Primitive types: stringify(jsonString/jsonNumber/jsonBool(value))
	const primWrapper = match (argType.kind) {
		TypeKind.String => "jsonString",
		TypeKind.Boolean => "jsonBool",
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "jsonNumber",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Enum => "jsonInt",
		_ => "",
	};
	if (primWrapper !== "") {
		const wrapIdent = makeIdent(primWrapper, loc);
		if (ctx.checkerCtx !== null) {
			const ws = lookupSymbol(ctx.checkerCtx.table, primWrapper);
			if (ws !== null) { wrapIdent.resolvedSym = ws; if (ws.symbolType !== null) wrapIdent.nodeType = ws.symbolType; }
		}
		const wrapped = makeCall(wrapIdent, cd.arguments, loc);
		const strIdent = makeIdent("stringify", loc);
		if (ctx.checkerCtx !== null) {
			const ss = lookupSymbol(ctx.checkerCtx.table, "stringify");
			if (ss !== null) { strIdent.resolvedSym = ss; if (ss.symbolType !== null) strIdent.nodeType = ss.symbolType; }
		}
		const result = makeCall(strIdent, [wrapped], loc);
		result.nodeType = stringType();
		return result;
	}

	// Typed struct/array stringify: already handled by checker (generateJsonStringifyInstance)
	return node;
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

// ===== arr.length = n → setLength(arr, n) sugar =====
// setLength is the real API. arr.length = n is syntactic sugar.
// Rewrites new Promise(executor) → msPromiseNew(executor)

function lowerNewPromise(node: Node): Node {
	if (node.nodeType !== null && isPromise(node.nodeType)) {
		const d = node.data as NewExprData;
		if (d.newArguments.length === 1) {
			const loc = node.location;
			const newCall = makeCall(makeIdent("msPromiseNew", loc), d.newArguments, loc);
			newCall.nodeType = node.nodeType;
			return newCall;
		}
	}
	return node;
}

// Rewrites BinaryExpr(=, MemberExpr(arr, "length"), n) → CallExpr to C runtime setLength.

function lowerLengthAssign(node: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend) return node;
	const d = node.data as BinaryExprData;
	if (d.operator !== "=") return node;
	if (d.left.kind !== NodeKind.MemberExpr) return node;
	const md = d.left.data as MemberExprData;
	if (md.property !== "length") return node;
	const objType = md.object.nodeType;
	if (objType === null || objType.kind !== TypeKind.Array) return node;

	const loc = node.location;
	const elemType = objType.typeReturn;

	// Pick the right C runtime function based on element type
	let fn = "msGenericArraySetLen";
	if (elemType !== null) {
		if (isNumeric(elemType) || elemType.kind === TypeKind.Boolean) {
			fn = "msNumberArraySetLen";
		} else if (elemType.kind === TypeKind.String) {
			fn = "msStringArraySetLen";
		} else if (elemType.kind === TypeKind.Ref || elemType.kind === TypeKind.Ptr) {
			fn = "msRefArraySetLen";
		}
	}

	// setLength takes &arr (mutates in place)
	const addrOf = makeUnary("&", md.object, loc);
	const result = makeCall(makeIdent(fn, loc), [addrOf, d.right], loc);
	result.nodeType = node.nodeType;
	return result;
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
	const prelude = "@builtin(\"ResultOk\") extern function ok(val: number): number;";
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
	assert result === "__jsonStringify___anon2__xi__yi";
}

test "anonymous object stringify string field" {
	const prelude = "@builtin(\"JsonStringify\") extern function jsonStringify(value: number): string;";
	const result = preludeLowerCallee(prelude, "jsonStringify({ name: \"hi\" });");
	assert result === "__jsonStringify___anon1__names";
}

test "anonymous object stringify mixed types" {
	const prelude = "@builtin(\"JsonStringify\") extern function jsonStringify(value: number): string;";
	const result = preludeLowerCallee(prelude, "jsonStringify({ a: 1, b: \"x\" });");
	assert result === "__jsonStringify___anon2__ai__bs";
}
