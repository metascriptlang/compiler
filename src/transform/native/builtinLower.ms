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
// JSON serialization is now user-land via std/serialize/json macros — no @builtin
// kinds remain for JSON-related rewrites here.

import { Node, NodeKind, NodeFlag, ProgramData, SourceLocation, CallExprData, MemberExprData, IdentifierData, BinaryExprData, Type, TypeKind } from "../../ast/node";
import { isNumeric, createResult, createArray, createPrimitive, stringType, unknownType, unwrapRef, typeNameOf, isResult, getResultOkType, getResultErrType } from "../../checker/types";
import { findExtension } from "../../checker/context";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall, makeString, makeNumber, makeMember, makeUnary,
	makeObjectLiteral, makeBool, makeHiddenStdConv, enumToStringName,
} from "../util";
import { findCallTypeArg } from "../../parser/context";
import { rewriteEcho } from "./debugLower";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";
import { tryLowerPromiseBuiltin, lowerNewPromise } from "../lowering/promiseLower";

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
// Per-T suffix helpers, typed readers, Promise.* / waitFor handlers, and
// new-Promise rewriting all live in src/transform/lowering/promiseLower.ms.
// See `tryLowerPromiseBuiltin` + `lowerNewPromise` imported at the top of this
// file. `isStructLikeType` moved to `../util` to break a circular import with
// promiseLower (asyncBridge + builtinLower + promiseLower all need it).

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

	// Promise.* / WaitFor dispatch lives in promiseLower.ms. A non-null return
	// means that pass rewrote the node; otherwise we continue with other handlers.
	const promiseRewrite = tryLowerPromiseBuiltin(node, builtinKind, ctx);
	if (promiseRewrite !== null) return promiseRewrite;

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

	const payloadType = isOk ? getResultOkType(resType) : getResultErrType(resType);
	if (payloadType !== null && payloadType.kind !== TypeKind.Void) {
		keys.push(isOk ? "value" : "error");
		values.push(cd.arguments[0]);
	}

	const literal = makeObjectLiteral(keys, values, loc);
	literal.nodeType = resType;
	return literal;
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
// Rewrites BinaryExpr(=, MemberExpr(arr, "length"), n) → CallExpr to C runtime setLength.
// `new Promise(executor) → msPromiseNew` lives in lowering/promiseLower.ms.

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

