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

import {
	Node, NodeKind, SymbolKind, Symbol,
	CallExprData,
} from "../../ast/node";
import { Type, TypeKind, CallingConvention } from "../../checker/types";
import { Token } from "../../lexer/token";
import { TransformContext } from "../context";
import { walkNode } from "../walker";

// ===== Main Entry Point =====

export function markClosureCalls(program: Node, ctx: TransformContext): Node {
	walkNode(program, markCall);
	return program;
}

function markCall(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const cd = node.data as CallExprData;

	// Only Identifier callees can be closures.
	// MemberExpr callees are always direct (method/extension).
	if (cd.callee.kind !== NodeKind.Identifier) return node;

	const sym = cd.callee.resolvedSym;

	// No resolvedSym → conservative: leave isDirectCall = true (default from parser).
	// Handles synthetic/runtime calls (ms* prefix etc.) that may lack symbols.
	if (sym === null) return node;

	// Function/Method/Class symbols → direct call (default is already true)
	if (sym.symbolKind === SymbolKind.Function) return node;
	if (sym.symbolKind === SymbolKind.Method) return node;
	if (sym.symbolKind === SymbolKind.Class) return node;

	// Variable/Parameter with Function type → closure call
	if (sym.symbolKind === SymbolKind.Variable || sym.symbolKind === SymbolKind.Parameter) {
		cd.isDirectCall = false;
		// Nim parity: set callConv on callee type (ccClosure)
		if (cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
			cd.callee.nodeType.callConv = CallingConvention.CcClosure;
		}
	}

	return node;
}

// ===== Tests =====
import { check } from "std/testing";
import { Type, createFunction, numberType, voidType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { SourceLocation, createNode } from "../../ast/node";
import { makeIdent, makeCall, makeMember, makeBlock } from "../util";
import { makeCtx } from "../testUtil";

// Helper: wrap statements in a Program node for markClosureCalls
function wrapProgram(stmts: Node[]): Node {
	return createNode(NodeKind.Program, { programStmts: stmts, programImports: [] }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
}

// Helper: create an ExprStmt wrapping a CallExpr, return the CallExpr's data
function makeTestCall(calleeName: string, sym: Symbol, calleeType: Type): { prog: Node, cd: CallExprData } {
	const loc: SourceLocation = { line: 0, column: 0 };
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
	const loc: SourceLocation = { line: 0, column: 0 };
	const obj = makeIdent("obj", loc);
	const mem = makeMember(obj, "method", loc);
	const callNode = makeCall(mem, [], loc);
	const cd = callNode.data as CallExprData;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, cd };
}

test "Function symbol is direct call" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("foo", SymbolKind.Function, fnType, false);
	const t = makeTestCall("foo", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === true);
}

test "Variable symbol is closure call" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === false);
}

test "Parameter symbol is closure call" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("handler", SymbolKind.Parameter, fnType, false);
	const t = makeTestCall("handler", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === false);
}

test "no resolvedSym stays direct (conservative)" {
	const t = makeTestCall("unknown", null as unknown as Symbol, null as unknown as Type);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === true);
}

test "MemberExpr callee is always direct" {
	const t = makeMemberTestCall();
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === true);
}

test "closure call sets CcClosure callConv" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === false);
	check(t.cd.callee.nodeType !== null);
	check(t.cd.callee.nodeType.callConv === CallingConvention.CcClosure);
}

test "Method symbol is direct call" {
	const fnType = createFunction([], [], voidType());
	const sym = makeSymbol("doStuff", SymbolKind.Method, fnType, false);
	const t = makeTestCall("doStuff", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === true);
}

test "Class symbol is direct call" {
	const sym = makeSymbol("Foo", SymbolKind.Class, null as unknown as Type, false);
	const t = makeTestCall("Foo", sym, null as unknown as Type);
	markClosureCalls(t.prog, makeCtx());
	check(t.cd.isDirectCall === true);
}
