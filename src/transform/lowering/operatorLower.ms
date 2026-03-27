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

import { Node, NodeKind, BinaryExprData, IdentifierData, TypeAssertionData, SourceLocation, ProgramData, Type, TypeKind, Symbol, SymbolKind } from "../../ast/node";
import { TransformContext, PendingTupleOp } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeUnary, makeBool, makeMember, makeBinary } from "../util";
import { typeNameOf, tupleTypeName, createFunction, booleanType, isMaybeType } from "../../checker/types";
import { lookupSymbol } from "../../checker/symbol";
import { findExtension, ExtensionMethod } from "../../checker/context";

// ===== Type Resolution =====

// Resolve the Type of an expression node.
// Tries nodeType first (set by checker/analyzer), then resolvedSym, then symbol table.
function resolveType(ctx: TransformContext, node: Node): Type {
	if (node.nodeType !== null) return node.nodeType;
	if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
		return node.resolvedSym.symbolType;
	}
	// Fallback: symbol table lookup for identifiers without resolvedSym
	if (ctx.checkerCtx === null) return null;
	if (node.kind !== NodeKind.Identifier) return null;
	const d = node.data as IdentifierData;
	const sym = lookupSymbol(ctx.checkerCtx.table, d.name);
	if (sym === null) return null;
	return sym.symbolType;
}

// Built-in types that use native C operators — never rewrite these.
function isBuiltinType(typeName: string): boolean {
	// String is NOT builtin — it has operator overloads (==, <, <=) in prelude.
	return typeName === "" || typeName === "number"
		|| typeName === "boolean" || typeName === "void" || typeName === "null"
		|| typeName === "int8" || typeName === "int16" || typeName === "int32" || typeName === "int64"
		|| typeName === "uint8" || typeName === "uint16" || typeName === "uint32" || typeName === "uint64"
		|| typeName === "float32" || typeName === "float64";
}



// ===== Null Detection =====

// Recursively unwrap TypeAssertion to detect null expressions.
// `null` → TypeAssertion(TypeAssertion(NullLiteral, "unknown"), "Type")
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
	if (t.kind !== TypeKind.Struct) return false;
	if (isMaybeType(t)) return false;
	return t.typeName !== "";
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

// Build a call to an operator extension — resolves nativeName for extern operators.
function makeExtOpCall(ext: ExtensionMethod, opName: string, left: Node, right: Node, loc: SourceLocation): Node {
	let callName = opName;
	if (ext.sym !== null) {
		if (ext.sym.nativeName !== null && ext.sym.nativeName !== "") {
			callName = ext.sym.nativeName;
		} else if (ext.sym.name !== "") {
			callName = ext.sym.name;
		}
	}
	const callIdent = makeIdent(callName, loc);
	callIdent.resolvedSym = ext.sym;
	return makeCall(callIdent, [left, right], loc);
}

// Resolve a base operator to a CallExpr.
function resolveOpCall(ctx: TransformContext, typeName: string, opName: string, leftType: Type, left: Node, right: Node, loc: SourceLocation): Node {
	// Explicit extension takes priority
	if (ctx.checkerCtx.extensionRegistry !== null) {
		const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName);
		if (ext !== null) {
			return makeExtOpCall(ext, opName, left, right, loc);
		}
	}
	// Auto-generated == for interfaces (=== same as == for value types)
	if ((opName === "==" || opName === "===") && isValueObject(leftType)) {
		const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
		const callee = makeIdent(typeName + "Eq", loc);
		callee.nodeType = fnType;
		return makeCall(callee, [left, right], loc);
	}
	// Closure equality: a === b → a.fn === b.fn && a.env === b.env (reference parity)
	if ((opName === "==" || opName === "===" || opName === "!=" || opName === "!==") && leftType.kind === TypeKind.Function) {
		const fnA = makeMember(left, "fn", loc);
		const fnB = makeMember(right, "fn", loc);
		const envA = makeMember(left, "env", loc);
		const envB = makeMember(right, "env", loc);
		const fnEq = makeBinary(fnA, "===", fnB, loc);
		const envEq = makeBinary(envA, "===", envB, loc);
		const bothEq = makeBinary(fnEq, "&&", envEq, loc);
		if (opName === "!=" || opName === "!==") return makeUnary("!", bothEq, loc);
		return bothEq;
	}
	// Auto-generated ==, <, <= for tuples (reference: reference core:1973-1996)
	if (leftType.kind === TypeKind.Tuple) {
		const tName = tupleTypeName(leftType);
		if (tName === "") return null as unknown as Node;
		const suffix = match (opName) {
			"==" | "===" => "Eq",
			"<" => "Lt",
			"<=" => "Le",
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
	const opName = d.operator;
	const isNotEqual = opName === "!=" || opName === "!==";

	// Resolve left operand type
	const leftType = resolveType(ctx, d.left);
	const loc = node.location;

	// 3. Null comparisons — check BEFORE typeName guard since null has typeName=""
	// reference parity: objects can't be nil (reference comparisons, reference core)
	const hasNullLeft = isNullExpr(d.left);
	const hasNullRight = isNullExpr(d.right);
	if (hasNullLeft || hasNullRight) {
		const valueType = hasNullLeft ? resolveType(ctx, d.right) : leftType;
		if (valueType !== null && isValueObject(valueType)) {
			return makeBool(isNotEqual, loc);
		}
		// Maybe<T>: x !== null → x.present, x === null → !x.present
		if (valueType !== null && isMaybeType(valueType)) {
			const nonNullSide = hasNullLeft ? d.right : d.left;
			const member = makeMember(nonNullSide, "present", loc);
			if (isNotEqual) return member;
			return makeUnary("!", member, loc);
		}
		// Array null check: arrays are value-type structs { len, p } — can never be null.
		// Reference parity: disallows isNil on sequences (value types with same layout).
		// Empty arrays have p=NULL but are valid — push handles lazy alloc.
		// Fold to constant true/false, same as strings, results, tuples.
		if (valueType !== null && valueType.kind === TypeKind.Array) {
			return makeBool(isNotEqual, loc);
		}
		// Closure null check: closure !== null → closure.fn !== null
		// msClosure is a value struct { fn, env } — check the function pointer field.
		if (valueType !== null && valueType.kind === TypeKind.Function) {
			const nonNullSide = hasNullLeft ? d.right : d.left;
			const fnMember = makeMember(nonNullSide, "fn", loc);
			d.left = hasNullLeft ? d.left : fnMember;
			d.right = hasNullLeft ? fnMember : d.right;
			return node;
		}
		// Other value types (Result, Tuple, String, Union) can never be null —
		// fold to constant true/false. Reference parity: value types can't be nil.
		if (valueType !== null) {
			const vk = valueType.kind;
			if (vk === TypeKind.GenericInstance || vk === TypeKind.Tuple || vk === TypeKind.String
				|| vk === TypeKind.Union) {
				return makeBool(isNotEqual, loc);
			}
		}
	}

	if (leftType === null) return node;
	const typeName = typeNameOf(leftType);
	if (typeName === "") return node;

	// 1. Explicit user-defined operator overload takes priority (reference parity:
	//    user overloads beat magic builtins). Checked BEFORE isBuiltinType
	//    so that e.g. `==`(a: int32, b: int32) overrides native ==.
	if (ctx.checkerCtx.extensionRegistry !== null) {
		const ext = findExtension(ctx.checkerCtx.extensionRegistry, typeName, opName);
		if (ext !== null) {
			return makeExtOpCall(ext, opName, d.left, d.right, loc);
		}
	}

	// 2a. String operators (==, !=, <, >, <=, >=) handled by operator overloads in prelude.
	// No hardcoded lowering — the overloads are registered as extensions and found above.

	// 2b. Built-in types use native C operators — no rewrite needed.
	if (isBuiltinType(typeName)) return node;

	// 4. Derived operators — fallback for types without explicit prelude overloads.
	// Strings have all operators in prelude (found in step 1 above).
	// Interfaces/tuples still use compiler derivation until templates exist.
	const baseOp = match (opName) {
		"!=" => "==",
		"!==" => "===",
		">" => "<",
		">=" => "<=",
		_ => "",
	};
	if (baseOp !== "") {
		// Check if base operator exists (explicit extension or auto-generated)
		let hasBase = false;
		if (ctx.checkerCtx.extensionRegistry !== null) {
			if (findExtension(ctx.checkerCtx.extensionRegistry, typeName, baseOp) !== null) hasBase = true;
		}
		if (!hasBase && (baseOp === "==" || baseOp === "===") && isValueObject(leftType)) hasBase = true;
		if (!hasBase && leftType.kind === TypeKind.Tuple && (baseOp === "==" || baseOp === "===" || baseOp === "<" || baseOp === "<=")) hasBase = true;

		if (hasBase) {
			if (opName === "!=" || opName === "!==") {
				const eqCall = resolveOpCall(ctx, typeName, baseOp, leftType, d.left, d.right, loc);
				return makeUnary("!", eqCall, loc);
			}
			if (opName === ">" || opName === ">=") {
				return resolveOpCall(ctx, typeName, baseOp, leftType, d.right, d.left, loc);
			}
		}
	}

	// 5. Direct base operators for value-type objects (auto-generated ==).
	// === is the same as == for value types (no reference identity distinction).
	if ((opName === "==" || opName === "===") && isValueObject(leftType)) {
		const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
		const callee = makeIdent(typeName + "Eq", loc);
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
import { createStruct, createFunction, createTuple, createRef, createPtr, createMaybeType, unknownType, numberType, stringType, booleanType } from "../../checker/types";
import { defineSymbol, makeSymbol, createSymbolTable } from "../../checker/symbol";
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
	const objType = createStruct(typeName, [], [], true);
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

// ===== Object operator tests =====

test "operator lower rewrites === on interface types" {
	const ctx = setupCtx("Token", "==");
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	const stmts = getStmts(result);
	assert stmts.length > 0;
	assert stmts[0].kind === NodeKind.ExprStmt;
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
	assert firstExprKind(result) === NodeKind.BinaryExpr;
}

test "operator lower rewrites builtin type with explicit override" {
	// User-defined override for number == — takes priority over native ==
	const ctx = setupCtx("number", "==");
	const pr = parseInput("a == b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Explicit extension registered → rewritten to CallExpr
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "operator lower auto-rewrites === on interface without explicit extension" {
	// reference parity: all value-type objects get auto-generated == (no explicit extension needed)
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	const stmts = getStmts(result);
	assert stmts.length > 0;
	// Interface type auto-rewrites to Token_eq(a, b) — CallExpr, not BinaryExpr
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "operator lower does not rewrite Ref types" {
	// Classes (Ref<Object>) are reference types — no auto-generated ==
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createRef(createStruct("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.BinaryExpr;
}

// ===== Derived operator tests (reference: system/reference comparisons) =====

test "!== derives from == on interface (auto-generated)" {
	// Reference: template `!=`*(x, y) = not (x == y)
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// !== → !Token_eq(a, b) — UnaryExpr wrapping CallExpr
	assert firstExprKind(result) === NodeKind.UnaryExpr;
}

test "!== derives from explicit == extension" {
	// User defines == for Coord, !== auto-derived
	const ctx = setupCtx("Coord", "==");
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// !== → !==(a, b) — UnaryExpr wrapping CallExpr
	assert firstExprKind(result) === NodeKind.UnaryExpr;
}

test "> derives from < (swap operands)" {
	// Reference: template `>`*(x, y) = y < x
	const ctx = setupCtx("Vec", "<");
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// > → <(b, a) — CallExpr with swapped args
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test ">= derives from <= (swap operands)" {
	// Reference: template `>=`*(x, y) = y <= x
	const ctx = setupCtx("Vec", "<=");
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// >= → <=(b, a) — CallExpr with swapped args
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "> not derived without < defined" {
	// No < extension → > stays as BinaryExpr
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Vec", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.BinaryExpr;
}

test "explicit != overrides derivation from ==" {
	// User defines both == and !== — !== uses explicit, not derived
	const checkerCtx = createContext();
	const registry = createExtensionRegistry();
	registerExtension(registry, makeOpExt("Token", "=="));
	registerExtension(registry, makeOpExt("Token", "!=="));
	checkerCtx.extensionRegistry = registry;
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Explicit !== extension → direct CallExpr (not UnaryExpr wrapping)
	assert firstExprKind(result) === NodeKind.CallExpr;
}

// ===== Tuple operator tests (reference: reference core:1973-1996) =====

test "tuple === rewrites to _eq call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.CallExpr;
	// Should register pending tuple op
	assert ctx.pendingTupleOps.length > 0;
}

test "tuple < rewrites to _lt call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a < b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "tuple <= rewrites to Le call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a <= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "tuple !== derives from == (auto-generated)" {
	// Reference: template `!=` = not(==) — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.UnaryExpr;
}

test "tuple > derives from < (swap)" {
	// Reference: template `>` = y < x — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.CallExpr;
}

test "tuple >= derives from <= (swap)" {
	// Reference: template `>=` = y <= x — works for tuples too
	const ctx = setupTupleCtx();
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.CallExpr;
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
	assert ctx.pendingTupleOps.length === 1;
}

// ===== Nullable Pointer Tests =====

test "Ref !== null is NOT constant-folded" {
	// Ref<Object> is a pointer type — null comparison should pass through
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const refType = createRef(createStruct("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("x", SymbolKind.Variable, refType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("x !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should remain BinaryExpr (not constant-folded to BooleanLiteral)
	assert firstExprKind(result) === NodeKind.BinaryExpr;
}

test "Ptr !== null is NOT constant-folded" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const ptrType = createPtr(createStruct("Buffer", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("p", SymbolKind.Variable, ptrType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("p !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	assert firstExprKind(result) === NodeKind.BinaryExpr;
}

test "Maybe<Interface> !== null rewrites to .present" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const maybeType = createMaybeType(createStruct("Token", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, maybeType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should rewrite to t.present → MemberExpr
	assert firstExprKind(result) === NodeKind.MemberExpr;
}

test "interface !== null constant-folds to true" {
	// Plain interface (non-nullable) — null comparison is always true
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerOperators(pr.value, ctx);
	// Should constant-fold to BooleanLiteral(true)
	assert firstExprKind(result) === NodeKind.BooleanLiteral;
}
