// Closure Call Marker — identifies CallExpr nodes where callee is a closure
// Uses resolvedSym metadata from the checker to decisively distinguish
// direct function calls from closure calls (variable/parameter with function type).
//
// In C, closure calls use a different calling convention (ms_closure.fn + env pointer)
// vs direct function calls. This pass sets isDirectCall = false on closure CallExprs.
//
// Decision logic:
//   MemberExpr callee       → always direct (method/extension)
//   Identifier, no symbol   → direct (conservative — handles runtime/synthetic calls)
//   Identifier, Function    → direct
//   Identifier, Method      → direct
//   Identifier, Class       → direct (constructor)
//   Identifier, Variable    → closure
//   Identifier, Parameter   → closure

import { Node, NodeKind, SymbolKind, Symbol, CallExprData, MemberExprData, makeLoc, NodeFlag, Type, TypeKind, CallingConvention } from "../../ast/node";
import { createFunction, voidType } from "../../checker/types";
import { Token } from "../../lexer/token";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeObjectLiteral, makeNull } from "../util";

// ===== Main Entry Point =====

export function markClosureCalls(program: Node, ctx: TransformContext): Node {
	walkNode(program, markCall);
	return program;
}

function markCall(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const cd = node.data as CallExprData;

	// Post-lambda-lifting MemberExpr callees: _envP.f with Function type is a closure call.
	// These are created by lambda lifting (runs after checker), so the checker can't see them.
	// Reference parity: lambda-lifted calls get closure calling convention from the lifted function's proc type.
	// Exception: Module namespace access (ns.func) is always a direct call.
	if (cd.callee.kind === NodeKind.MemberExpr && cd.callee.nodeType !== null
		&& cd.callee.nodeType.kind === TypeKind.Function) {
		const calleeObj = (cd.callee.data as MemberExprData).object;
		const isModuleAccess = calleeObj.resolvedSym !== null && calleeObj.resolvedSym.symbolKind === SymbolKind.Module;
		if (!isModuleAccess) {
			cd.isDirectCall = false;
			cd.callee.nodeType.callConv = CallingConvention.CcClosure;
		}
	}

	// ArrayAccess callee with Function nodeType: `arr[i](args)` where the
	// element type is a function/closure. Same closure-call dispatch as the
	// MemberExpr branch above — Nim parity is "dispatch by callee TYPE, not
	// syntactic shape". Without this, codegen emits the raw `expr(args)`
	// form which lowers to `msArrayAccess(arr, i)(args)` — calling an
	// `msClosure` struct directly, which C rejects with "called object type
	// 'msClosure' is not a function or function pointer".
	if (cd.callee.kind === NodeKind.ArrayAccess && cd.callee.nodeType !== null
		&& cd.callee.nodeType.kind === TypeKind.Function) {
		cd.isDirectCall = false;
		cd.callee.nodeType.callConv = CallingConvention.CcClosure;
	}

	// Reference parity: thunk generation — wrap named functions passed as
	// closure-typed args into {fn, env:null} thunks. Runs in transform, not checker.
	wrapFuncArgsAsThunks(cd);

	return node;
}

// Wrap function-reference arguments into closure thunks (standard pattern).
// Scans CallExpr arguments: if arg is an Identifier → SymbolKind.Function
// and the callee's corresponding parameter expects a Function/closure type,
// wrap it in ObjectLiteral { fn, env } with closure nodeType.
function wrapFuncArgsAsThunks(cd: CallExprData): void {
	// Need callee's function type to know parameter types
	const calleeType = getCalleeType(cd);
	if (calleeType === null) return;
	if (calleeType.kind !== TypeKind.Function) return;
	if (calleeType.typeChildren === null) return;

	for (let i = 0; i < cd.arguments.length; i += 1) {
		const arg = cd.arguments[i];
		if (arg.kind !== NodeKind.Identifier) continue;
		const argSym = arg.resolvedSym;
		if (argSym === null) continue;
		// Only wrap named functions (not variables/parameters which are already closures)
		if (argSym.symbolKind !== SymbolKind.Function) continue;
		// In MetaScript, all function-typed parameters are closures (msClosure in C).
		// A named function passed as argument always needs wrapping into { fn, env: null }.
		const loc = arg.location;
		const nullNode = makeNull(loc);
		const thunk = makeObjectLiteral(["fn", "env"], [arg, nullNode], loc);
		thunk.flags = thunk.flags | NodeFlag.Closure;
		// Set closure type from the function's own symbol type
		if (argSym.symbolType !== null) {
			thunk.nodeType = argSym.symbolType;
		}
		cd.arguments[i] = thunk;
	}
}

function getCalleeType(cd: CallExprData): Type | null {
	if (cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType;
	}
	if (cd.callee.resolvedSym !== null && cd.callee.resolvedSym.symbolType !== null) {
		return cd.callee.resolvedSym.symbolType;
	}
	return null;
}

// ===== Tests =====
import { createFunction, numberType, voidType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { createNode } from "../../ast/node";
import { makeIdent, makeCall, makeMember } from "../util";
import { makeCtx } from "../testUtil";

// Helper: wrap statements in a Program node for markClosureCalls
function wrapProgram(stmts: Node[]): Node {
	return createNode(NodeKind.Program, { programStmts: stmts }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
}

// Helper: create an ExprStmt wrapping a CallExpr, return the CallExpr's data
function makeTestCall(calleeName: string, sym: Symbol, calleeType: Type): { prog: Node, cd: CallExprData } {
	const loc = makeLoc(0, 0);
	const callee = makeIdent(calleeName, loc);
	if (sym !== null) {
		callee.resolvedSym = sym;
	}
	if (calleeType !== null) {
		callee.nodeType = calleeType;
	}
	const callNode = makeCall(callee, [], loc);
	const cd = callNode.data as CallExprData;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, cd };
}

// Helper: create a MemberExpr-based call (obj.method())
function makeMemberTestCall(): { prog: Node, cd: CallExprData } {
	const loc = makeLoc(0, 0);
	const obj = makeIdent("obj", loc);
	const mem = makeMember(obj, "method", loc);
	const callNode = makeCall(mem, [], loc);
	const cd = callNode.data as CallExprData;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, cd };
}

// Reference parity: Identifier-based closure detection moved to checker (checkCallExpr).
// closureCallMarker now only handles post-lambda-lifting MemberExpr callees
// and thunk wrapping (generateThunk equivalent).

test "MemberExpr with Function type is closure call" {
	// Simulates _envP.f from lambda lifting — MemberExpr callee with Function type
	const loc = makeLoc(0, 0);
	const obj = makeIdent("_envP", loc);
	const mem = makeMember(obj, "handler", loc);
	const fnType = createFunction([numberType()], [], voidType());
	mem.nodeType = fnType;
	const callNode = makeCall(mem, [], loc);
	const cd = callNode.data as CallExprData;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	markClosureCalls(prog, makeCtx());
	assert cd.isDirectCall === false;
	assert cd.callee.nodeType.callConv === CallingConvention.CcClosure;
}

test "MemberExpr without Function type stays direct" {
	const t = makeMemberTestCall();
	markClosureCalls(t.prog, makeCtx());
	assert t.cd.isDirectCall === true;
}

test "Identifier callee not touched by marker" {
	// Identifier-based closure detection is now in the checker, not the marker
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	// Marker does NOT set isDirectCall — checker does that based on callConv
	assert t.cd.isDirectCall === true;
}
