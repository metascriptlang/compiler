// Closure Call Lowering — rewrite indirect closure calls to direct calls with explicit fn/env extraction
// Runs AFTER closureCallMarker (which sets isDirectCall = false), BEFORE codegen.
//
// Rewrites:
//   cb(args)  where isDirectCall === false
//   → ((msClosureFn)(cb.fn))(cb.env, args)
//
// This moves closure-calling logic from codegen (TAG_CALL_CLOSURE) to the transform layer,
// keeping codegen as a dumb emitter (only TAG_CALL_DIRECT).
//
// The fn pointer is cast to msClosureFn (typedef void (*msClosureFn)(void*, ...)) via TypeAssertion.
// Setting nodeType = null on the TypeAssertion forces codegen to use mangle(asType) path,
// and mangle("msClosureFn") passes through unchanged since it's all alphanumeric.

import {
	Node, NodeKind, SourceLocation, DeclKind,
	CallExprData, TypeAssertionData, ConditionalExprData,
	BinaryExprData,
} from "../../ast/node";
import { createNode } from "../../ast/node";
import { Type, TypeKind, createFunction, createPrimitive, voidType, numberType, stringType, booleanType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeMember, makeNull, syntheticToken } from "../util";

// Module-level context for type resolution during walk
let _ctx: TransformContext = null as unknown as TransformContext;

// ===== Main Entry Point =====

export function lowerClosureCalls(program: Node, ctx: TransformContext): Node {
	_ctx = ctx;
	walkNode(program, rewriteClosureCall);
	return program;
}

// ===== Rewriter =====

function rewriteClosureCall(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const cd = node.data as CallExprData;
	if (cd.isDirectCall) return node;

	const loc = node.location;
	const callee = cd.callee;

	// Reference compiler pattern (Implementation parity):
	//   env ? fn(args..., env) : ((direct_cast)fn)(args...)
	// - env LAST (not first) so named functions ignore the trailing env arg
	// - Conditional: if env is NULL, call without env at all

	const retStr = resolveClosureReturnStr(callee);

	// Extract env: callee.env
	const envMember = makeMember(callee, "env", loc);

	// Condition: callee.env !== null
	const envCheck = makeMember(callee, "env", loc);
	const nullNode = makeNull(loc);
	const condition = createNode(NodeKind.BinaryExpr, { operator: "!==", left: envCheck, right: nullNode } as unknown as BinaryExprData, syntheticToken(loc));

	// WITH env branch: ((cast)(callee.fn))(env, args...)
	// env FIRST matches our lambda lifting convention (_envP is first param)
	// Use __clFull__ marker for non-variadic typed cast (ARM64 ABI requires it).
	// Implementation parity: build a properly typed function pointer.
	const fnMemberWithEnv = makeMember(callee, "fn", loc);
	const fnCastWithEnv = createNode(NodeKind.TypeAssertion, { asExpr: fnMemberWithEnv, asType: "__clFull__" }, syntheticToken(loc));
	// Set nodeType for codegen's genClFullCast to read param/return types
	let clFullType = resolveCalleeType(callee);
	if (clFullType === null || clFullType.kind !== TypeKind.Function) {
		const retType = retStrToType(retStr);
		clFullType = buildCallSiteFnType(cd, retType);
	}
	fnCastWithEnv.nodeType = clFullType;
	const argsWithEnv: Node[] = [envMember];
	let i = 0;
	while (i < cd.arguments.length) {
		argsWithEnv.push(cd.arguments[i]);
		i = i + 1;
	}
	const callWithEnv = makeCall(fnCastWithEnv, argsWithEnv, loc);
	callWithEnv.nodeType = node.nodeType;
	(callWithEnv.data as CallExprData).isDirectCall = true;

	// WITHOUT env branch: ((directCast)(callee.fn))(args...) — no env
	// Standard closure pattern: codegen generates per-call-site typed function pointer cast.
	// We pass "__clHalf__" marker + callee's type so codegen can build the C cast.
	const fnMemberNoEnv = makeMember(callee, "fn", loc);
	const fnCastNoEnv = createNode(NodeKind.TypeAssertion, { asExpr: fnMemberNoEnv, asType: "__clHalf__" }, syntheticToken(loc));
	// Build Function type for codegen's genClHalfCast from the best available info.
	// Prefer resolved callee type; fall back to synthetic type from call-site args.
	let clHalfType = resolveCalleeType(callee);
	if (clHalfType === null || clHalfType.kind !== TypeKind.Function) {
		// Use return type from retStr (which resolves through aliases/symbols)
		const retType = retStrToType(retStr);
		clHalfType = buildCallSiteFnType(cd, retType);
	}
	fnCastNoEnv.nodeType = clHalfType;
	const argsNoEnv: Node[] = [];
	i = 0;
	while (i < cd.arguments.length) {
		argsNoEnv.push(cd.arguments[i]);
		i = i + 1;
	}
	const callNoEnv = makeCall(fnCastNoEnv, argsNoEnv, loc);
	callNoEnv.nodeType = node.nodeType;
	(callNoEnv.data as CallExprData).isDirectCall = true;

	// Conditional: env ? fn(args, env) : fn(args)
	const ternary = createNode(NodeKind.ConditionalExpr, {
		ternaryCondition: condition,
		ternaryConsequent: callWithEnv,
		ternaryAlternate: callNoEnv,
	} as unknown as ConditionalExprData, syntheticToken(loc));
	ternary.nodeType = node.nodeType;

	return ternary;
}

// Resolve callee to a Function type for clHalf cast generation.
// Tries nodeType first, then resolvedSym.symbolType.
// Falls back to parsing TypeReference annotation string.
function resolveCalleeType(callee: Node): Type {
	let t = callee.nodeType;
	if (t !== null && t.kind === TypeKind.Function) return t;
	if (callee.resolvedSym !== null && callee.resolvedSym.symbolType !== null) {
		t = callee.resolvedSym.symbolType;
		if (t.kind === TypeKind.Function) return t;
	}
	// TypeReference with annotation: parse "( param : type, ... ) => retType"
	if (t !== null && t.kind === TypeKind.TypeReference && t.typeName !== "") {
		const parsed = parseAnnotationToFnType(t.typeName);
		if (parsed !== null) return parsed;
	}
	if (callee.nodeType !== null && callee.nodeType.kind === TypeKind.TypeReference && callee.nodeType.typeName !== "") {
		const parsed = parseAnnotationToFnType(callee.nodeType.typeName);
		if (parsed !== null) return parsed;
	}
	return callee.nodeType;
}

// Parse function annotation string "( n : number ) => boolean" into a Function type.
function parseAnnotationToFnType(ann: string): Type {
	// Find "=> " to split params from return type
	const marker = "=> ";
	let arrowIdx = -1;
	let idx = 0;
	while (idx < ann.length - 3) {
		if (ann.slice(idx, idx + 3) === marker) {
			arrowIdx = idx;
		}
		idx = idx + 1;
	}
	if (arrowIdx < 0) return null;

	const retStr = ann.slice(arrowIdx + 3, ann.length).trim();
	const retType = retStrToType(retStr);

	// Parse params from the part before "=>"
	let paramPart = ann.slice(0, arrowIdx).trim();
	// Strip outer parens
	if (paramPart.length > 0 && paramPart.charAt(0) === "(") {
		paramPart = paramPart.slice(1, paramPart.length);
	}
	if (paramPart.length > 0 && paramPart.charAt(paramPart.length - 1) === ")") {
		paramPart = paramPart.slice(0, paramPart.length - 1);
	}
	paramPart = paramPart.trim();

	const paramTypes: Type[] = [];
	if (paramPart.length > 0) {
		// Split by "," and extract type after ":"
		let start = 0;
		let i = 0;
		while (i <= paramPart.length) {
			if (i === paramPart.length || paramPart.charAt(i) === ",") {
				const seg = paramPart.slice(start, i).trim();
				// Extract type: "name : type" → type part
				let colonIdx = -1;
				let j = 0;
				while (j < seg.length) {
					if (seg.charAt(j) === ":") { colonIdx = j; }
					j = j + 1;
				}
				let typeStr = seg;
				if (colonIdx >= 0) {
					typeStr = seg.slice(colonIdx + 1, seg.length).trim();
				}
				paramTypes.push(retStrToType(typeStr));
				start = i + 1;
			}
			i = i + 1;
		}
	}

	return createFunction(paramTypes, [], retType);
}

// Convert return type string (from resolveClosureReturnStr) to a Type.
function retStrToType(retStr: string): Type {
	if (retStr === "number" || retStr === "float64") return numberType();
	if (retStr === "boolean") return booleanType();
	if (retStr === "string") return stringType();
	if (retStr === "void") return voidType();
	if (retStr === "int32") return createPrimitive(TypeKind.Int32);
	if (retStr === "int64") return createPrimitive(TypeKind.Int64);
	// Default: pointer type (void* in C)
	return voidType();
}

// Build a synthetic Function type from call-site info (args + return type).
// Fallback when callee's type is unresolved (TypeReference alias).
function buildCallSiteFnType(cd: CallExprData, returnType: Type): Type {
	const paramTypes: Type[] = [];
	let i = 0;
	while (i < cd.arguments.length) {
		const argType = cd.arguments[i].nodeType;
		paramTypes.push(argType !== null ? argType : null);
		i = i + 1;
	}
	return createFunction(paramTypes, [], returnType !== null ? returnType : voidType());
}

// Resolve a closure callee's return type string from available type info.
// The checker may leave function-typed params as TypeReference with the raw
// annotation string (e.g. "( n : number ) => boolean"). We parse it.
function resolveClosureReturnStr(callee: Node): string {
	// Direct Function type on nodeType
	let t = callee.nodeType;
	if (t !== null && t.kind === TypeKind.Function && t.typeReturn !== null) {
		return typeKindToRetStr(t.typeReturn.kind);
	}
	// resolvedSym → symbolType
	if (callee.resolvedSym !== null && callee.resolvedSym.symbolType !== null) {
		t = callee.resolvedSym.symbolType;
		if (t.kind === TypeKind.Function && t.typeReturn !== null) {
			return typeKindToRetStr(t.typeReturn.kind);
		}
		// TypeReference with inline function annotation → parse "=> returnType"
		if (t.kind === TypeKind.TypeReference && t.typeName !== "") {
			return parseReturnFromAnnotation(t.typeName);
		}
	}
	return "";
}

// Extract return type name from a function type annotation string like "( n : number ) => boolean"
function parseReturnFromAnnotation(ann: string): string {
	const marker = "=> ";
	let idx = 0;
	while (idx < ann.length - 3) {
		if (ann.slice(idx, idx + 3) === marker) {
			return ann.slice(idx + 3, ann.length).trim();
		}
		idx += 1;
	}
	return "";
}

// Map a return type name string to closure fn cast type
function retStrToCastType(retStr: string): string {
	if (retStr === "number" || retStr === "float64") return "msClosureFnD";
	if (retStr === "boolean") return "msClosureFnB";
	if (retStr === "string") return "msClosureFnS";
	if (retStr === "void") return "msClosureFn";
	if (retStr === "int32") return "msClosureFnI";
	if (retStr === "int64") return "msClosureFnI64";
	if (retStr !== "") return "msClosureFnP";
	return "msClosureFnP";
}

// Map TypeKind to return type string
function typeKindToRetStr(kind: TypeKind): string {
	if (kind === TypeKind.Number || kind === TypeKind.Float64) return "number";
	if (kind === TypeKind.Boolean) return "boolean";
	if (kind === TypeKind.String) return "string";
	if (kind === TypeKind.Void || kind === TypeKind.Null) return "void";
	if (kind === TypeKind.Int8 || kind === TypeKind.Int16 || kind === TypeKind.Int32 || kind === TypeKind.Uint8 || kind === TypeKind.Uint16 || kind === TypeKind.Uint32) return "int32";
	if (kind === TypeKind.Int64 || kind === TypeKind.Uint64) return "int64";
	return "ptr";
}

// Pick the correct closure function pointer typedef based on return type.
function closureFnCastType(callType: Type): string {
	if (callType === null) return "msClosureFn";
	// callType is the overall call expression's type (= the closure's return type)
	const rt = callType;
	if (rt.kind === TypeKind.Void || rt.kind === TypeKind.Null) return "msClosureFn";
	if (rt.kind === TypeKind.Number || rt.kind === TypeKind.Float64) return "msClosureFnD";
	if (rt.kind === TypeKind.Boolean) return "msClosureFnB";
	if (rt.kind === TypeKind.String) return "msClosureFnS";
	if (rt.kind === TypeKind.Int8 || rt.kind === TypeKind.Int16 || rt.kind === TypeKind.Int32 || rt.kind === TypeKind.Uint8 || rt.kind === TypeKind.Uint16 || rt.kind === TypeKind.Uint32) return "msClosureFnI";
	if (rt.kind === TypeKind.Int64 || rt.kind === TypeKind.Uint64) return "msClosureFnI64";
	// Pointer types (class, ref, array, etc.) return void*
	return "msClosureFnP";
}


// ===== Tests =====
import { Token } from "../../lexer/token";
import { makeCtx } from "../testUtil";

function wrapProgram(stmts: Node[]): Node {
	return createNode(NodeKind.Program, { programStmts: stmts, programImports: [] }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
}

function makeClosureCall(calleeName: string, args: Node[]): { prog: Node, cd: CallExprData } {
	const loc: SourceLocation = { line: 1, column: 0 };
	const callee = makeIdent(calleeName, loc);
	const fnType = createFunction([numberType()], [], voidType());
	callee.nodeType = fnType;
	const callNode = makeCall(callee, args, loc);
	const cd = callNode.data as CallExprData;
	cd.isDirectCall = false;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, cd };
}

test "closure call is rewritten to direct call" {
	const t = makeClosureCall("cb", []);
	lowerClosureCalls(t.prog, makeCtx());
	// After lowering, the ExprStmt should contain a direct call
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	assert newCall.kind === NodeKind.CallExpr;
	const newCd = newCall.data as CallExprData;
	assert newCd.isDirectCall === true;
}

test "closure call has env prepended to args" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const arg1 = makeIdent("x", loc);
	const t = makeClosureCall("cb", [arg1]);
	lowerClosureCalls(t.prog, makeCtx());
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	const newCd = newCall.data as CallExprData;
	// Should have env + original arg = 2 args
	assert newCd.arguments.length === 2;
	// First arg is env (MemberExpr .env)
	assert newCd.arguments[0].kind === NodeKind.MemberExpr;
}

test "closure call callee is TypeAssertion with msClosureFn" {
	const t = makeClosureCall("cb", []);
	lowerClosureCalls(t.prog, makeCtx());
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	const newCd = newCall.data as CallExprData;
	// Callee should be TypeAssertion
	assert newCd.callee.kind === NodeKind.TypeAssertion;
	const ta = newCd.callee.data as TypeAssertionData;
	assert ta.asType === "msClosureFn";
	// Inner should be MemberExpr .fn
	assert ta.asExpr.kind === NodeKind.MemberExpr;
}

test "direct call is not rewritten" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const callee = makeIdent("directFn", loc);
	const callNode = makeCall(callee, [], loc);
	const cd = callNode.data as CallExprData;
	cd.isDirectCall = true;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	lowerClosureCalls(prog, makeCtx());
	// Should remain unchanged
	const newCd = ((prog.data as { programStmts: Node[] }).programStmts[0].data as { expr: Node }).expr.data as CallExprData;
	assert newCd.isDirectCall === true;
	assert newCd.callee.kind === NodeKind.Identifier;
}
