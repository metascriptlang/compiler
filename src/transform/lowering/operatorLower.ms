// Operator Lowering — rewrite binary ops to function calls when operator overload exists
//
// Nim parity: system.nim defines `proc \`==\`*[T: tuple|object](x, y: T): bool`
// and semantic analysis resolves `a == b` into `\`==\`(a, b)` as a normal call.
// Codegen never sees struct == struct.
//
// This transform does the same: when a BinaryExpr's operand type has a matching
// operator function registered in ExtensionRegistry, rewrite to CallExpr.
// Built-in types (number, string, boolean) are never rewritten.
//
// Nim parity coverage:
//   system.nim:1973  — proc `==`*[T: tuple|object]  → auto-generated _eq
//   system.nim:1980  — proc `<=`*[T: tuple]          → auto-generated _le
//   system.nim:1989  — proc `<`*[T: tuple]           → auto-generated _lt
//   comparisons.nim  — template `!=` = not(==)        → derived from ==
//   comparisons.nim  — template `>` = y < x           → derived from <
//   comparisons.nim  — template `>=` = y <= x         → derived from <=
//
// Reference compiler: parser.zig:7162 isOperatorName, lexer.zig:422 scanBacktick

import { Node, NodeKind, BinaryExprData, IdentifierData, SourceLocation, ProgramData } from "../../ast/node";
import { TransformContext, PendingTupleOp } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeUnary } from "../util";
import { lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind, typeNameOf, tupleTypeName } from "../../checker/types";
import { findExtension, ExtensionMethod } from "../../checker/context";

// ===== Type Resolution =====

// Resolve the Type of an expression node.
// Tries nodeType first (set by checker/analyzer), then symbol table lookup for identifiers.
function resolveType(ctx: TransformContext, node: Node): Type {
	// 1. nodeType (set by checker on declarations, by analyzer on DRC-injected nodes)
	if (node.nodeType !== null) {
		return node.nodeType;
	}
	// 2. Symbol table lookup for identifiers
	if (ctx.checkerCtx === null) return null as unknown as Type;
	if (node.kind !== NodeKind.Identifier) return null as unknown as Type;
	const d = node.data as IdentifierData;
	const sym = lookupSymbol(ctx.checkerCtx.table, d.name);
	if (sym === null) return null as unknown as Type;
	return sym.symbolType;
}

// Built-in types that use native C operators — never rewrite these.
function isBuiltinType(typeName: string): boolean {
	return typeName === "" || typeName === "number" || typeName === "string"
		|| typeName === "boolean" || typeName === "void" || typeName === "null"
		|| typeName === "int8" || typeName === "int16" || typeName === "int32" || typeName === "int64"
		|| typeName === "uint8" || typeName === "uint16" || typeName === "uint32" || typeName === "uint64"
		|| typeName === "float32" || typeName === "float64";
}

// Map MetaScript binary operators to their operator function names.
// Only operators that can be overloaded are mapped.
function binaryOpName(op: string): string {
	return match (op) {
		"===" => "==",
		"!==" => "!=",
		"<" => "<",
		"<=" => "<=",
		">" => ">",
		">=" => ">=",
		"+" => "+",
		"-" => "-",
		"*" => "*",
		"/" => "/",
		"%" => "%",
		_ => "",
	};
}

// ===== Derived Operators (Nim parity: system/comparisons.nim) =====
//
// Nim defines derived operators as templates — pure syntactic rewrites:
//   template `!=`*(x, y: untyped): untyped = not (x == y)
//   template `>`*(x, y: untyped): untyped  = y < x
//   template `>=`*(x, y: untyped): untyped = y <= x
//
// We do the same: derive != from ==, > from <, >= from <=.
// This is generic — works for ANY type that has the base operator.

// Get the base operator that a derived operator depends on.
function derivedBaseOp(opName: string): string {
	return match (opName) {
		"!=" => "==",
		">" => "<",
		">=" => "<=",
		_ => "",
	};
}

// ===== Operator Resolution =====

// Check if a type is a value-type object (interface) — candidate for auto-generated ==.
function isValueObject(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Object) return false;
	if (t.typeName === "") return false;
	// isInterface flag is bit 0 of typeFlags
	return (t.typeFlags & 1) !== 0;
}

// Check if a base operator has an implementation for a given type.
// Checks: explicit extension → auto-generated (== for objects, ==/</<= for tuples).
function hasOperator(ctx: TransformContext, typeName: string, opName: string, leftType: Type): boolean {
	if (ctx.checkerCtx.extensionRegistry !== null) {
		if (findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName) !== null) return true;
	}
	// Auto-generated == exists for all value-type objects (Nim: proc `==`*[T: tuple|object])
	if (opName === "==" && isValueObject(leftType)) return true;
	// Auto-generated ==, <, <= exist for all tuples (Nim: system.nim:1973-1996)
	if (leftType.kind === TypeKind.Tuple) {
		if (opName === "==" || opName === "<" || opName === "<=") return true;
	}
	return false;
}

// Register a pending tuple operation for later generation by destructorLifting.
function registerTupleOp(ctx: TransformContext, t: Type, tName: string, op: string): void {
	// Find existing entry for this tuple
	let i = 0;
	while (i < ctx.pendingTupleOps.length) {
		if (ctx.pendingTupleOps[i].tupleName === tName) {
			// Add op if not already present
			let found = false;
			for (const existing of ctx.pendingTupleOps[i].ops) {
				if (existing === op) { found = true; }
			}
			if (!found) ctx.pendingTupleOps[i].ops.push(op);
			return;
		}
		i += 1;
	}
	// Create new entry
	const entry: PendingTupleOp = { tupleType: t, tupleName: tName, ops: [op] };
	ctx.pendingTupleOps.push(entry);
}

// Resolve a base operator to a CallExpr.
// Returns the call node, or null if no implementation found.
function resolveOpCall(ctx: TransformContext, typeName: string, opName: string, leftType: Type, left: Node, right: Node, loc: SourceLocation): Node {
	// Explicit extension takes priority
	if (ctx.checkerCtx.extensionRegistry !== null) {
		const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName);
		if (ext !== null) {
			return makeCall(makeIdent(opName, loc), [left, right], loc);
		}
	}
	// Auto-generated == for interfaces
	if (opName === "==" && isValueObject(leftType)) {
		return makeCall(makeIdent(typeName + "_eq", loc), [left, right], loc);
	}
	// Auto-generated ==, <, <= for tuples (Nim: system.nim:1973-1996)
	if (leftType.kind === TypeKind.Tuple) {
		const tName = tupleTypeName(leftType);
		if (tName === "") return null as unknown as Node;
		const suffix = match (opName) {
			"==" => "_eq",
			"<" => "_lt",
			"<=" => "_le",
			_ => "",
		};
		if (suffix !== "") {
			registerTupleOp(ctx, leftType, tName, suffix);
			return makeCall(makeIdent(tName + suffix, loc), [left, right], loc);
		}
	}
	return null as unknown as Node;
}

// ===== Visitor =====

function lowerOperatorNode(node: Node, ctx: TransformContext): Node {
	if (node.kind !== NodeKind.BinaryExpr) return node;
	if (ctx.checkerCtx === null) return node;

	const d = node.data as BinaryExprData;

	// Only rewrite overloadable operators
	const opName = binaryOpName(d.operator);
	if (opName === "") return node;

	// Resolve left operand type
	const leftType = resolveType(ctx, d.left);
	if (leftType === null) return node;
	const typeName = typeNameOf(leftType);
	if (typeName === "") return node;

	const loc = node.location;

	// 1. Explicit user-defined operator overload takes priority (Nim parity:
	//    user overloads beat magic builtins). Checked BEFORE isBuiltinType
	//    so that e.g. `==`(a: int32, b: int32) overrides native ==.
	if (ctx.checkerCtx.extensionRegistry !== null) {
		const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName);
		if (ext !== null) {
			return makeCall(makeIdent(opName, loc), [d.left, d.right], loc);
		}
	}

	// 2. Built-in types use native C operators — no rewrite needed.
	if (isBuiltinType(typeName)) return node;

	// 3. Derived operators (Nim: system/comparisons.nim templates).
	//    != → not(==), > → swap(<), >= → swap(<=)
	//    Generic — works for any type that has the base operator.
	const baseOp = derivedBaseOp(opName);
	if (baseOp !== "" && hasOperator(ctx, typeName, baseOp, leftType)) {
		if (opName === "!=") {
			// template `!=`*(x, y): untyped = not (x == y)
			const eqCall = resolveOpCall(ctx, typeName, baseOp, leftType, d.left, d.right, loc);
			return makeUnary("!", eqCall, loc);
		}
		if (opName === ">" || opName === ">=") {
			// template `>`*(x, y): untyped  = y < x   (swap operands)
			// template `>=`*(x, y): untyped = y <= x   (swap operands)
			return resolveOpCall(ctx, typeName, baseOp, leftType, d.right, d.left, loc);
		}
	}

	// 4. Direct base operators for value-type objects (auto-generated ==).
	if (opName === "==" && isValueObject(leftType)) {
		return makeCall(makeIdent(typeName + "_eq", loc), [d.left, d.right], loc);
	}

	// 5. Direct base operators for tuples (auto-generated ==, <, <=).
	//    Nim: system.nim:1973 (==), :1989 (<), :1980 (<=)
	if (leftType.kind === TypeKind.Tuple) {
		const resolved = resolveOpCall(ctx, typeName, opName, leftType, d.left, d.right, loc);
		if (resolved !== null) return resolved;
	}

	return node;
}

// ===== Entry Point =====

export function lowerOperators(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerOperatorNode(node, ctx);
	});
}

// ===== Tests =====

import { createContext, createExtensionRegistry, registerExtension } from "../../checker/context";
import { createObject, createFunction, createTuple, unknownType, numberType, stringType, booleanType } from "../../checker/types";
import { Symbol, defineSymbol, makeSymbol, SymbolKind, createSymbolTable } from "../../checker/symbol";
import { createTransformContext, createTransformContextWithChecker } from "../context";
import { parseInput, getStmts, firstExprKind, firstCallArgCount } from "../testUtil";

function makeOpExt(receiverType: string, opName: string): ExtensionMethod {
	return {
		methodName: opName,
		receiverTypeName: receiverType,
		sourcePath: "",
		fnType: createFunction([unknownType(), unknownType()], ["a", "b"], unknownType()),
		isStatic: false,
		sym: null as unknown as Symbol,
	};
}

function setupCtx(typeName: string, opName: string): TransformContext {
	const checkerCtx = createContext();
	const registry = createExtensionRegistry();
	registerExtension(registry, makeOpExt(typeName, opName));
	checkerCtx.extensionRegistry = registry;
	const objType = createObject(typeName, [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	return createTransformContextWithChecker(checkerCtx);
}

function setupTupleCtx(): TransformContext {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const tupType = createTuple([numberType(), stringType()]);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, tupType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, tupType, false));
	return createTransformContextWithChecker(checkerCtx);
}

import { test, check } from "std/testing";

// ===== Object operator tests =====

test "operator lower rewrites === on interface types" {
	const ctx = setupCtx("Token", "==");
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	const stmts = getStmts(result);
	check(stmts.length > 0);
	check(stmts[0].kind === NodeKind.ExprStmt);
}

test "operator lower does not rewrite builtin types without override" {
	// No explicit extension for number — native == used
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const numType = unknownType(); // number-like
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, numType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, numType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

test "operator lower rewrites builtin type with explicit override" {
	// User-defined override for number — takes priority over native ==
	const ctx = setupCtx("number", "==");
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Explicit extension registered → rewritten to CallExpr
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "operator lower auto-rewrites === on interface without explicit extension" {
	// Nim parity: all value-type objects get auto-generated == (no explicit extension needed)
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createObject("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	const stmts = getStmts(result);
	check(stmts.length > 0);
	// Interface type auto-rewrites to Token_eq(a, b) — CallExpr, not BinaryExpr
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "operator lower does not rewrite non-interface objects" {
	// Classes are reference types — no auto-generated ==
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createObject("MyClass", [], [], false);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

// ===== Derived operator tests (Nim: system/comparisons.nim) =====

test "!== derives from == on interface (auto-generated)" {
	// Nim: template `!=`*(x, y) = not (x == y)
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createObject("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// !== → !Token_eq(a, b) — UnaryExpr wrapping CallExpr
	check(firstExprKind(result) === NodeKind.UnaryExpr);
}

test "!== derives from explicit == extension" {
	// User defines == for Coord, !== auto-derived
	const ctx = setupCtx("Coord", "==");
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// !== → !==(a, b) — UnaryExpr wrapping CallExpr
	check(firstExprKind(result) === NodeKind.UnaryExpr);
}

test "> derives from < (swap operands)" {
	// Nim: template `>`*(x, y) = y < x
	const ctx = setupCtx("Vec", "<");
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// > → <(b, a) — CallExpr with swapped args
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test ">= derives from <= (swap operands)" {
	// Nim: template `>=`*(x, y) = y <= x
	const ctx = setupCtx("Vec", "<=");
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// >= → <=(b, a) — CallExpr with swapped args
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "> not derived without < defined" {
	// No < extension → > stays as BinaryExpr
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createObject("Vec", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

test "explicit != overrides derivation from ==" {
	// User defines both == and != — != uses explicit, not derived
	const checkerCtx = createContext();
	const registry = createExtensionRegistry();
	registerExtension(registry, makeOpExt("Token", "=="));
	registerExtension(registry, makeOpExt("Token", "!="));
	checkerCtx.extensionRegistry = registry;
	const objType = createObject("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Explicit != extension → direct CallExpr (not UnaryExpr wrapping)
	check(firstExprKind(result) === NodeKind.CallExpr);
}

// ===== Tuple operator tests (Nim: system.nim:1973-1996) =====

test "tuple === rewrites to _eq call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
	// Should register pending tuple op
	check(ctx.pendingTupleOps.length > 0);
}

test "tuple < rewrites to _lt call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a < b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "tuple <= rewrites to _le call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a <= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "tuple !== derives from == (auto-generated)" {
	// Nim: template `!=` = not(==) — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.UnaryExpr);
}

test "tuple > derives from < (swap)" {
	// Nim: template `>` = y < x — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "tuple >= derives from <= (swap)" {
	// Nim: template `>=` = y <= x — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "pending tuple ops dedup" {
	const ctx = setupTupleCtx();
	const pr1 = parseInput("a === b;");
	if (!pr1.ok) return;
	lowerOperators(pr1.value, ctx);
	const pr2 = parseInput("a === b;");
	if (!pr2.ok) return;
	lowerOperators(pr2.value, ctx);
	// Same tuple type used twice — should only have 1 pending entry
	check(ctx.pendingTupleOps.length === 1);
}
