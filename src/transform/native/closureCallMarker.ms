// Closure Call Marker — selects the calling convention for every CallExpr.
//
// In C, closure calls use a different calling convention (ms_closure.fn + env
// pointer) vs direct function calls. This pass sets isDirectCall = false on
// closure CallExprs.
//
// Reference parity (genAsgnCall): the callee's callConv decides, and nothing
// else does. Gating on node kind instead leaves the callees that lowering
// introduces — `f(x)(y)` becomes a `$tmp`, `(c ? f : g)(y)` a `$tern` — emitting
// a raw `expr(args)` on an msClosure struct, which C rejects.
//
// The reference skips {tyGenericInst, tyAlias, tySink, tyOwned} before reading
// callConv. Here that set is empty by construction: aliases and generic
// instances are resolved before this pass (and substitution copies callConv),
// and Sink/Lent are never built for a callee — probed, not assumed.

import { Node, NodeKind, SymbolKind, Symbol, CallExprData, makeLoc, NodeFlag, Type, TypeKind, CallingConvention } from "../../ast/node";
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

	// Reference parity (genAsgnCall): dispatch on the callee's callConv, never on
	// its node kind. Gating on kind leaves callees that later lowering introduced
	// (`f(x)(y)`, `(c ? f : g)(y)` both become a temp) emitting a raw `expr(args)`
	// on an msClosure struct, which C rejects with "called object type 'msClosure'
	// is not a function or function pointer".
	if (isClosureTypedCallee(cd.callee)) {
		cd.isDirectCall = false;
	}

	// Reference parity: thunk generation — wrap named functions passed as
	// closure-typed args into {fn, env:null} thunks. Runs in transform, not checker.
	wrapFuncArgsAsThunks(node);

	return node;
}

// Wrap function-reference arguments into closure thunks (standard pattern).
// Scans CallExpr arguments: if arg is an Identifier → SymbolKind.Function
// and the callee's corresponding parameter expects a Function/closure type,
// wrap it in ObjectLiteral { fn, env } with closure nodeType.
function wrapFuncArgsAsThunks(node: Node): void {
	const cd = node.data as CallExprData;
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

function isClosureTypedCallee(callee: Node): boolean {
	if (callee.nodeType === null) return false;
	if (callee.nodeType.kind !== TypeKind.Function) return false;
	return callee.nodeType.callConv === CallingConvention.CcClosure;
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
import { createFunction, createClosureType, numberType, voidType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { createNode } from "../../ast/node";
import { makeIdent, makeCall, makeMember } from "../util";
import { makeCtx } from "../testUtil";

// Helper: wrap statements in a Program node for markClosureCalls
function wrapProgram(stmts: Node[]): Node {
	return createNode(NodeKind.Program, { programStmts: stmts }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
}

// Helper: create an ExprStmt wrapping a CallExpr, return the CallExpr's data
// Returns the call NODE, never its `data`: a CallExprData carried out through a
// struct field is a copy, so a test reading it would observe the pre-walk value
// and pass no matter what the pass does.
function makeTestCall(calleeName: string, sym: Symbol, calleeType: Type): { prog: Node, call: Node } {
	const loc = makeLoc(0, 0);
	const callee = makeIdent(calleeName, loc);
	if (sym !== null) {
		callee.resolvedSym = sym;
	}
	if (calleeType !== null) {
		callee.nodeType = calleeType;
	}
	const callNode = makeCall(callee, [], loc);
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, call: callNode };
}

function isDirect(call: Node): boolean {
	return (call.data as CallExprData).isDirectCall;
}

// Helper: create a MemberExpr-based call (obj.method())
function makeMemberTestCall(): { prog: Node, call: Node } {
	const loc = makeLoc(0, 0);
	const obj = makeIdent("obj", loc);
	const mem = makeMember(obj, "method", loc);
	const callNode = makeCall(mem, [], loc);
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, call: callNode };
}

// The marker is the single site that fixes the calling convention: it runs last,
// on the fully lowered tree, so it also sees the callees that earlier lowering
// introduced (temps standing in for a call/ternary result).

test "MemberExpr holding a closure is a closure call" {
	// Simulates _envP.f from lambda lifting — a captured closure read back out
	// of the environment struct.
	const loc = makeLoc(0, 0);
	const obj = makeIdent("_envP", loc);
	const mem = makeMember(obj, "handler", loc);
	mem.nodeType = createClosureType([numberType()], [], voidType());
	const callNode = makeCall(mem, [], loc);
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	markClosureCalls(prog, makeCtx());
	assert isDirect(callNode) === false;
}

test "MemberExpr without Function type stays direct" {
	const t = makeMemberTestCall();
	markClosureCalls(t.prog, makeCtx());
	assert isDirect(t.call) === true;
}

test "Closure-typed variable callee is a closure call" {
	const fnType = createClosureType([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	assert isDirect(t.call) === false;
}

test "Named function callee stays direct" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("helper", SymbolKind.Function, fnType, false);
	const t = makeTestCall("helper", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	assert isDirect(t.call) === true;
}

test "Synthesized callee without a symbol stays direct" {
	// Per-type DRC hooks are emitted as plain calls with no symbol attached;
	// treating "no symbol" as a closure emits `hook.env` on a function pointer.
	const loc = makeLoc(0, 0);
	const callee = makeIdent("HashMapEntry_copy", loc);
	callee.nodeType = createFunction([numberType()], [], voidType());
	const callNode = makeCall(callee, [], loc);
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	markClosureCalls(wrapProgram([exprStmt]), makeCtx());
	assert isDirect(callNode) === true;
}

test "Closure symbol without a node type stays direct" {
	// The node's own type is the single source of truth (reference reads only
	// ri[0].typ); a checker that stops stamping nodeType must surface as a C
	// compile error at the call, not be silently repaired from the symbol.
	const fnType = createClosureType([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, null as unknown as Type);
	markClosureCalls(t.prog, makeCtx());
	assert isDirect(t.call) === true;
}

test "Callee produced by another call is a closure call" {
	// `make(1)(2)` — the callee names nothing and carries no symbol, so only its
	// type can classify it.
	const loc = makeLoc(0, 0);
	const inner = makeCall(makeIdent("make", loc), [], loc);
	inner.nodeType = createClosureType([numberType()], [], voidType());
	const outer = makeCall(inner, [], loc);
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: outer }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	markClosureCalls(wrapProgram([exprStmt]), makeCtx());
	assert isDirect(outer) === false;
}
