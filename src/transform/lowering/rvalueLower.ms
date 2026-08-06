// Rvalue Lowering — materialize rvalue receivers into temps for C codegen
// Follows reference rvalue_lower.zig + standard evalOnce pattern
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

import { Node, NodeKind, DeclKind, ExprStmtData, CallExprData, MemberExprData, VariableDeclData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { noneType } from "../../checker/types";
import { walkNode, walkExpandBlocks } from "../walker";
import { makeVarDecl, makeIdent, makeIdentResolved, makeCall, makeMember, makeExprStmt, makeBlock } from "../util";
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
	const rvalType = member.object.nodeType !== null ? member.object.nodeType : noneType();
	const sym = freshTempSym(ctx, "rval", rvalType);
	const tmpDecl = makeVarDecl(sym.name, member.object, DeclKind.Const, loc);
	tmpDecl.resolvedSym = sym;
	const newCallee = makeMember(makeIdentResolved(sym, loc), member.property, loc);
	const newCall = makeCall(newCallee, call.arguments, loc);
	const newExprStmt = makeExprStmt(newCall, loc);
	const stmts: Node[] = [];
	stmts.push(tmpDecl);
	stmts.push(newExprStmt);
	return makeBlock(stmts, loc);
}

// ===== AsBytes Bridge Receiver Hoist =====
// The zero-copy bridge emits `((msUint8Array*)&(receiver))` — the receiver must
// be addressable in C. Hoist an rvalue receiver into a peer temp statement
// (flat walkExpandBlocks splice like callHoist — a block would scope a
// VariableDecl away from its followers). Gated on the AsBytes builtin only:
// the general all-methods hoist (lowerRvalue above) is still unwired (bug066).

function isAsBytesCallOnRvalue(expr: Node): boolean {
	if (expr.kind !== NodeKind.CallExpr) return false;
	const call = expr.data as CallExprData;
	if (call.callee.kind !== NodeKind.MemberExpr) return false;
	if (call.callee.resolvedSym === null || call.callee.resolvedSym.builtinKind !== "AsBytes") return false;
	return isRvalue((call.callee.data as MemberExprData).object);
}

function hoistBridgeReceiver(callNode: Node, ctx: TransformContext): Node {
	const member = (callNode.data as CallExprData).callee.data as MemberExprData;
	const loc = callNode.location;
	const rvalType = member.object.nodeType !== null ? member.object.nodeType : noneType();
	const sym = freshTempSym(ctx, "rval", rvalType);
	const tmpDecl = makeVarDecl(sym.name, member.object, DeclKind.Const, loc);
	tmpDecl.resolvedSym = sym;
	tmpDecl.nodeType = rvalType;
	const ref = makeIdentResolved(sym, loc);
	ref.nodeType = rvalType;
	member.object = ref;
	return tmpDecl;
}

function expandBridgeStmt(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer !== null && isAsBytesCallOnRvalue(d.initializer)) {
			return [hoistBridgeReceiver(d.initializer, ctx), stmt];
		}
		return [stmt];
	}
	if (stmt.kind === NodeKind.ExprStmt) {
		const sd = stmt.data as ExprStmtData;
		if (sd.expr !== null && isAsBytesCallOnRvalue(sd.expr)) {
			return [hoistBridgeReceiver(sd.expr, ctx), stmt];
		}
	}
	return [stmt];
}

export function lowerRvalueBridge(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandBridgeStmt, ctx);
	return program;
}

// ===== Entry Point =====

export function lowerRvalue(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerRvalueNode(node, ctx);
	});
}

// ===== Tests =====
test "method on call becomes block" {
	// f().method(); → { const $rval_0 = f(); $rval_0.method(); }
	assert firstStmtKindAfter("f().method();", lowerRvalue) === NodeKind.BlockStmt;
}

test "method on identifier unchanged" {
	// x.method(); → unchanged (x is lvalue)
	assert firstStmtKindAfter("x.method();", lowerRvalue) === NodeKind.ExprStmt;
}

test "method on member unchanged" {
	// a.b.method(); → unchanged (a.b is lvalue)
	assert firstStmtKindAfter("a.b.method();", lowerRvalue) === NodeKind.ExprStmt;
}

test "method on literal becomes block" {
	// [1,2].push(3); → block
	assert firstStmtKindAfter("[1,2].push(3);", lowerRvalue) === NodeKind.BlockStmt;
}

test "plain call unchanged" {
	// f(); → unchanged (not a method call)
	assert firstStmtKindAfter("f();", lowerRvalue) === NodeKind.ExprStmt;
}

test "non-call unchanged" { assert firstStmtKindAfter("x + y;", lowerRvalue) === NodeKind.ExprStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerRvalue) === NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerRvalue) === 2; }
