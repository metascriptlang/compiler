import { Node, NodeKind, Type, TypeKind, ArrayAccessData, createNodeAt } from "../ast/node";
import { skipModifier, peelTransparentInstance, typeDisplayName, isNumeric, isReadonlyView, createReadonlyView } from "./types";
import { sameType, nonNullMemberOfNullable } from "./compat";
import { CheckerContext, addError } from "./context";
import { writeRefusal } from "./assignable";

function pointee(target: Type | null): Type | null {
	let dest = skipModifier(target);
	if (dest == null) return null;
	const nonNull = nonNullMemberOfNullable(dest);
	if (nonNull != null) dest = nonNull;
	dest = peelTransparentInstance(dest);
	return dest.kind == TypeKind.Ptr ? dest.typeReturn : null;
}

function bareSource(source: Type | null): Type | null {
	const src = skipModifier(source);
	return src != null ? peelTransparentInstance(src) : null;
}

function storedInline(t: Type): boolean {
	return isNumeric(t) || t.kind == TypeKind.Boolean || t.kind == TypeKind.Char || t.kind == TypeKind.Enum
		|| t.kind == TypeKind.Struct || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Tuple;
}

export function pointerAddressElement(source: Type | null, target: Type | null): Type | null {
	const src = bareSource(source);
	const elem = pointee(target);
	if (src == null || elem == null) return null;
	if (src.kind == TypeKind.Ref || src.kind == TypeKind.Ptr || src.kind == TypeKind.Null) return null;
	if (src.kind == TypeKind.Span) {
		const item = skipModifier(src.typeReturn);
		if (item != null && (item.kind == TypeKind.Ref || item.kind == TypeKind.Ptr)) return null;
		return src.typeReturn != null && sameType(src.typeReturn, elem) ? src.typeReturn : null;
	}
	return sameType(src, elem) ? src : null;
}

export function nativeAddressSource(source: Type | null, target: Type | null): Type | null {
	const src = bareSource(source);
	const elem = pointee(target);
	if (src == null || elem == null || pointerAddressElement(source, target) != null) return null;
	if (src.kind == TypeKind.Ptr) return sameType(src, elem) ? src : null;
	return storedInline(src) ? src : null;
}

export function checkPointerAddress(ctx: CheckerContext, node: Node, expr: Node, target: Type): void {
	const source = bareSource(expr.nodeType);
	const dest = bareSource(target);
	if (source != null && dest != null && dest.kind == TypeKind.Span && dest.typeReturn != null) {
		let view = source;
		if (view.kind == TypeKind.Ref && view.typeReturn != null) view = peelTransparentInstance(view.typeReturn);
		if ((view.kind == TypeKind.Span || view.kind == TypeKind.Array || view.kind == TypeKind.SizedArray)
			&& view.typeReturn != null && !sameType(view.typeReturn, dest.typeReturn)) {
			addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
				+ ": a view keeps its element type; read bytes through `as Ptr<void> as Ptr<uint8>` on a native target", expr.location.line, expr.location.column);
		}
		return;
	}
	const elem = pointee(target);
	if (source == null || elem == null) return;
	if (source.kind == TypeKind.Span && source.typeReturn != null && sameType(source.typeReturn, elem)) {
		const item = skipModifier(source.typeReturn);
		if (item != null && item.kind == TypeKind.Ref) {
			addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
				+ ": the view stores reference slots, but this pointer type addresses their pointees", expr.location.line, expr.location.column);
			return;
		}
	}
	let handle = source;
	if (handle.kind == TypeKind.Ref && handle.typeReturn != null) handle = peelTransparentInstance(handle.typeReturn);
	if ((handle.kind == TypeKind.Array || handle.kind == TypeKind.String) && !sameType(source, elem) && elem.kind != TypeKind.Void) {
		addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
			+ ": a " + typeDisplayName(source) + " is a handle to heap storage, so its address holds no "
			+ typeDisplayName(elem) + "; reach its elements through `as Span<…>` first", expr.location.line, expr.location.column);
		return;
	}
	const element = pointerAddressElement(expr.nodeType, target);
	if (element == null && nativeAddressSource(expr.nodeType, target) == null) return;
	let place = expr;
	if (element != null && source.kind == TypeKind.Span) {
		const index = createNodeAt(NodeKind.NumberLiteral, { value: 0, isFloat: false, intVal: 0 as int64, outOfRangeText: "", isBitPattern: false }, expr.location);
		place = createNodeAt(NodeKind.ArrayAccess, { array: expr, index } as ArrayAccessData, expr.location);
	} else if (expr.kind != NodeKind.Identifier && expr.kind != NodeKind.MemberExpr
		&& expr.kind != NodeKind.ArrayAccess && expr.kind != NodeKind.HiddenDeref) {
		addError(ctx, "cannot take a typed pointer: expression has no address", expr.location.line, expr.location.column);
		return;
	}
	const refusal = writeRefusal(place, true);
	if (refusal == "" || node.nodeType == null || isReadonlyView(node.nodeType)) return;
	const view = createReadonlyView(node.nodeType);
	if (isReadonlyView(view)) {
		node.nodeType = view;
		return;
	}
	addError(ctx, refusal, expr.location.line, expr.location.column);
}
