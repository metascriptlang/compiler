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
	CallExprData, SourceLocation, NF_CLOSURE, createNodeAt,
} from "../../ast/node";
import { Type, TypeKind, CallingConvention, createFunction, voidType } from "../../checker/types";
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

	// MemberExpr callees: usually direct (method/extension), BUT env struct field
	// access (_envP.f) with Function type is a closure call (from lambda lifting).
	if (cd.callee.kind !== NodeKind.Identifier) {
		if (cd.callee.kind === NodeKind.MemberExpr && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
			cd.isDirectCall = false;
			cd.callee.nodeType.callConv = CallingConvention.CcClosure;
		}
		return node;
	}

	// Nim parity: generateThunk — wrap named functions passed as closure-typed args.
	// Must run before early returns — any call (direct or closure) can have function args.
	wrapFuncArgsAsThunks(cd);

	const sym = cd.callee.resolvedSym;

	// No resolvedSym → conservative: leave isDirectCall = true (default from parser).
	// Handles synthetic/runtime calls (ms* prefix etc.) that may lack symbols.
	if (sym === null) return node;

	// Extern-backed functions are always direct calls (never closures).
	// This catches cross-module extern functions whose symbolKind may not propagate.
	if (sym.nativeName !== "") return node;

	// Function/Method/Class symbols → direct call (default is already true)
	if (sym.symbolKind === SymbolKind.Function) return node;
	if (sym.symbolKind === SymbolKind.Method) return node;
	if (sym.symbolKind === SymbolKind.Class) return node;

	// Imported symbols → direct call (common for cross-module functions)
	if (sym.declNode !== null && sym.declNode.kind === NodeKind.ImportDecl) return node;

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

// Wrap function-reference arguments into closure thunks (Nim: generateThunk).
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
		thunk.flags = thunk.flags | NF_CLOSURE;
		// Set closure type from the function's own symbol type
		if (argSym.symbolType !== null) {
			thunk.nodeType = argSym.symbolType;
		}
		cd.arguments[i] = thunk;
	}
}

function getCalleeType(cd: CallExprData): Type {
	if (cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType;
	}
	if (cd.callee.resolvedSym !== null && cd.callee.resolvedSym.symbolType !== null) {
		return cd.callee.resolvedSym.symbolType;
	}
	return null as unknown as Type;
}

// ===== Tests =====
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
	expect(t.cd.isDirectCall === true);
}

test "Variable symbol is closure call" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === false);
}

test "Parameter symbol is closure call" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("handler", SymbolKind.Parameter, fnType, false);
	const t = makeTestCall("handler", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === false);
}

test "no resolvedSym stays direct (conservative)" {
	const t = makeTestCall("unknown", null as unknown as Symbol, null as unknown as Type);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === true);
}

test "MemberExpr callee is always direct" {
	const t = makeMemberTestCall();
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === true);
}

test "closure call sets CcClosure callConv" {
	const fnType = createFunction([numberType()], [], voidType());
	const sym = makeSymbol("cb", SymbolKind.Variable, fnType, false);
	const t = makeTestCall("cb", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === false);
	expect(t.cd.callee.nodeType !== null);
	expect(t.cd.callee.nodeType.callConv === CallingConvention.CcClosure);
}

test "Method symbol is direct call" {
	const fnType = createFunction([], [], voidType());
	const sym = makeSymbol("doStuff", SymbolKind.Method, fnType, false);
	const t = makeTestCall("doStuff", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === true);
}

test "Class symbol is direct call" {
	const sym = makeSymbol("Foo", SymbolKind.Class, null as unknown as Type, false);
	const t = makeTestCall("Foo", sym, null as unknown as Type);
	markClosureCalls(t.prog, makeCtx());
	expect(t.cd.isDirectCall === true);
}

test "imported function remains direct call" {
	// Simulate an imported symbol that fell back to Variable kind
	const fnType = createFunction([numberType()], ["code"], voidType());
	const sym = makeSymbol("exit", SymbolKind.Variable, fnType, false);
	const zl: SourceLocation = { line: 0, column: 0 };
	const data: ImportDeclData = { importNames: ["exit"], importAliases: ["exit"], importSource: "std/process" };
	sym.declNode = createNodeAt(NodeKind.ImportDecl, data, zl);
	
	const t = makeTestCall("exit", sym, fnType);
	markClosureCalls(t.prog, makeCtx());
	
	// Should NOT be marked as closure call
	expect(t.cd.isDirectCall === true);
}
