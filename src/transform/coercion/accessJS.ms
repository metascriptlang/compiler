import { Node, NodeKind, ArrayAccessData, BinaryExprData, UpdateExprData, CallExprData, MemberExprData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { addError } from "../../checker/context";
import { peelTransparentInstance } from "../../checker/types";
import { walkNode, isAssignOp } from "../walker";
import { makeBinary, makeCall, makeMember, makeArrayAccess, runtimeRef, isRuntimeProcCall } from "../util";
import { cloneIfPure } from "./intArithJS";

export function lowerAccessJS(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => rewriteAccess(node, ctx));
}

function rewriteAccess(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.ArrayAccess) return checkedRead(node);
	if (node.kind == NodeKind.MemberExpr) return spanLength(node);
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator)) d.left = checkedPlace(d.left, ctx);
		return node;
	}
	if (node.kind == NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		d.updateArg = checkedPlace(d.updateArg, ctx);
	}
	return node;
}

function indexedType(arr: Node): Type | null {
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

function isRange(index: Node): boolean {
	if (index.kind != NodeKind.BinaryExpr) return false;
	const op = (index.data as BinaryExprData).operator;
	return op == ".." || op == "...";
}

function checkedRead(node: Node): Node {
	const d = node.data as ArrayAccessData;
	if (isRange(d.index) || indexedType(d.array) == null) return node;
	const helper = isSpan(d.array) ? "msSpanAt" : "msArrayAt";
	const read = makeCall(runtimeRef(helper, node.location), [d.array, d.index], node.location);
	read.nodeType = node.nodeType;
	return read;
}

function refuseWrite(ctx: TransformContext, loc: SourceLocation): void {
	if (ctx.checkerCtx == null) return;
	addError(ctx.checkerCtx, "a write to an element needs its array or its index read twice to check the bound; hoist the array or the index into a local first", loc.line, loc.column);
}

function checkedPlace(target: Node, ctx: TransformContext): Node {
	const span = isRuntimeProcCall(target, "msSpanAt");
	if (!span && !isRuntimeProcCall(target, "msArrayAt")) return target;
	const args = (target.data as CallExprData).arguments;
	const arr = args[0];
	const index = args[1];
	const loc = target.location;
	let place: Node;
	const arrAgain = cloneIfPure(arr);
	if (span) {
		const viewAgain = cloneIfPure(arr);
		if (arrAgain == null || viewAgain == null) {
			refuseWrite(ctx, loc);
			return target;
		}
		const checked = makeCall(runtimeRef("msChkIndex", loc), [index, makeMember(arrAgain, "len", loc)], loc);
		place = makeArrayAccess(makeMember(arr, "base", loc), makeBinary(makeMember(viewAgain, "off", loc), "+", checked, loc), loc);
	} else if (arrAgain != null) {
		const len = makeMember(arrAgain, "length", loc);
		place = makeArrayAccess(arr, makeCall(runtimeRef("msChkIndex", loc), [index, len], loc), loc);
	} else {
		const indexAgain = cloneIfPure(index);
		if (indexAgain == null) {
			refuseWrite(ctx, loc);
			return target;
		}
		const arrChecked = makeCall(runtimeRef("msChkArray", loc), [arr, index], loc);
		arrChecked.nodeType = arr.nodeType;
		place = makeArrayAccess(arrChecked, indexAgain, loc);
	}
	place.nodeType = target.nodeType;
	return place;
}
