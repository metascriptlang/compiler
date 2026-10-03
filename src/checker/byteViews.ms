import { Node, NodeKind, Type, TypeKind, TypeAssertionData, HiddenStdConvData, BinaryExprData, ArrayAccessData, UpdateExprData, NumberLiteralData } from "../ast/node";
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

function heldAsObject(t: Type | null): boolean {
	const b = castType(t);
	return b != null && (b.kind == TypeKind.Struct || b.kind == TypeKind.SizedArray || b.kind == TypeKind.Tuple);
}

function isVoid(t: Type | null): boolean {
	const b = castType(t);
	return b != null && b.kind == TypeKind.Void;
}

function pointerCastSupported(source: Type, target: Type, vmObjects: boolean): boolean {
	if (source.kind == TypeKind.Null || sameType(source, target)) return true;
	if (vmObjects && source.kind == TypeKind.Ptr && target.kind == TypeKind.Ptr
		&& ((isVoid(source.typeReturn) && heldAsObject(target.typeReturn)) || (heldAsObject(source.typeReturn) && isVoid(target.typeReturn)))) return true;
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

export function byteViewRefusal(sourceType: Type | null, targetType: Type | null, vmObjects: boolean = false): string {
	const source = castType(sourceType);
	const dest = castType(targetType);
	if (source == null || dest == null) return "";
	if (source.kind != TypeKind.Ptr && dest.kind != TypeKind.Ptr && viewType(dest) == null) return "";
	if (hasGenericParams(source) || hasGenericParams(dest)) return "";
	if (pointerCastSupported(source, dest, vmObjects)) return "";
	return "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(dest);
}

function isPointer(t: Type | null): boolean {
	const b = castType(t);
	return b != null && b.kind == TypeKind.Ptr;
}

function literalZero(node: Node): boolean {
	return node.kind == NodeKind.NumberLiteral && (node.data as NumberLiteralData).value == 0;
}

export function pointerOpRefusal(node: Node): string {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		const op = d.operator;
		const arithmetic = op == "+" || op == "-" || op == "+=" || op == "-=" || op == "<" || op == "<=" || op == ">" || op == ">=";
		if (arithmetic && (isPointer(d.left.nodeType) || isPointer(d.right.nodeType))) return "cannot apply '" + op + "' to a pointer";
	} else if (node.kind == NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		if (isPointer(d.updateArg.nodeType)) return "cannot apply '" + d.updateOp + "' to a pointer";
	} else if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		if (isPointer(d.array.nodeType) && !literalZero(d.index)) return "cannot index a pointer past the element it addresses";
	}
	return "";
}

export const NO_ADDRESS_ARITHMETIC = ": a location there has no address arithmetic; index the Span it came from instead";

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
	const opRefusal = pointerOpRefusal(node);
	if (opRefusal != "") addError(ctx, opRefusal + " on JS" + NO_ADDRESS_ARITHMETIC, node.location.line, node.location.column);
	forEachChild(node, (child: Node): void => { checkNode(ctx, child); });
}

export function refusePointerOpsOnJs(ctx: CheckerContext, program: Node): void {
	checkNode(ctx, program);
}
