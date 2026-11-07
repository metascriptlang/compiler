// A store into an Owned<T> slot checks the single-owner rule before it happens: `h.f = v` becomes
// `msOwnedReplace(h.f, v, h); h.f = v;`, `h.kids[i] = v` the same with the element, and
// `h.kids.push(v)` becomes `msOwnedAdopt(v, h); h.kids.push(v);`. The check is a statement beside the
// unchanged store, never a call around `v`: the analyzer reads a call result as a fresh value and
// would drop the count a live `v` still needs. The holder is the nearest object on the slot's path
// (`h.rec.f` and `h.kids[i]` belong to `h`); a slot no object holds passes none. A holder or value
// that is not a plain place is bound to a local first, holder before value, so each is evaluated
// once; a plain-place holder is read again, as the unchecked store reads it. A value leaving its slot leaves its owner: `move h.f` and `h.kids.pop()`
// become `msOwnedTake(...)`, a sink that hands the same value back.

import { Node, NodeKind, Type, TypeKind, BinaryExprData, MemberExprData, HiddenDerefData, HiddenStdConvData, ExprStmtData, ArrayAccessData, MoveExprData, CallExprData, SourceLocation } from "../../ast/node";
import { TransformContext, freshOwnedSym } from "../context";
import { mapChildren } from "../walker";
import { makeCall, runtimeRef, makeBlock, makeExprStmt, makeLocalDecl, makeIdentResolved, makeNull } from "../util";
import { ownedSlotOf, ownedElementOf, withoutOwned, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { isAssignOp } from "../../ast/operators";
import { cloneNodeKeepSem } from "../../monomorphize/clone";

let _ctx: TransformContext | null = null;

interface Site {
	node: Node;
	set: (n: Node) => void;
}

function isOwnedStore(n: Node): boolean {
	return n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator) && ownedSlotOf((n.data as BinaryExprData).left);
}

function elementCall(n: Node, native: string): boolean {
	if (n.kind != NodeKind.CallExpr) return false;
	const sym = n.resolvedSym != null ? n.resolvedSym : (n.data as CallExprData).callee.resolvedSym;
	if (sym == null || (sym.nativeName.startsWith("&") ? sym.nativeName.slice(1) : sym.nativeName) != native) return false;
	const recv = receiverSite(n);
	return recv != null && ownedElementOf(recv.node.nodeType) != null;
}

function visit(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.GeneratedOp)) return node;
	if (node.kind == NodeKind.ExprStmt) {
		const e = (node.data as ExprStmtData).expr;
		if (isOwnedStore(e)) return checkStore(node);
		if (elementCall(e, "msGenericArrayPush")) return checkPush(node);
	}
	if (isOwnedStore(node)) throw new Error(`internal: an owned store '${(node.data as BinaryExprData).operator}' reached lowerOwnedStores outside a statement`);
	if (elementCall(node, "msGenericArrayPush")) throw new Error(`internal: a push of an owned element reached lowerOwnedStores outside a statement`);
	mapChildren(node, visit);
	if (node.kind == NodeKind.MoveExpr && ownedSlotOf((node.data as MoveExprData).moveArg)) return take(node);
	if (elementCall(node, "msGenericArrayPop")) return take(node);
	return node;
}

function take(left: Node): Node {
	const call = makeCall(runtimeRef("msOwnedTake", left.location), [left], left.location);
	call.nodeType = left.nodeType;
	return call;
}

function isPlainPlace(n: Node): boolean {
	return match (n.kind) {
		NodeKind.Identifier | NodeKind.NullLiteral => true,
		NodeKind.MemberExpr => !(n.data as MemberExprData).isOptional && isPlainPlace((n.data as MemberExprData).object),
		NodeKind.ArrayAccess => isPlainPlace((n.data as ArrayAccessData).array) && ((n.data as ArrayAccessData).index.kind == NodeKind.NumberLiteral || isPlainPlace((n.data as ArrayAccessData).index)),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => isPlainPlace((n.data as HiddenDerefData).expr),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => isPlainPlace((n.data as HiddenStdConvData).convExpr),
		_ => false,
	};
}

function objectSite(site: Site): Site | null {
	const n = site.node;
	if (n.kind == NodeKind.HiddenDeref || n.kind == NodeKind.HiddenAddr) {
		const d = n.data as HiddenDerefData;
		return n.kind == NodeKind.HiddenDeref && d.expr.nodeType != null && d.expr.nodeType.kind == TypeKind.Ref
			? { node: d.expr, set: (x: Node): void => { d.expr = x; } }
			: objectSite({ node: d.expr, set: (x: Node): void => { d.expr = x; } });
	}
	if (n.nodeType != null && n.nodeType.kind == TypeKind.Ref) return site;
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		return objectSite({ node: d.object, set: (x: Node): void => { d.object = x; } });
	}
	return null;
}

function receiverSite(call: Node): Site | null {
	const d = call.data as CallExprData;
	if (d.callee.kind == NodeKind.MemberExpr) {
		const md = d.callee.data as MemberExprData;
		return { node: md.object, set: (x: Node): void => { md.object = x; } };
	}
	if (d.arguments.length == 0) return null;
	const first = d.arguments[0];
	if (first.kind == NodeKind.HiddenAddr) {
		const hd = first.data as HiddenDerefData;
		return { node: hd.expr, set: (x: Node): void => { hd.expr = x; } };
	}
	return { node: first, set: (x: Node): void => { d.arguments[0] = x; } };
}

function bind(value: Node, prefix: string, stmts: Node[]): Node {
	const sym = freshOwnedSym(_ctx!, prefix, value.nodeType);
	stmts.push(makeLocalDecl(sym, value, value.nodeType!, value.location));
	return makeIdentResolved(sym, value.location);
}

// `container` is what holds the slot (the field's object, the element's array); `value` the stored value.
function guard(stmt: Node, container: Site, value: Site, replaced: Node | null, loc: SourceLocation): Node {
	const holder = objectSite(container);
	if (holder == null && !isPlainPlace(container.node)) throw new Error(`internal: an owned slot of a value held at a computed place reached lowerOwnedStores; bind the holder first`);
	const stmts: Node[] = [];
	const bindValue = !isPlainPlace(value.node);
	if (holder != null && !isPlainPlace(holder.node)) {
		holder.node.nodeType = withoutOwned(holder.node.nodeType!);
		const bound = bind(holder.node, "ownedHolder", stmts);
		holder.set(bound);
		holder.node = bound;
	}
	if (bindValue) {
		const bound = bind(value.node, "ownedValue", stmts);
		value.set(bound);
		value.node = bound;
	}
	const holderArg = holder != null ? cloneNodeKeepSem(holder.node) : makeNull(loc);
	const check = replaced != null
		? makeCall(runtimeRef("msOwnedReplace", loc), [cloneNodeKeepSem(replaced), cloneNodeKeepSem(value.node), holderArg], loc)
		: makeCall(runtimeRef("msOwnedAdopt", loc), [cloneNodeKeepSem(value.node), holderArg], loc);
	check.nodeType = voidType();
	stmts.push(makeExprStmt(check, loc));
	stmts.push(stmt);
	return makeBlock(stmts, loc);
}

function checkStore(stmt: Node): Node {
	const store = (stmt.data as ExprStmtData).expr;
	const d = store.data as BinaryExprData;
	if (d.operator != "=") throw new Error(`internal: an owned store '${d.operator}' reached lowerOwnedStores unlowered`);
	mapChildren(store, visit);
	const value: Site = { node: d.right, set: (x: Node): void => { d.right = x; } };
	if (d.left.kind == NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		return guard(stmt, { node: ad.array, set: (x: Node): void => { ad.array = x; } }, value, d.left, store.location);
	}
	const md = d.left.data as MemberExprData;
	return guard(stmt, { node: md.object, set: (x: Node): void => { md.object = x; } }, value, d.left, store.location);
}

function checkPush(stmt: Node): Node {
	const call = (stmt.data as ExprStmtData).expr;
	mapChildren(call, visit);
	const args = (call.data as CallExprData).arguments;
	const at = args.length - 1;
	return guard(stmt, receiverSite(call)!, { node: args[at], set: (x: Node): void => { args[at] = x; } }, null, call.location);
}

export function lowerOwnedStores(program: Node, ctx: TransformContext): Node {
	if (ctx.raiserBackend) return program;
	_ctx = ctx;
	mapChildren(program, visit);
	_ctx = null;
	return program;
}
