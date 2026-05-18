// Extension Method Lowering — rewrite obj.method(args) → method(obj, args)
//
// The checker resolves extension calls and sets NF_ExtCall / NF_ExtStatic flags
// on the CallExpr node, along with resolvedSym pointing to the winning extension.
// This transform only does the structural AST rewrite (MemberExpr → direct call).
// No registry re-lookup needed — follows reference pattern where sem resolves UFCS.

import { Node, NodeKind, NodeFlag, CallExprData, MemberExprData, ExprStmtData, SymbolKind, Symbol } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall } from "../util";
import { defineSymbol, makeSymbol } from "../../checker/symbol";
import { unknownType, createFunction } from "../../checker/types";
import { createContext, registerExtension, ExtensionMethod } from "../../checker/context";
import { parseInput, getStmts, firstCalleeKind, firstCallArgCount } from "../testUtil";
import { createTransformContext, createTransformContextWithChecker } from "../context";

// ===== Visitor =====

function lowerExtNode(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	// NF_ExtCall set by checker — no registry lookup needed
	if ((node.flags & NodeFlag.ExtCall) === 0) return node;

	const call = node.data as CallExprData;
	if (call.callee.kind !== NodeKind.MemberExpr) return node;

	const member = call.callee.data as MemberExprData;
	const loc = node.location;
	const sym = node.resolvedSym;
	// Use mangled name from resolved sym (e.g. Greeter_greet), fall back to property name
	const callName = (sym !== null && sym.name !== "") ? sym.name : member.property;

	// Static extension: Math.floor(x) → floor(x) — no receiver prepend
	if ((node.flags & NodeFlag.ExtStatic) !== 0) {
		const staticIdent = makeIdent(callName, loc);
		staticIdent.resolvedSym = sym;
		const newCall = makeCall(staticIdent, call.arguments, loc);
		newCall.nodeType = node.nodeType;
		return newCall;
	}

	// Instance extension: s.trim() → trim(s) — prepend receiver
	const newArgs: Node[] = [];
	newArgs.push(member.object);
	for (let ai = 0; ai < call.arguments.length; ai += 1) {
		newArgs.push(call.arguments[ai]);
	}
	const calleeIdent = makeIdent(callName, loc);
	calleeIdent.resolvedSym = sym;
	const newCall = makeCall(calleeIdent, newArgs, loc);
	newCall.nodeType = node.nodeType;
	return newCall;
}

// ===== Entry Point =====

export function lowerExtensionMethod(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerExtNode);
}

// ===== Test Helpers =====

// Tests simulate checker behavior by setting flags directly on CallExpr nodes.
function setupExtensionCtx(input: string, ext: ExtensionMethod): Node {
	const result = parseInput(input);
	if (!result.ok) return null as unknown as Node;
	const cc = createContext();
	registerExtension(cc.extensionRegistry, ext);
	const sym = makeSymbol(ext.methodName, SymbolKind.Function, ext.fnType, false);
	defineSymbol(cc.table, sym);
	// Simulate checker: set NF_ExtCall flag on the CallExpr
	const stmts = getStmts(result.value);
	if (stmts.length > 0) {
		const callNode = (stmts[0].data as ExprStmtData).expr;
		if (callNode !== null && callNode.kind === NodeKind.CallExpr) {
			callNode.flags = callNode.flags | NodeFlag.ExtCall;
			if (ext.isStatic) callNode.flags = callNode.flags | NodeFlag.ExtStatic;
			callNode.resolvedSym = sym;
		}
	}
	const ctx = createTransformContextWithChecker(cc);
	return lowerExtensionMethod(result.value, ctx);
}

// ===== Tests =====

function makeTrimExt(): ExtensionMethod {
	const ext: ExtensionMethod = {
		methodName: "trim",
		receiverTypeName: "string",
		sourcePath: "",
		fnType: createFunction([], [], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
	return ext;
}

function makePushExt(): ExtensionMethod {
	const ext: ExtensionMethod = {
		methodName: "push",
		receiverTypeName: "Array",
		sourcePath: "",
		fnType: createFunction([unknownType()], ["x"], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
	return ext;
}

test "extension call rewritten to direct call" {
	const prog = setupExtensionCtx("s.trim();", makeTrimExt());
	assert firstCalleeKind(prog) === NodeKind.Identifier;
}

test "non-extension call unchanged" {
	const result = parseInput("foo.bar();");
	if (!result.ok) return;
	const cc = createContext();
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerExtensionMethod(result.value, ctx);
	assert firstCalleeKind(prog) === NodeKind.MemberExpr;
}

test "no flag no rewrite" {
	const result = parseInput("s.trim();");
	if (!result.ok) return;
	const ctx = createTransformContext();
	const prog = lowerExtensionMethod(result.value, ctx);
	assert firstCalleeKind(prog) === NodeKind.MemberExpr;
}

test "extension with args prepends receiver" {
	const prog = setupExtensionCtx("a.push(1);", makePushExt());
	assert firstCallArgCount(prog) === 2;
}

test "extension no args gets receiver only" {
	const prog = setupExtensionCtx("s.trim();", makeTrimExt());
	assert firstCallArgCount(prog) === 1;
}

test "class member takes priority over extension" {
	// If checker didn't set NF_ExtCall, transform won't rewrite
	const result = parseInput("t.run();");
	if (!result.ok) return;
	const cc = createContext();
	const ctx = createTransformContextWithChecker(cc);
	// No NF_ExtCall flag → unchanged
	const prog = lowerExtensionMethod(result.value, ctx);
	assert firstCalleeKind(prog) === NodeKind.MemberExpr;
}

test "regular function call unchanged" {
	const prog = setupExtensionCtx("trim();", makeTrimExt());
	assert firstCalleeKind(prog) === NodeKind.Identifier;
}

test "non-matching method unchanged" {
	// No NF_ExtCall flag on s.length() → unchanged
	const result = parseInput("s.length();");
	if (!result.ok) return;
	const ctx = createTransformContext();
	const prog = lowerExtensionMethod(result.value, ctx);
	assert firstCalleeKind(prog) === NodeKind.MemberExpr;
}

test "static extension no receiver prepend" {
	const result = parseInput("Math.floor(3.7);");
	if (!result.ok) return;
	const cc = createContext();
	const ext: ExtensionMethod = {
		methodName: "floor",
		receiverTypeName: "Math",
		sourcePath: "",
		fnType: createFunction([unknownType()], ["x"], unknownType()),
		isStatic: true,
		sym: null as unknown as Symbol,
	};
	registerExtension(cc.extensionRegistry, ext);
	const fnSym = makeSymbol("floor", SymbolKind.Function, ext.fnType, false);
	defineSymbol(cc.table, fnSym);
	// Simulate checker: set NF_ExtCall + NF_ExtStatic
	const stmts = getStmts(result.value);
	const callNode = (stmts[0].data as ExprStmtData).expr;
	callNode.flags = callNode.flags | NodeFlag.ExtCall | NodeFlag.ExtStatic;
	callNode.resolvedSym = fnSym;
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerExtensionMethod(result.value, ctx);
	// Should rewrite to floor(3.7) — callee is Identifier, not MemberExpr
	assert firstCalleeKind(prog) === NodeKind.Identifier;
}
