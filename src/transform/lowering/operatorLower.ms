// Operator Lowering — rewrite binary ops to function calls when operator overload exists
//
// reference parity: reference core defines `proc \`==\`*[T: tuple|object](x, y: T): bool`
// and semantic analysis resolves `a == b` into `\`==\`(a, b)` as a normal call.
// Codegen never sees struct == struct.
//
// This transform does the same: when a BinaryExpr's operand type has a matching
// operator function registered in ExtensionRegistry, rewrite to CallExpr.
// Built-in types (number, string, boolean) are never rewritten.
//
// reference parity coverage:
//   reference core:1973  — proc `==`*[T: tuple|object]  → auto-generated _eq
//   reference core:1980  — proc `<=`*[T: tuple]          → auto-generated _le
//   reference core:1989  — proc `<`*[T: tuple]           → auto-generated _lt
//   reference comparisons  — template `!=` = not(==)        → derived from ==
//   reference comparisons  — template `>` = y < x           → derived from <
//   reference comparisons  — template `>=` = y <= x         → derived from <=
//
// Reference compiler: parser.zig:7162 isOperatorName, lexer.zig:422 scanBacktick

import { Node, NodeKind, BinaryExprData, IdentifierData, TypeAssertionData, SourceLocation, ProgramData } from "../../ast/node";
import { TransformContext, PendingTupleOp } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeUnary, makeBool, makeMember } from "../util";
import { lookupSymbol } from "../../checker/symbol";
import { Type, TypeKind, typeNameOf, tupleTypeName, createFunction, booleanType, isMaybeType } from "../../checker/types";
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

// ===== Derived Operators (reference parity: system/reference comparisons) =====
//
// Reference implementation defines derived operators as templates — pure syntactic rewrites:
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

// ===== Null Detection =====

// Recursively unwrap TypeAssertion to detect null expressions.
// `null as unknown as Type` → TypeAssertion(TypeAssertion(NullLiteral, "unknown"), "Type")
export function isNullExpr(node: Node): boolean {
	if (node.kind === NodeKind.NullLiteral) return true;
	if (node.kind === NodeKind.TypeAssertion) return isNullExpr((node.data as TypeAssertionData).asExpr);
	return false;
}

// ===== Operator Resolution =====

// Check if a type is a value-type object (interface) — candidate for auto-generated ==.
// Excludes Maybe<T> types which need special null comparison handling.
function isValueObject(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Object) return false;
	if (isMaybeType(t)) return false;
	return t.typeName !== "";
}

// Check if a base operator has an implementation for a given type.
// Checks: explicit extension → auto-generated (== for objects, ==/</<= for tuples).
function hasOperator(ctx: TransformContext, typeName: string, opName: string, leftType: Type): boolean {
	if (ctx.checkerCtx.extensionRegistry !== null) {
		if (findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName) !== null) return true;
	}
	// Auto-generated == exists for all value-type objects (reference: proc `==`*[T: tuple|object])
	if (opName === "==" && isValueObject(leftType)) return true;
	// Auto-generated ==, <, <= exist for all tuples (reference: reference core:1973-1996)
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
	// Auto-generated == for interfaces — codegen handles & via ccgIntroducedPtr (Nim parity:
	// system.nim:1973 `==`*[T: object](x, y: T) takes value params, codegen adds pointer)
	if (opName === "==" && isValueObject(leftType)) {
		const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
		const callee = makeIdent(typeName + "_eq", loc);
		callee.nodeType = fnType;
		return makeCall(callee, [left, right], loc);
	}
	// Auto-generated ==, <, <= for tuples (reference: reference core:1973-1996)
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
			const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
			const callee = makeIdent(tName + suffix, loc);
			callee.nodeType = fnType;
			return makeCall(callee, [left, right], loc);
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

	// 1. Explicit user-defined operator overload takes priority (reference parity:
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

	// 3. Null comparisons on non-nullable value types → constant bool
	// Nim parity: objects can't be nil (sigmatch.nim:typeRel, system.nim:1452-1457)
	const hasNullLeft = isNullExpr(d.left);
	const hasNullRight = isNullExpr(d.right);
	if (hasNullLeft || hasNullRight) {
		const valueType = hasNullLeft ? resolveType(ctx, d.right) : leftType;
		if (valueType !== null && isValueObject(valueType)) {
			return makeBool(opName === "!=", loc);
		}
		// Maybe<T>: x !== null → x.present, x === null → !x.present
		if (valueType !== null && isMaybeType(valueType)) {
			const nonNullSide = hasNullLeft ? d.right : d.left;
			const member = makeMember(nonNullSide, "present", loc);
			if (opName === "!=") return member;
			return makeUnary("!", member, loc);
		}
	}

	// 4. Derived operators (reference: system/reference comparisons templates).
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

	// 5. Direct base operators for value-type objects (auto-generated ==).
	if (opName === "==" && isValueObject(leftType)) {
		const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
		const callee = makeIdent(typeName + "_eq", loc);
		callee.nodeType = fnType;
		return makeCall(callee, [d.left, d.right], loc);
	}

	// 6. Direct base operators for tuples (auto-generated ==, <, <=).
	//    Reference: reference core:1973 (==), :1989 (<), :1980 (<=)
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
import { createObject, createFunction, createTuple, createRef, createPtr, createMaybeType, unknownType, numberType, stringType, booleanType } from "../../checker/types";
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
	// reference parity: all value-type objects get auto-generated == (no explicit extension needed)
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

test "operator lower does not rewrite Ref types" {
	// Classes (Ref<Object>) are reference types — no auto-generated ==
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createRef(createObject("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

// ===== Derived operator tests (reference: system/reference comparisons) =====

test "!== derives from == on interface (auto-generated)" {
	// Reference: template `!=`*(x, y) = not (x == y)
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
	// Reference: template `>`*(x, y) = y < x
	const ctx = setupCtx("Vec", "<");
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// > → <(b, a) — CallExpr with swapped args
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test ">= derives from <= (swap operands)" {
	// Reference: template `>=`*(x, y) = y <= x
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

// ===== Tuple operator tests (reference: reference core:1973-1996) =====

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
	// Reference: template `!=` = not(==) — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.UnaryExpr);
}

test "tuple > derives from < (swap)" {
	// Reference: template `>` = y < x — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.CallExpr);
}

test "tuple >= derives from <= (swap)" {
	// Reference: template `>=` = y <= x — works for tuples too
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

// ===== Nullable Pointer Tests =====

test "Ref !== null is NOT constant-folded" {
	// Ref<Object> is a pointer type — null comparison should pass through
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const refType = createRef(createObject("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("x", SymbolKind.Variable, refType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("x !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should remain BinaryExpr (not constant-folded to BooleanLiteral)
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

test "Ptr !== null is NOT constant-folded" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const ptrType = createPtr(createObject("Buffer", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("p", SymbolKind.Variable, ptrType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("p !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	check(firstExprKind(result) === NodeKind.BinaryExpr);
}

test "Maybe<Interface> !== null rewrites to .present" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const maybeType = createMaybeType(createObject("Token", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, maybeType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should rewrite to t.present → MemberExpr
	check(firstExprKind(result) === NodeKind.MemberExpr);
}

test "interface !== null constant-folds to true" {
	// Plain interface (non-nullable) — null comparison is always true
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createObject("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should constant-fold to BooleanLiteral(true)
	check(firstExprKind(result) === NodeKind.BooleanLiteral);
}
