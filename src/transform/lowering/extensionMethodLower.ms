// Extension Method Lowering — rewrite obj.method(args) → method(obj, args)
//
// Extension methods (declared as `function f(this self: Type)`) are registered
// in the ExtensionRegistry by the checker but the AST is NOT rewritten.
// C codegen needs UFCS form: direct function call with receiver as first arg.
// Reference compiler: normalize.zig Pass 7.
//
// Detection: checks ExtensionRegistry for method name, uses symbol table to
// avoid false positives on regular class/interface member calls.

import { Node, NodeKind, CallExprData, MemberExprData, ExprStmtData, ProgramData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall } from "../util";
import { lookupSymbol, SymbolKind, defineSymbol, makeSymbol, Symbol } from "../../checker/symbol";
import { TypeKind, Type, getProperty, typeNameOf, unknownType, createStruct, createFunction } from "../../checker/types";
import { ExtensionRegistry, hasExtensionByName, findExtension, createContext, registerExtension, ExtensionMethod } from "../../checker/context";
import { parseInput, getStmts, firstCalleeKind, firstCallArgCount } from "../testUtil";
import { createTransformContext, createTransformContextWithChecker } from "../context";

// ===== Helpers =====

// Check if receiver's resolved type has a property with this name.
// If so, it's a regular member call (class/interface method), not an extension.
function receiverHasProperty(ctx: TransformContext, obj: Node, name: string): boolean {
	if (ctx.checkerCtx === null) return false;
	const objType = obj.nodeType;
	if (objType === null) return false;
	const prop = getProperty(objType, name);
	return prop.kind !== TypeKind.Unknown;
}

// Get the type name of a receiver node for extension lookup
function getReceiverTypeName(ctx: TransformContext, obj: Node): string {
	if (ctx.checkerCtx === null) return "";
	const objType = obj.nodeType;
	if (objType === null) return "";
	return typeNameOf(objType);
}

// Resolve the best symbol for a rewritten callee identifier
function resolveCalleeSym(ext: ExtensionMethod, calleeSym: Symbol, ctx: TransformContext, methodName: string): Symbol {
	if (ext !== null && ext.sym !== null) return ext.sym;
	if (calleeSym !== null) return calleeSym;
	return lookupSymbol(ctx.checkerCtx.table, methodName);
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
	// Checker may have resolved this as a class method (ClassName_methodName)
	const calleeSym = call.callee.resolvedSym;

	if (!hasExtensionByName(ctx.checkerCtx.extensionRegistry, methodName)) {
		// Not by short name — check if calleeSym indicates a class method (mangled name in registry)
		if (calleeSym === null) return node;
		if (!hasExtensionByName(ctx.checkerCtx.extensionRegistry, calleeSym.name)) return node;
	}

	// If receiver has a property with this name, it's a regular member call
	if (receiverHasProperty(ctx, member.object, methodName)) return node;

	// Look up the specific extension to determine instance vs static.
	// For array methods, the registry uses raw type annotations ("number[]", "string[]", "T[]")
	// but typeNameOf returns "Array" for all. Resolve by element type matching.
	const receiverType = getReceiverTypeName(ctx, member.object);
	// Class methods registered with mangled name (ClassName_methodName), standalone extensions with short name
	const mangledMethodName = receiverType + "_" + methodName;
	let ext = findExtension(ctx.checkerCtx.extensionRegistry, receiverType, mangledMethodName);
	if (ext === null) ext = findExtension(ctx.checkerCtx.extensionRegistry, receiverType, methodName);
	const objType = member.object.nodeType;
	if (ext === null && objType !== null && objType.kind === TypeKind.Array) {
		// Array type: try raw type annotations ("number[]", "string[]", generic "T[]")
		const elemKind = (objType.typeReturn !== null) ? objType.typeReturn.kind : TypeKind.Unknown;
		if (elemKind === TypeKind.Number) {
			ext = findExtension(ctx.checkerCtx.extensionRegistry, "number[]", methodName);
			if (ext === null) ext = findExtension(ctx.checkerCtx.extensionRegistry, "number[ ]", methodName);
		} else if (elemKind === TypeKind.String) {
			ext = findExtension(ctx.checkerCtx.extensionRegistry, "string[]", methodName);
			if (ext === null) ext = findExtension(ctx.checkerCtx.extensionRegistry, "string[ ]", methodName);
		} else {
			// Non-number, non-string arrays → use generic overload ("T[]" or "T[ ]")
			ext = findExtension(ctx.checkerCtx.extensionRegistry, "T[]", methodName);
			if (ext === null) ext = findExtension(ctx.checkerCtx.extensionRegistry, "T[ ]", methodName);
		}
	}

	const loc = node.location;
	// Static extension: Math.floor(x) → floor(x) — no receiver prepend
	if (ext !== null && ext.isStatic) {
		const staticName = (ext.sym !== null) ? ext.sym.name : methodName;
		const staticIdent = makeIdent(staticName, loc);
		staticIdent.resolvedSym = resolveCalleeSym(ext, calleeSym, ctx, methodName);
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
	// Use mangled name from extension sym (e.g. Greeter_greet) when available
	const callName = (ext !== null && ext.sym !== null) ? ext.sym.name : methodName;
	const calleeIdent = makeIdent(callName, loc);
	calleeIdent.resolvedSym = resolveCalleeSym(ext, calleeSym, ctx, methodName);
	const newCall = makeCall(calleeIdent, newArgs, loc);
	newCall.nodeType = node.nodeType;
	return newCall;
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

test "no checker context no rewrite" {
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
	const result = parseInput("t.run();");
	if (!result.ok) return;
	const cc = createContext();
	const ext: ExtensionMethod = {
		methodName: "run",
		receiverTypeName: "string",
		sourcePath: "",
		fnType: createFunction([], [], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
	registerExtension(cc.extensionRegistry, ext);
	const fnSym = makeSymbol("run", SymbolKind.Function, ext.fnType, false);
	defineSymbol(cc.table, fnSym);
	const taskType = createStruct("Task", ["run"], [createFunction([], [], unknownType())], false);
	const tSym = makeSymbol("t", SymbolKind.Variable, taskType, false);
	defineSymbol(cc.table, tSym);
	// Set nodeType on receiver so receiverHasProperty can find the struct field
	const stmts = getStmts(result.value);
	const callNode = (stmts[0].data as ExprStmtData).expr;
	const callData = callNode.data as CallExprData;
	const memberData = callData.callee.data as MemberExprData;
	memberData.object.nodeType = taskType;
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerExtensionMethod(result.value, ctx);
	assert firstCalleeKind(prog) === NodeKind.MemberExpr;
}

test "regular function call unchanged" {
	const prog = setupExtensionCtx("trim();", makeTrimExt());
	assert firstCalleeKind(prog) === NodeKind.Identifier;
}

test "non-matching method unchanged" {
	const prog = setupExtensionCtx("s.length();", makeTrimExt());
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
	// Math is an identifier with Object type "Math"
	const mathType = createStruct("Math", [], [], false);
	const mathSym = makeSymbol("Math", SymbolKind.Variable, mathType, false);
	defineSymbol(cc.table, mathSym);
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerExtensionMethod(result.value, ctx);
	// Should rewrite to floor(3.7) — callee is Identifier, not MemberExpr
	assert firstCalleeKind(prog) === NodeKind.Identifier;
}
