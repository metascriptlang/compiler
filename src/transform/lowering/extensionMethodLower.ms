// Extension Method Lowering — rewrite obj.method(args) → method(obj, args)
//
// Extension methods (declared as `function f(this self: Type)`) are registered
// in the ExtensionRegistry by the checker but the AST is NOT rewritten.
// C codegen needs UFCS form: direct function call with receiver as first arg.
// Reference compiler: normalize.zig Pass 7.
//
// Detection: checks ExtensionRegistry for method name, uses symbol table to
// avoid false positives on regular class/interface member calls.

import { Node, NodeKind, CallExprData, MemberExprData, IdentifierData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall } from "../util";
import { lookupSymbol } from "../../checker/symbol";
import { TypeKind, getProperty } from "../../checker/types";
import { ExtensionRegistry } from "../../checker/context";
import { test, check, testGroup } from "std/testing";
import { parseInput, getStmts, firstCalleeKind, firstCallArgCount } from "../testUtil";
import { createTransformContext, createTransformContextWithChecker } from "../context";
import { createContext, registerExtension, ExtensionMethod } from "../../checker/context";
import { defineSymbol, makeSymbol, SymbolKind } from "../../checker/symbol";
import { unknownType, createObject, createFunction } from "../../checker/types";

// ===== Helpers =====

// Check if ANY extension in the registry has this method name.
function isExtensionName(registry: ExtensionRegistry, name: string): boolean {
	let mi = 0;
	while (mi < registry.methods.length) {
		if (registry.methods[mi].methodName === name) return true;
		mi += 1;
	}
	return false;
}

// Check if receiver's resolved type has a property with this name.
// If so, it's a regular member call (class/interface method), not an extension.
function receiverHasProperty(ctx: TransformContext, obj: Node, name: string): boolean {
	if (ctx.checkerCtx === null) return false;
	if (obj.kind !== NodeKind.Identifier) return false;
	const d = obj.data as IdentifierData;
	const sym = lookupSymbol(ctx.checkerCtx.table, d.name);
	if (sym === null) return false;
	const prop = getProperty(sym.symbolType, name);
	return prop.kind !== TypeKind.Unknown;
}

// ===== Visitor =====

function lowerExtNode(node: Node, ctx: TransformContext): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const call = node.data as CallExprData;
	if (call.callee.kind !== NodeKind.MemberExpr) return node;

	const member = call.callee.data as MemberExprData;
	// Skip optional chaining: obj?.method() should not be rewritten
	if (member.isOptional) return node;

	if (ctx.checkerCtx === null) return node;
	if (ctx.checkerCtx.extensionRegistry === null) return node;

	const methodName = member.property;
	if (!isExtensionName(ctx.checkerCtx.extensionRegistry, methodName)) return node;

	// If receiver has a property with this name, it's a regular member call
	if (receiverHasProperty(ctx, member.object, methodName)) return node;

	// Rewrite: obj.method(a, b) → method(obj, a, b)
	const loc = node.location;
	const newArgs: Node[] = [];
	newArgs.push(member.object);
	let ai = 0;
	while (ai < call.arguments.length) {
		newArgs.push(call.arguments[ai]);
		ai += 1;
	}
	return makeCall(makeIdent(methodName, loc), newArgs, loc);
}

// ===== Entry Point =====

export function lowerExtensionMethod(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerExtNode(node, ctx);
	});
}

// ===== Test Helpers =====

function setupExtensionCtx(input: string, ext: ExtensionMethod): Node {
	const result = parseInput(input);
	if (!result.ok) return null as unknown as Node;
	const cc = createContext();
	registerExtension(cc.extensionRegistry, ext);
	const sym = makeSymbol(ext.methodName, SymbolKind.Function, ext.fnType, false);
	defineSymbol(cc.table, sym);
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
	};
	return ext;
}

function makePushExt(): ExtensionMethod {
	const ext: ExtensionMethod = {
		methodName: "push",
		receiverTypeName: "Array",
		sourcePath: "",
		fnType: createFunction([unknownType()], ["x"], unknownType()),
	};
	return ext;
}

testGroup("Extension Method Lowering", () => {
	test("extension call rewritten to direct call", () => {
		const prog = setupExtensionCtx("s.trim();", makeTrimExt());
		check(firstCalleeKind(prog) === NodeKind.Identifier);
	});
	test("non-extension call unchanged", () => {
		const result = parseInput("foo.bar();");
		if (!result.ok) return;
		const cc = createContext();
		const ctx = createTransformContextWithChecker(cc);
		const prog = lowerExtensionMethod(result.value, ctx);
		check(firstCalleeKind(prog) === NodeKind.MemberExpr);
	});
	test("no checker context no rewrite", () => {
		const result = parseInput("s.trim();");
		if (!result.ok) return;
		const ctx = createTransformContext();
		const prog = lowerExtensionMethod(result.value, ctx);
		check(firstCalleeKind(prog) === NodeKind.MemberExpr);
	});
	test("extension with args prepends receiver", () => {
		const prog = setupExtensionCtx("a.push(1);", makePushExt());
		check(firstCallArgCount(prog) === 2);
	});
	test("extension no args gets receiver only", () => {
		const prog = setupExtensionCtx("s.trim();", makeTrimExt());
		check(firstCallArgCount(prog) === 1);
	});
	test("class member takes priority over extension", () => {
		const result = parseInput("t.run();");
		if (!result.ok) return;
		const cc = createContext();
		const ext: ExtensionMethod = {
			methodName: "run",
			receiverTypeName: "string",
			sourcePath: "",
			fnType: createFunction([], [], unknownType()),
		};
		registerExtension(cc.extensionRegistry, ext);
		const fnSym = makeSymbol("run", SymbolKind.Function, ext.fnType, false);
		defineSymbol(cc.table, fnSym);
		const taskType = createObject("Task", ["run"], [createFunction([], [], unknownType())], false);
		const tSym = makeSymbol("t", SymbolKind.Variable, taskType, false);
		defineSymbol(cc.table, tSym);
		const ctx = createTransformContextWithChecker(cc);
		const prog = lowerExtensionMethod(result.value, ctx);
		check(firstCalleeKind(prog) === NodeKind.MemberExpr);
	});
	test("regular function call unchanged", () => {
		const prog = setupExtensionCtx("trim();", makeTrimExt());
		check(firstCalleeKind(prog) === NodeKind.Identifier);
	});
	test("non-matching method unchanged", () => {
		const prog = setupExtensionCtx("s.length();", makeTrimExt());
		check(firstCalleeKind(prog) === NodeKind.MemberExpr);
	});
});
