// New Expression Lowering — rewrite `new Foo(args)` to `Foo_new(args)`
//
// In C backend, class constructors are emitted as ClassName_new() functions.
// This transform rewrites NewExpr → CallExpr so codegen sees a normal call.
// Follows standard allocation pattern: allocation delegated to constructor function.

import { Node, NodeKind, NewExprData, IdentifierData, MemberExprData } from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import { TransformContext, createTransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { ExprStmtData, CallExprData } from "../../ast/node";

// ===== Value Destructor Resolution =====
// Resolves the C destructor function name for a Map's value type.
// Only pointer-type values (classes/objects on the heap) have destructors.
// Value-type structs (string, array) require boxing — deferred.

function resolveValueDestructor(valueType: Type): string {
	if (valueType === null) return "NULL";
	// Object types (classes/interfaces) are heap-allocated pointers — destructor frees them
	if (valueType.kind === TypeKind.Struct) {
		if (valueType.typeName !== null && valueType.typeName.length > 0) {
			return "(msMapValueDestructor)" + valueType.typeName + "_destroy";
		}
	}
	// Ref/Ptr types (generic heap objects) — use msDecref-style cleanup
	if (valueType.kind === TypeKind.Ref) {
		if (valueType.typeName !== null && valueType.typeName.length > 0) {
			return "(msMapValueDestructor)" + valueType.typeName + "_destroy";
		}
	}
	// Primitives, enums, etc. — no cleanup needed
	return "NULL";
}

// ===== Visitor =====

function lowerNewNode(node: Node): Node {
	if (node.kind !== NodeKind.NewExpr) return node;
	const d = node.data as NewExprData;
	const loc = node.location;

	// `new Foo(args)` → `Foo_new(args)`
	// Extract class name from callee
	if (d.newCallee.kind === NodeKind.Identifier) {
		const id = d.newCallee.data as IdentifierData;
		// Runtime-provided types → direct runtime constructor
		if (id.name === "Map") {
			// Resolve value destructor from Map's typeExtra (value type)
			let destructorName = "NULL";
			if (node.nodeType !== null && node.nodeType.typeExtra !== null) {
				destructorName = resolveValueDestructor(node.nodeType.typeExtra);
			}
			const call = makeCall(makeIdent("msMapNew", loc), [makeIdent(destructorName, loc)], loc);
			call.nodeType = node.nodeType;
			return call;
		}
		if (id.name === "Set") {
			// Set has no values — always NULL destructor
			const call = makeCall(makeIdent("msSetNew", loc), [], loc);
			call.nodeType = node.nodeType;
			return call;
		}
		// Only lower to ClassName_new() when arguments exist (explicit constructor).
		// No-arg new: leave as NewExpr for backend-specific inline allocation (Standard reference pattern)
		if (d.newArguments.length > 0) {
			const ctorName = id.name + "_new";
			return makeCall(makeIdent(ctorName, loc), d.newArguments, loc);
		}
		return node;
	}

	// `new ns.Foo(args)` → `ns_Foo_new(args)` (member expression callee)
	if (d.newCallee.kind === NodeKind.MemberExpr) {
		const m = d.newCallee.data as MemberExprData;
		if (m.object.kind === NodeKind.Identifier) {
			const objId = m.object.data as IdentifierData;
			if (d.newArguments.length > 0) {
				const ctorName = objId.name + "_" + m.property + "_new";
				return makeCall(makeIdent(ctorName, loc), d.newArguments, loc);
			}
			return node;
		}
	}

	// Fallback: emit as Callee_new(args) with callee as-is
	return makeCall(makeIdent("__new", loc), d.newArguments, loc);
}

// ===== Entry Point =====

export function lowerNewExpr(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerNewNode);
}

// ===== Test Helpers =====

function getCallName(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "PARSE_ERROR";
	const ctx = createTransformContext();
	const prog = lowerNewExpr(result.value, ctx);
	const stmts = getStmts(prog);
	if (stmts.length === 0) return "NO_STMTS";
	if (stmts[0].kind !== NodeKind.ExprStmt) return "NOT_EXPR";
	const sd = stmts[0].data as ExprStmtData;
	if (sd.expr.kind !== NodeKind.CallExpr) return "NOT_CALL";
	const cd = sd.expr.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return "NOT_IDENT";
	const id = cd.callee.data as IdentifierData;
	return id.name;
}

// ===== Tests =====
test "new Foo() stays NewExpr (inline alloc)" { assert firstExprKindAfter("new Foo();", lowerNewExpr) === NodeKind.NewExpr; }

test "new Bar(x, y) becomes Bar_new(x, y)" {
	const name = getCallName("new Bar(x, y);");
	assert name === "Bar_new";
}

test "new Map() becomes msMapNew()" { assert getCallName("new Map();") === "msMapNew"; }

test "new with args is CallExpr" { assert firstExprKindAfter("new Foo(x);", lowerNewExpr) === NodeKind.CallExpr; }

test "non-new unchanged" { assert firstExprKindAfter("foo();", lowerNewExpr) === NodeKind.CallExpr; }

test "stmt count preserved" { assert stmtCountAfter("new A(); new B();", lowerNewExpr) === 2; }

test "new with args preserved count" {
	const result = parseInput("new Foo(1, 2);");
	if (!result.ok) { assert false; return; }
	const ctx = createTransformContext();
	const prog = lowerNewExpr(result.value, ctx);
	const stmts = getStmts(prog);
	const sd = stmts[0].data as ExprStmtData;
	const cd = sd.expr.data as CallExprData;
	assert cd.arguments.length === 2;
}
