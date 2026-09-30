import { Node, NodeKind, Type, TypeKind, TypeAssertionData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";
import { skipModifier, typeDisplayName } from "./types";
import { sameType } from "./compat";

export const SPAN_BYTE_CAST_MSG: string = "reads raw bytes on C, but the JS backend has no byte representation — read elements with view[i] or cast to the same element type";

function spanElementOf(t: Type | null): Type | null {
	let cur = skipModifier(t);
	if (cur == null) return null;
	if (cur.kind == TypeKind.Ref && cur.typeReturn != null) cur = skipModifier(cur.typeReturn);
	if (cur == null || cur.kind != TypeKind.Span) return null;
	return cur.typeReturn;
}

function isSpanByteCast(node: Node): boolean {
	if (node.kind != NodeKind.TypeAssertion) return false;
	const target = skipModifier(node.nodeType);
	if (target == null || target.kind != TypeKind.Ptr) return false;
	const d = node.data as TypeAssertionData;
	const spanElem = spanElementOf(d.asExpr != null ? d.asExpr.nodeType : null);
	if (spanElem == null) return false;
	const ptrElem = target.typeReturn;
	return ptrElem == null || !sameType(spanElem, ptrElem);
}

function sbcWalk(node: Node, out: Node[]): void {
	forEachChild(node, (child: Node): void => { sbcWalk(child, out); });
	if (isSpanByteCast(node)) out.push(node);
}

export function collectSpanByteCast(program: Node): Node[] {
	const out: Node[] = [];
	if (program == null) return out;
	sbcWalk(program, out);
	return out;
}

export function refuseSpanByteCastOnJs(ctx: CheckerContext, program: Node): void {
	for (const hit of collectSpanByteCast(program)) {
		const target = skipModifier(hit.nodeType);
		const d = hit.data as TypeAssertionData;
		const from = typeDisplayName(spanElementOf(d.asExpr != null ? d.asExpr.nodeType : null));
		const to = target != null && target.typeReturn != null ? typeDisplayName(target.typeReturn) : "void";
		addError(ctx, `a Span<${from}> cast to Ptr<${to}> ${SPAN_BYTE_CAST_MSG}`, hit.location.line, hit.location.column);
	}
}
