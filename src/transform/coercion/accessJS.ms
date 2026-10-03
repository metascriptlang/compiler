import { Node, NodeKind, ArrayAccessData, BinaryExprData, UpdateExprData, MemberExprData, SpreadExprData, CallExprData, SourceLocation, Type, TypeKind, DeclKind } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext, freshTempSym } from "../context";
import { addError } from "../../checker/context";
import { peelTransparentInstance, unknownType } from "../../checker/types";
import { walkNode, walkExpandBlocks, isAssignOp } from "../walker";
import { makeBinary, makeCall, makeMember, makeArrayAccess, makeAssign, makeVarDecl, makeNull, makeIdentResolved, runtimeRef, isRuntimeProcCall } from "../util";
import { cloneIfPure } from "./intArithJS";
import { asUnknown } from "./nullishCoalesce";

export function lowerAccessJS(program: Node, ctx: TransformContext): Node {
	const lowered = walkNode(program, (node: Node): Node => rewriteAccess(node));
	walkExpandBlocks(lowered, (stmt: Node, c: TransformContext): Node[] => holdPlacesStmt(stmt, c), ctx);
	return walkNode(lowered, (node: Node): Node => refuseUnheldPlace(node, ctx));
}

function rewriteAccess(node: Node): Node {
	if (node.kind == NodeKind.ArrayAccess) return checkedAccess(node);
	if (node.kind == NodeKind.MemberExpr) return spanLength(node);
	if (node.kind == NodeKind.SpreadExpr) return spreadSpanValues(node);
	return node;
}

function holdPlacesStmt(stmt: Node, ctx: TransformContext): Node[] {
	const temps: Node[] = [];
	holdPlaces(stmt, temps, ctx);
	temps.push(stmt);
	return temps;
}

function holdPlaces(node: Node, temps: Node[], ctx: TransformContext): void {
	if (node == null) return;
	forEachChild(node, (c: Node): void => {
		if (c == null) return;
		const k = c.kind;
		if (k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr || k == NodeKind.FunctionDecl
			|| k == NodeKind.MethodDecl || k == NodeKind.ConstructorDecl || k == NodeKind.BlockStmt) return;
		holdPlaces(c, temps, ctx);
	});
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) d.left = heldPlace(d.left, temps, ctx);
	} else if (node.kind == NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		d.updateArg = heldPlace(d.updateArg, temps, ctx);
	}
}

function heldPlace(target: Node, temps: Node[], ctx: TransformContext): Node {
	const span = isRuntimeProcCall(target, "msSpanAt");
	if (!span && !isRuntimeProcCall(target, "msArrayAt")) return target;
	const args = (target.data as CallExprData).arguments;
	const loc = target.location;
	const held = args[0];
	const sym = freshTempSym(ctx, "place", unknownType());
	const decl = makeVarDecl(sym.name, makeNull(loc), DeclKind.Var, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	temps.push(decl);
	const first = makeAssign(makeIdentResolved(sym, loc), asUnknown(held, loc), loc);
	first.nodeType = sym.symbolType;
	const place = span
		? makeArrayAccess(makeMember(first, "base", loc), makeBinary(makeMember(makeIdentResolved(sym, loc), "off", loc), "+", checkedIndex(args[1], makeMember(makeIdentResolved(sym, loc), "len", loc), loc), loc), loc)
		: makeArrayAccess(first, checkedIndex(args[1], makeMember(makeIdentResolved(sym, loc), "length", loc), loc), loc);
	place.nodeType = target.nodeType;
	return place;
}

function refuseUnheldPlace(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) refuseReadOnlyPlace(d.left, ctx);
	} else if (node.kind == NodeKind.UpdateExpr) {
		refuseReadOnlyPlace((node.data as UpdateExprData).updateArg, ctx);
	}
	return node;
}

export function indexedType(arr: Node): Type | null {
	if (arr.nodeType == null) return null;
	let t = peelTransparentInstance(arr.nodeType);
	if (t.kind == TypeKind.Ref && t.typeReturn != null) t = peelTransparentInstance(t.typeReturn);
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span) return t;
	return null;
}

function isSpan(arr: Node): boolean {
	const t = indexedType(arr);
	return t != null && t.kind == TypeKind.Span;
}

function spanLength(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property == "length" && isSpan(d.object)) d.property = "len";
	return node;
}

function spreadSpanValues(node: Node): Node {
	const d = node.data as SpreadExprData;
	if (!isSpan(d.spreadArg)) return node;
	d.spreadArg = makeCall(runtimeRef("msSpanValues", node.location), [d.spreadArg], node.location);
	return node;
}

function isRange(index: Node): boolean {
	if (index.kind != NodeKind.BinaryExpr) return false;
	const op = (index.data as BinaryExprData).operator;
	return op == ".." || op == "...";
}

function checkedIndex(index: Node, len: Node, loc: SourceLocation): Node {
	return makeCall(runtimeRef("msChkIndex", loc), [index, len], loc);
}

function checkedSpanPlace(view: Node, index: Node, loc: SourceLocation): Node | null {
	const lenView = cloneIfPure(view);
	const offView = cloneIfPure(view);
	if (lenView == null || offView == null) return null;
	const at = makeBinary(makeMember(offView, "off", loc), "+", checkedIndex(index, makeMember(lenView, "len", loc), loc), loc);
	return makeArrayAccess(makeMember(view, "base", loc), at, loc);
}

function checkedArrayPlace(arr: Node, index: Node, loc: SourceLocation): Node | null {
	const arrAgain = cloneIfPure(arr);
	if (arrAgain != null) return makeArrayAccess(arr, checkedIndex(index, makeMember(arrAgain, "length", loc), loc), loc);
	const indexAgain = cloneIfPure(index);
	if (indexAgain == null) return null;
	const arrChecked = makeCall(runtimeRef("msChkArray", loc), [arr, index], loc);
	arrChecked.nodeType = arr.nodeType;
	return makeArrayAccess(arrChecked, indexAgain, loc);
}

function checkedAccess(node: Node): Node {
	const d = node.data as ArrayAccessData;
	if (isRange(d.index) || indexedType(d.array) == null) return node;
	const loc = node.location;
	const span = isSpan(d.array);
	let access = span ? checkedSpanPlace(d.array, d.index, loc) : checkedArrayPlace(d.array, d.index, loc);
	if (access == null) access = makeCall(runtimeRef(span ? "msSpanAt" : "msArrayAt", loc), [d.array, d.index], loc);
	access.nodeType = node.nodeType;
	return access;
}

function refuseReadOnlyPlace(target: Node, ctx: TransformContext): void {
	if (!isRuntimeProcCall(target, "msArrayAt") && !isRuntimeProcCall(target, "msSpanAt")) return;
	if (ctx.checkerCtx == null) return;
	const loc = target.location;
	addError(ctx.checkerCtx, "a write to an element needs its array or its index read twice to check the bound; hoist the array or the index into a local first", loc.line, loc.column);
}
