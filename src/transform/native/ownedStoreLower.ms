// A store into an Owned<T> field checks the single-owner rule before it happens:
// `h.f = v` becomes `msOwnedReplace(h.f, v, h); h.f = v;`. The check is a statement beside the
// unchanged store, never a call around `v`: the analyzer reads a call result as a fresh value and
// would drop the count a live `v` still needs. A holder or value that is not a plain place is bound
// to a local first, holder before value, so each is evaluated once and in source order.
// `move h.f` empties the slot, so the moved value leaves its owner: `msOwnedTake(move h.f)`, a sink
// that hands the same value back.

import { Node, NodeKind, Type, TypeKind, BinaryExprData, MemberExprData, HiddenDerefData, HiddenStdConvData, ExprStmtData, ArrayAccessData, MoveExprData } from "../../ast/node";
import { TransformContext, freshOwnedSym } from "../context";
import { mapChildren } from "../walker";
import { makeCall, runtimeRef, makeBlock, makeExprStmt, makeLocalDecl, makeIdentResolved, makeNull } from "../util";
import { ownedSlotOf, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { isAssignOp } from "../../ast/operators";
import { cloneNodeKeepSem } from "../../monomorphize/clone";

let _ctx: TransformContext | null = null;

function isOwnedStore(n: Node): boolean {
	return n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator) && ownedSlotOf((n.data as BinaryExprData).left);
}

function visit(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.GeneratedOp)) return node;
	if (node.kind == NodeKind.ExprStmt && isOwnedStore((node.data as ExprStmtData).expr)) return checkStore(node);
	if (isOwnedStore(node)) throw new Error(`internal: an owned field store '${(node.data as BinaryExprData).operator}' reached lowerOwnedStores outside a statement`);
	mapChildren(node, visit);
	if (node.kind == NodeKind.MoveExpr && ownedSlotOf((node.data as MoveExprData).moveArg)) return release(node);
	return node;
}

function release(moved: Node): Node {
	const call = makeCall(runtimeRef("msOwnedTake", moved.location), [moved], moved.location);
	call.nodeType = moved.nodeType;
	return call;
}

function isPlainPlace(n: Node): boolean {
	return match (n.kind) {
		NodeKind.Identifier | NodeKind.NullLiteral => true,
		NodeKind.MemberExpr => !(n.data as MemberExprData).isOptional && isPlainPlace((n.data as MemberExprData).object),
		NodeKind.ArrayAccess => isPlainPlace((n.data as ArrayAccessData).array) && ((n.data as ArrayAccessData).index.kind == NodeKind.NumberLiteral || isPlainPlace((n.data as ArrayAccessData).index)),
		NodeKind.HiddenDeref => isPlainPlace((n.data as HiddenDerefData).expr),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => isPlainPlace((n.data as HiddenStdConvData).convExpr),
		_ => false,
	};
}

function isRef(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Ref;
}

function isStableName(n: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && !hasFlag(n.resolvedSym, SymbolFlag.Mutable);
}

function bind(value: Node, prefix: string, stmts: Node[]): Node {
	const sym = freshOwnedSym(_ctx!, prefix, value.nodeType);
	stmts.push(makeLocalDecl(sym, value, value.nodeType!, value.location));
	return makeIdentResolved(sym, value.location);
}

function checkStore(stmt: Node): Node {
	const store = (stmt.data as ExprStmtData).expr;
	const d = store.data as BinaryExprData;
	if (d.operator != "=") throw new Error(`internal: an owned field store '${d.operator}' reached lowerOwnedStores unlowered`);
	mapChildren(store, visit);
	const loc = store.location;
	const md = d.left.data as MemberExprData;
	const deref = md.object.kind == NodeKind.HiddenDeref ? md.object : null;
	const holder = deref != null ? (deref.data as HiddenDerefData).expr : md.object;
	const holdsWord = isRef(holder.nodeType);
	if (!holdsWord && !isPlainPlace(md.object)) throw new Error(`internal: an owned field of a value held at a computed place reached lowerOwnedStores; bind the holder first`);
	const stmts: Node[] = [];
	const bindValue = !isPlainPlace(d.right);
	if (holdsWord && (!isPlainPlace(holder) || (bindValue && !isStableName(holder)))) {
		const bound = bind(holder, "ownedHolder", stmts);
		if (deref != null) (deref.data as HiddenDerefData).expr = bound;
		else md.object = bound;
	}
	if (bindValue) d.right = bind(d.right, "ownedValue", stmts);
	const holderArg = holdsWord ? cloneNodeKeepSem(deref != null ? (deref.data as HiddenDerefData).expr : md.object) : makeNull(loc);
	const check = makeCall(runtimeRef("msOwnedReplace", loc), [cloneNodeKeepSem(d.left), cloneNodeKeepSem(d.right), holderArg], loc);
	check.nodeType = voidType();
	stmts.push(makeExprStmt(check, loc));
	stmts.push(stmt);
	return makeBlock(stmts, loc);
}

export function lowerOwnedStores(program: Node, ctx: TransformContext): Node {
	if (ctx.raiserBackend) return program;
	_ctx = ctx;
	mapChildren(program, visit);
	_ctx = null;
	return program;
}
