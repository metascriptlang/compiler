import { Node, NodeKind, Type, TypeKind, ArrayAccessData, createNodeAt } from "../ast/node";
import { skipModifier, peelTransparentInstance, typeDisplayName } from "./types";
import { sameType, nonNullMemberOfNullable } from "./compat";
import { CheckerContext, addError } from "./context";
import { writeRefusal } from "./assignable";

export function pointerAddressElement(source: Type | null, target: Type | null): Type | null {
	let src = skipModifier(source);
	let dest = skipModifier(target);
	if (src == null || dest == null) return null;
	const nonNull = nonNullMemberOfNullable(dest);
	if (nonNull != null) dest = nonNull;
	src = peelTransparentInstance(src);
	dest = peelTransparentInstance(dest);
	if (dest.kind != TypeKind.Ptr || dest.typeReturn == null) return null;
	if (src.kind == TypeKind.Ref || src.kind == TypeKind.Ptr || src.kind == TypeKind.Null) return null;
	if (src.kind == TypeKind.Span) {
		const elem = skipModifier(src.typeReturn);
		if (elem != null && (elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr)) return null;
		return src.typeReturn != null && sameType(src.typeReturn, dest.typeReturn) ? src.typeReturn : null;
	}
	return sameType(src, dest.typeReturn) ? src : null;
}


export function checkPointerAddress(ctx: CheckerContext, expr: Node, target: Type): void {
	const source = skipModifier(expr.nodeType);
	const dest = skipModifier(target);
	if (source != null && source.kind == TypeKind.Span && source.typeReturn != null
		&& dest != null && dest.kind == TypeKind.Ptr && dest.typeReturn != null
		&& sameType(source.typeReturn, dest.typeReturn)) {
		const elem = skipModifier(source.typeReturn);
		if (elem != null && (elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr)) {
			addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(dest)
				+ ": the view stores reference slots, but this pointer type addresses their pointees", expr.location.line, expr.location.column);
			return;
		}
	}
	if (pointerAddressElement(expr.nodeType, target) == null) return;
	let place = expr;
	const src = skipModifier(expr.nodeType);
	if (src != null && peelTransparentInstance(src).kind == TypeKind.Span) {
		const index = createNodeAt(NodeKind.NumberLiteral, { value: 0, isFloat: false, intVal: 0 as int64, outOfRangeText: "", isBitPattern: false }, expr.location);
		place = createNodeAt(NodeKind.ArrayAccess, { array: expr, index } as ArrayAccessData, expr.location);
	} else if (expr.kind != NodeKind.Identifier && expr.kind != NodeKind.MemberExpr
		&& expr.kind != NodeKind.ArrayAccess && expr.kind != NodeKind.HiddenDeref) {
		addError(ctx, "cannot take a typed pointer: expression has no address", expr.location.line, expr.location.column);
		return;
	}
	const refusal = writeRefusal(place, true);
	if (refusal != "") addError(ctx, refusal, expr.location.line, expr.location.column);
}
