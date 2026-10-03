import { Node, NodeKind, Type, TypeKind, TypeAssertionData, HiddenStdConvData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";
import { skipModifier, peelTransparentInstance, typeDisplayName, hasGenericParams } from "./types";
import { sameType, nonNullMemberOfNullable } from "./compat";
import { pointerAddressElement } from "./pointerAddress";

function castType(t: Type | null): Type | null {
	let cur = skipModifier(t);
	if (cur == null) return null;
	const nonNull = nonNullMemberOfNullable(cur);
	if (nonNull != null) cur = nonNull;
	return peelTransparentInstance(cur);
}

function samePointee(a: Type | null, b: Type | null): boolean {
	return a != null && b != null && sameType(a, b);
}

function viewType(t: Type): Type | null {
	if (t.kind == TypeKind.Ref && t.typeReturn != null) t = peelTransparentInstance(t.typeReturn);
	return t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span ? t : null;
}

function pointerCastSupported(source: Type, target: Type): boolean {
	if (source.kind == TypeKind.Null || sameType(source, target)) return true;
	if (pointerAddressElement(source, target) != null) return true;
	const srcView = viewType(source);
	const destView = viewType(target);
	if (destView != null) {
		if (source.kind == TypeKind.String && destView.kind == TypeKind.Span
			&& destView.typeReturn != null && destView.typeReturn.kind == TypeKind.Char) return true;
		return srcView != null && destView.kind == TypeKind.Span && samePointee(srcView.typeReturn, destView.typeReturn);
	}
	if (target.kind == TypeKind.Ptr) {
		const elem = target.typeReturn;
		if (elem == null) return false;
		if (source.kind == TypeKind.Ptr) return samePointee(source.typeReturn, elem);
		if (elem.kind == TypeKind.Void) {
			return source.kind == TypeKind.Ref || source.kind == TypeKind.Struct || source.kind == TypeKind.Unknown;
		}
		if (source.kind == TypeKind.Ref) {
			return samePointee(source, elem) || samePointee(source.typeReturn, elem);
		}
		return false;
	}
	if (source.kind != TypeKind.Ptr) return true;
	if (source.typeReturn != null && source.typeReturn.kind == TypeKind.Void) {
		return target.kind == TypeKind.Ref;
	}
	return target.kind == TypeKind.Ref
		&& (samePointee(source.typeReturn, target) || samePointee(source.typeReturn, target.typeReturn));
}

export function byteViewRefusal(sourceType: Type | null, targetType: Type | null): string {
	const source = castType(sourceType);
	const dest = castType(targetType);
	if (source == null || dest == null) return "";
	if (source.kind != TypeKind.Ptr && dest.kind != TypeKind.Ptr && viewType(dest) == null) return "";
	if (hasGenericParams(source) || hasGenericParams(dest)) return "";
	if (pointerCastSupported(source, dest)) return "";
	return "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(dest);
}

export const NO_BYTE_MEMORY = ": no byte representation or recoverable typed location for this conversion";

function checkPointerCast(ctx: CheckerContext, node: Node, expr: Node, target: Type | null): void {
	const refusal = byteViewRefusal(expr != null ? expr.nodeType : null, target);
	if (refusal != "") addError(ctx, refusal + " on JS" + NO_BYTE_MEMORY, node.location.line, node.location.column);
}

function checkNode(ctx: CheckerContext, node: Node): void {
	if (node == null) return;
	if (node.kind == NodeKind.TypeAssertion) {
		checkPointerCast(ctx, node, (node.data as TypeAssertionData).asExpr, node.nodeType);
	} else if (node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		checkPointerCast(ctx, node, d.convExpr, d.convType);
	}
	forEachChild(node, (child: Node): void => { checkNode(ctx, child); });
}

export function refusePointerCastsOnJs(ctx: CheckerContext, program: Node): void {
	checkNode(ctx, program);
}
