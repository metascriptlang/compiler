// Subscript Lowering — rewrite custom obj[idx] → `[]`(obj, idx)
//
// Subscript operators (declared as `function `[]`(this self: Type, idx: number)`)
// are registered in the ExtensionRegistry by the checker but the AST is NOT rewritten.
// C codegen needs direct function call form.
// Reference compiler: subscript_lower.zig.
//
// Detection: checks ExtensionRegistry for "[]"/"[]=" operators on receiver type.
// Builtin indexable types (Array, string, Map) are never rewritten.

import { Node, NodeKind, ArrayAccessData, BinaryExprData, IdentifierData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall } from "../util";
import { Symbol, lookupSymbol, SymbolKind, defineSymbol, makeSymbol } from "../../checker/symbol";
import { TypeKind, unknownType, createStruct, createFunction, createArray, typeNameOf } from "../../checker/types";
import { ExtensionRegistry, ExtensionMethod, createContext, registerExtension, findExtension } from "../../checker/context";
import { createTransformContext, createTransformContextWithChecker } from "../context";
import { parseInput, getStmts, firstExprKind, firstCallArgCount } from "../testUtil";

// ===== Helpers =====

// Get the type name of a node via symbol table lookup.
function getTypeName(ctx: TransformContext, node: Node): string {
	if (ctx.checkerCtx === null) return "";
	if (node.kind !== NodeKind.Identifier) return "";
	const d = node.data as IdentifierData;
	const sym = lookupSymbol(ctx.checkerCtx.table, d.name);
	if (sym === null) return "";
	return typeNameOf(sym.symbolType);
}

// Builtin types that use native [] — never rewrite these.
function isBuiltinIndexable(typeName: string): boolean {
	return match (typeName) {
		"Array" | "string" | "Map" => true,
		_ => false,
	};
}

// ===== Visitor =====

function lowerSubscriptNode(node: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx === null) return node;
	if (ctx.checkerCtx.extensionRegistry === null) return node;
	const registry = ctx.checkerCtx.extensionRegistry;

	// Case 1: Getter — obj[idx] → `[]`(obj, idx)
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const typeName = getTypeName(ctx, d.array);
		if (typeName === "") return node;
		if (isBuiltinIndexable(typeName)) return node;
		if (findExtension(registry, typeName, "[]") === null) return node;
		const loc = node.location;
		const args: Node[] = [];
		args.push(d.array);
		args.push(d.index);
		return makeCall(makeIdent("[]", loc), args, loc);
	}

	// Case 2: Setter — obj[idx] = value → `[]=`(obj, idx, value)
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator !== "=") return node;
		if (d.left.kind !== NodeKind.ArrayAccess) return node;
		const ad = d.left.data as ArrayAccessData;
		const typeName = getTypeName(ctx, ad.array);
		if (typeName === "") return node;
		if (isBuiltinIndexable(typeName)) return node;
		if (findExtension(registry, typeName, "[]=") === null) return node;
		const loc = node.location;
		const args: Node[] = [];
		args.push(ad.array);
		args.push(ad.index);
		args.push(d.right);
		return makeCall(makeIdent("[]=", loc), args, loc);
	}

	return node;
}

// ===== Entry Point =====

export function lowerSubscript(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerSubscriptNode(node, ctx);
	});
}

// ===== Test Helpers =====

function makeGetterExt(receiverType: string): ExtensionMethod {
	const ext: ExtensionMethod = {
		methodName: "[]",
		receiverTypeName: receiverType,
		sourcePath: "",
		fnType: createFunction([unknownType()], ["index"], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
	return ext;
}

function makeSetterExt(receiverType: string): ExtensionMethod {
	const ext: ExtensionMethod = {
		methodName: "[]=",
		receiverTypeName: receiverType,
		sourcePath: "",
		fnType: createFunction([unknownType(), unknownType()], ["index", "value"], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
	return ext;
}

function setupSubscriptCtx(input: string, receiverName: string, receiverType: string, exts: string): Node {
	const result = parseInput(input);
	if (!result.ok) return null as unknown as Node;
	const cc = createContext();
	if (exts === "get" || exts === "both") {
		const getter = makeGetterExt(receiverType);
		registerExtension(cc.extensionRegistry, getter);
		const gSym = makeSymbol("[]", SymbolKind.Function, getter.fnType, false);
		defineSymbol(cc.table, gSym);
	}
	if (exts === "set" || exts === "both") {
		const setter = makeSetterExt(receiverType);
		registerExtension(cc.extensionRegistry, setter);
		const sSym = makeSymbol("[]=", SymbolKind.Function, setter.fnType, false);
		defineSymbol(cc.table, sSym);
	}
	const objType = createStruct(receiverType, [], [], false);
	const varSym = makeSymbol(receiverName, SymbolKind.Variable, objType, false);
	defineSymbol(cc.table, varSym);
	const ctx = createTransformContextWithChecker(cc);
	return lowerSubscript(result.value, ctx);
}

// ===== Tests =====
test "getter rewritten to call" {
	const prog = setupSubscriptCtx("buf[0];", "buf", "Buffer", "get");
	assert firstExprKind(prog) === NodeKind.CallExpr;
}

test "setter rewritten to call" {
	const prog = setupSubscriptCtx("buf[0] = 1;", "buf", "Buffer", "set");
	assert firstExprKind(prog) === NodeKind.CallExpr;
}

test "builtin array unchanged" {
	const result = parseInput("arr[0];");
	if (!result.ok) return;
	const cc = createContext();
	const getter = makeGetterExt("Array");
	registerExtension(cc.extensionRegistry, getter);
	const arrType = createArray(unknownType());
	const arrSym = makeSymbol("arr", SymbolKind.Variable, arrType, false);
	defineSymbol(cc.table, arrSym);
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerSubscript(result.value, ctx);
	assert firstExprKind(prog) === NodeKind.ArrayAccess;
}

test "no extension unchanged" {
	const result = parseInput("obj[0];");
	if (!result.ok) return;
	const cc = createContext();
	const objType = createStruct("Widget", [], [], false);
	const objSym = makeSymbol("obj", SymbolKind.Variable, objType, false);
	defineSymbol(cc.table, objSym);
	const ctx = createTransformContextWithChecker(cc);
	const prog = lowerSubscript(result.value, ctx);
	assert firstExprKind(prog) === NodeKind.ArrayAccess;
}

test "no checker no rewrite" {
	const result = parseInput("buf[0];");
	if (!result.ok) return;
	const ctx = createTransformContext();
	const prog = lowerSubscript(result.value, ctx);
	assert firstExprKind(prog) === NodeKind.ArrayAccess;
}

test "getter has 2 args" {
	const prog = setupSubscriptCtx("buf[i];", "buf", "Buffer", "get");
	assert firstCallArgCount(prog) === 2;
}

test "setter has 3 args" {
	const prog = setupSubscriptCtx("buf[i] = v;", "buf", "Buffer", "set");
	assert firstCallArgCount(prog) === 3;
}

test "parser accepts backtick function name" {
	const result = parseInput("function `[]`(this b: Buffer, i: number): number { return 0; }");
	assert result.ok;
	if (!result.ok) return;
	const stmts = getStmts(result.value);
	assert stmts.length > 0;
	assert stmts[0].kind === NodeKind.FunctionDecl;
}
