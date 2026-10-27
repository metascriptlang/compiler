// The zero-copy `asBytes` bridge emits `((msUint8Array*)&(receiver))`, so the receiver must be
// addressable in C: an rvalue receiver is hoisted into a peer temp statement. The splice is
// flat because a block would scope the temp away from the statements that follow.

import { Node, NodeKind, DeclKind, CallExprData, MemberExprData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { noneType } from "../../checker/types";
import { walkExpandBlocks } from "../walker";
import { hoistStmtValue } from "../blockExpand";
import { makeVarDecl, makeIdentResolved } from "../util";

function isRvalue(node: Node): boolean {
	return match (node.kind) {
		NodeKind.CallExpr | NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BinaryExpr | NodeKind.UnaryExpr | NodeKind.ArrayLiteral
			| NodeKind.ObjectLiteral | NodeKind.ConditionalExpr => true,
		_ => false,
	};
}

function isAsBytesCallOnRvalue(expr: Node): boolean {
	if (expr.kind != NodeKind.CallExpr) return false;
	const call = expr.data as CallExprData;
	if (call.callee.kind != NodeKind.MemberExpr) return false;
	if (call.callee.resolvedSym == null || call.callee.resolvedSym.builtinKind != "AsBytes") return false;
	return isRvalue((call.callee.data as MemberExprData).object);
}

function hoistBridgeReceiver(value: Node, pre: Node[], ctx: TransformContext): Node {
	if (!isAsBytesCallOnRvalue(value)) return value;
	const member = (value.data as CallExprData).callee.data as MemberExprData;
	const loc = value.location;
	const rvalType = member.object.nodeType != null ? member.object.nodeType : noneType();
	const sym = freshTempSym(ctx, "rval", rvalType);
	const tmpDecl = makeVarDecl(sym.name, member.object, DeclKind.Const, loc);
	tmpDecl.resolvedSym = sym;
	tmpDecl.nodeType = rvalType;
	const ref = makeIdentResolved(sym, loc);
	ref.nodeType = rvalType;
	member.object = ref;
	pre.push(tmpDecl);
	return value;
}

function expandBridgeStmt(stmt: Node, ctx: TransformContext): Node[] {
	return match (stmt.kind) {
		NodeKind.VariableDecl | NodeKind.ExprStmt => hoistStmtValue(stmt, hoistBridgeReceiver, ctx),
		_ => [stmt],
	};
}

export function lowerRvalueBridge(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandBridgeStmt, ctx);
	return program;
}
