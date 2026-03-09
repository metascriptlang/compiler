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
// codegen/c/jsonEmit.ms for clean separation of concerns.

import {
	Node, NodeKind, NodeFlag, DeclKind, ProgramData, SourceLocation,
	CallExprData, MemberExprData, IdentifierData,
} from "../../ast/node";
import { Type, TypeKind, isNumeric, createResult, createArray, createPrimitive, stringType, booleanType, numberType, unknownType, unwrapRef } from "../../checker/types";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall,
	makeObjectLiteral, makeBool, makeHiddenStdConv,
	makeExprStmt,
} from "../util";
import { findCallTypeArg } from "../../parser/context";
import { generateJsonParseC, generateJsonStringifyC } from "../../codegen/c/jsonEmit";
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
// AST rewriting only — C code generation delegated to codegen/c/jsonEmit.ms

// Resolve the struct type for the explicit type arg (e.g., "Person" → struct type with fields).
function resolveJsonTargetType(typeArgStr: string, ctx: TransformContext): Type {
	if (ctx.checkerCtx === null) return null as unknown as Type;
	const sym = lookupSymbol(ctx.checkerCtx.table, typeArgStr);
	if (sym === null) return null as unknown as Type;
	if (sym.symbolType === null) return null as unknown as Type;
	const unwrapped = unwrapRef(sym.symbolType);
	if (unwrapped.kind === TypeKind.Struct) return unwrapped;
	return null as unknown as Type;
}

// Dedup check — prevents generating the same helper twice.
// Uses ctx.emittedHelpers (per-compilation) instead of module-level state.
function hasEmitted(ctx: TransformContext, name: string): boolean {
	let i = 0;
	while (i < ctx.emittedHelpers.length) {
		if (ctx.emittedHelpers[i] === name) return true;
		i = i + 1;
	}
	return false;
}

function rewriteJsonParse(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	const typeArgStr = findCallTypeArg(node);
	if (typeArgStr === "") return node;

	const structType = resolveJsonTargetType(typeArgStr, ctx);
	if (structType === null) return node;

	const helperName = "__jsonParse_" + typeArgStr;
	const resultType = createResult(structType, stringType());

	if (!hasEmitted(ctx, helperName)) {
		const emitNode = generateJsonParseC(helperName, typeArgStr, structType, loc);
		if (emitNode === null) return node;
		ctx.emittedHelpers.push(helperName);
		ctx.pendingDecls.push(emitNode);
	}

	const newCallee = makeIdent(helperName, loc);
	const result = makeCall(newCallee, cd.arguments, loc);
	result.nodeType = resultType;
	return result;
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

	const structType = resolveJsonTargetType(typeArgStr, ctx);
	if (structType === null) return node;

	const helperName = "__jsonStringify_" + typeArgStr;

	if (!hasEmitted(ctx, helperName)) {
		const emitNode = generateJsonStringifyC(helperName, typeArgStr, structType, loc);
		if (emitNode === null) return node;
		ctx.emittedHelpers.push(helperName);
		ctx.pendingDecls.push(emitNode);
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
