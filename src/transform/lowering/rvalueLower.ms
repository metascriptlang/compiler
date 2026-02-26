// Rvalue Lowering — materialize rvalue receivers into temps for C codegen
// Follows reference rvalue_lower.zig + Nim's evalOnce pattern
//
// In C, method calls on rvalue receivers need an lvalue (address):
//   f().method(args)  → { const $tmp = f(); $tmp.method(args); }
//   arr.slice(1).map(fn) → { const $tmp = arr.slice(1); $tmp.map(fn); }
//
// Detection: CallExpr whose callee is MemberExpr whose object is an rvalue
// (another CallExpr, literal, binary expression — anything not an identifier
// or member access).
//
// Only applied in statement position (ExprStmt) where we can expand 1:N.
// In expression position, C codegen handles it (GNU statement expressions
// or codegen-level temp insertion).

import { Node, NodeKind, DeclKind, ExprStmtData, CallExprData, MemberExprData } from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import { makeVarDecl, makeIdent, makeCall, makeMember, makeExprStmt, makeBlock } from "../util";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

// ===== Helpers =====

// Check if an expression is an rvalue (not addressable in C)
function isRvalue(node: Node): boolean {
	return match (node.kind) {
		// Call results are rvalues
		NodeKind.CallExpr => true,
		// Literals are rvalues
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral => true,
		// Binary/unary results are rvalues
		NodeKind.BinaryExpr | NodeKind.UnaryExpr => true,
		// Array/object literals are rvalues
		NodeKind.ArrayLiteral | NodeKind.ObjectLiteral => true,
		// Conditional expression result is rvalue
		NodeKind.ConditionalExpr => true,
		// Identifiers and member access are lvalues (addressable)
		_ => false,
	};
}

// ===== Visitor =====

function lowerRvalueNode(node: Node, ctx: TransformContext): Node {
	// Only handle ExprStmt containing a method call — 1:N expansion
	if (node.kind !== NodeKind.ExprStmt) return node;
	const sd = node.data as ExprStmtData;

	// Must be a call expression
	if (sd.expr.kind !== NodeKind.CallExpr) return node;
	const call = sd.expr.data as CallExprData;

	// Must be a method call: expr.method(args)
	if (call.callee.kind !== NodeKind.MemberExpr) return node;
	const member = call.callee.data as MemberExprData;

	// Receiver must be an rvalue
	if (!isRvalue(member.object)) return node;

	// Transform: f().method(args);
	//   → { const $rval_N = f(); $rval_N.method(args); }
	const loc = node.location;
	const tmpName = freshTemp(ctx, "rval");
	const tmpDecl = makeVarDecl(tmpName, member.object, DeclKind.Const, loc);
	const newCallee = makeMember(makeIdent(tmpName, loc), member.property, loc);
	const newCall = makeCall(newCallee, call.arguments, loc);
	const newExprStmt = makeExprStmt(newCall, loc);
	const stmts: Node[] = [];
	stmts.push(tmpDecl);
	stmts.push(newExprStmt);
	return makeBlock(stmts, loc);
}

// ===== Entry Point =====

export function lowerRvalue(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerRvalueNode(node, ctx);
	});
}

// ===== Tests =====

testGroup("Rvalue Lowering", () => {
	test("method on call becomes block", () => {
		// f().method(); → { const $rval_0 = f(); $rval_0.method(); }
		check(firstStmtKindAfter("f().method();", lowerRvalue) === NodeKind.BlockStmt);
	});
	test("method on identifier unchanged", () => {
		// x.method(); → unchanged (x is lvalue)
		check(firstStmtKindAfter("x.method();", lowerRvalue) === NodeKind.ExprStmt);
	});
	test("method on member unchanged", () => {
		// a.b.method(); → unchanged (a.b is lvalue)
		check(firstStmtKindAfter("a.b.method();", lowerRvalue) === NodeKind.ExprStmt);
	});
	test("method on literal becomes block", () => {
		// [1,2].push(3); → block
		check(firstStmtKindAfter("[1,2].push(3);", lowerRvalue) === NodeKind.BlockStmt);
	});
	test("plain call unchanged", () => {
		// f(); → unchanged (not a method call)
		check(firstStmtKindAfter("f();", lowerRvalue) === NodeKind.ExprStmt);
	});
	test("non-call unchanged", () => {
		check(firstStmtKindAfter("x + y;", lowerRvalue) === NodeKind.ExprStmt);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerRvalue) === NodeKind.WhileStmt);
	});
	test("stmt count preserved", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", lowerRvalue) === 2);
	});
});
