import { Node, NodeKind, ArrayAccessData, BinaryExprData, UpdateExprData, MemberExprData, SpreadExprData, SourceLocation, Type, TypeKind, TypeFlag, DeclKind, ExprStmtData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { addError } from "../../checker/context";
import { peelTransparentInstance, distinctBody } from "../../checker/types";
import { walkNode, walkExpandBlocks, isAssignOp } from "../walker";
import { makeBinary, makeCall, makeMember, makeArrayAccess, runtimeRef, isRuntimeProcCall, makeVarDecl, makeIdentResolved, makeExprStmt } from "../util";
import { cloneIfPure } from "./intArithJS";

export function lowerAccessJS(program: Node, ctx: TransformContext): Node {
	stabilizeElementPlaces(program, ctx);
	return walkNode(program, (node: Node): Node => rewriteAccess(node, ctx));
}


function rewriteAccess(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.ArrayAccess) return checkedAccess(node);
	if (node.kind == NodeKind.MemberExpr) return spanLength(node);
	if (node.kind == NodeKind.SpreadExpr) return spreadSpanValues(node);
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) refuseReadOnlyPlace(d.left, ctx);
		return node;
	}
	if (node.kind == NodeKind.UpdateExpr) refuseReadOnlyPlace((node.data as UpdateExprData).updateArg, ctx);
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


// Destination parts are evaluated once, as Nim does before a store
// (injectdestructors.nim stabilizeBracketIndex): a clone re-runs effects, and
// an array hoisted into a temp initializer becomes a detached value copy.
function stabilizeElementPlaces(program: Node, ctx: TransformContext): void {
	walkExpandBlocks(program, (stmt: Node): Node[] => stabilizeStmt(stmt, ctx), ctx);
}

function stabilizeStmt(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind != NodeKind.ExprStmt) return [stmt];
	const ed = stmt.data as ExprStmtData;
	if (ed.expr == null || ed.expr.kind != NodeKind.BinaryExpr) return [stmt];
	const bd = ed.expr.data as BinaryExprData;
	if (bd.operator != "=" || bd.left.kind != NodeKind.ArrayAccess || isRange((bd.left.data as ArrayAccessData).index)) return [stmt];
	const ad = bd.left.data as ArrayAccessData;
	if (indexedType(ad.array) == null) return [stmt];
	const loc = bd.left.location;
	if (isSpan(ad.array)) {
		if (cloneIfPure(ad.array) != null) return [stmt];
		const sym = freshTempSym(ctx, "rcdst", ad.array.nodeType);
		const decl = makeVarDecl(sym.name, ad.array, DeclKind.Const, loc);
		decl.resolvedSym = sym;
		ad.array = makeIdentResolved(sym, loc);
		return [decl, stmt];
	}
	if (cloneIfPure(ad.array) != null || cloneIfPure(ad.index) != null) return [stmt];
	if (elementIsValueJS(bd.left.nodeType)) return [stmt];
	const store = makeCall(runtimeRef("msChkStore", loc), [ad.array, ad.index, bd.right], loc);
	store.nodeType = bd.right.nodeType;
	return [makeExprStmt(store, loc)];
}

// Mirrors needsValueCopy in codegen/js/valueCopy.ms, the authority: a
// value-typed element stores through msValAssign at emission, never through
// msChkStore, which would alias the stored value instead of copying it in.
function elementIsValueJS(t: Type | null): boolean {
	let base = distinctBody(t);
	while (base != null) {
		t = base;
		base = distinctBody(t);
	}
	if (t != null && t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe) && t.typeReturn != null) t = t.typeReturn;
	if (t == null) return false;
	if (t.kind == TypeKind.Struct) return t.typeFlags.has(TypeFlag.IsStruct);
	return t.kind == TypeKind.Tuple || t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray;
}

function refuseReadOnlyPlace(target: Node, ctx: TransformContext): void {
	if (!isRuntimeProcCall(target, "msArrayAt") && !isRuntimeProcCall(target, "msSpanAt")) return;
	if (ctx.checkerCtx == null) return;
	const loc = target.location;
	addError(ctx.checkerCtx, "a write to an element needs its array or its index read twice to check the bound; hoist the array or the index into a local first", loc.line, loc.column);
}
