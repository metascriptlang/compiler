// Integer division, modulo and power on the C backend:
//
//   a / b    → msDivI32(a, b)         (a zero divisor and MIN / -1 raise)
//   a % b    → msModI32(a, b)
//   a /= b   → msDivAssignI32(a, b)   (the left side is evaluated once)
//   a ** b   → msPowI64(a, b)         (msPowWrapI64 under --danger)
//
// Division by a literal that is neither 0 nor -1 cannot raise and stays an operator,
// as do all divisions under --danger. An 8- or 16-bit operation runs at 32 bits
// and its result is converted back, so it wraps at its own width.

import { Node, NodeKind, BinaryExprData, HiddenStdConvData, NumberLiteralData, Type, TypeKind } from "../../ast/node";
import { peelToRepr, createPrimitive } from "../../checker/types";
import { wrapInConv } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, runtimeRef } from "../util";

export function injectIntChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => intCheckVisitor(n, ctx));
	return program;
}

function intCheckVisitor(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator == "**") return lowerIntPow(node, d, ctx);
	if (!ctx.rangeChecks) return node;
	if (d.operator == "/" || d.operator == "%") {
		const t = integerRepr(node.nodeType);
		if (t == null || cannotRaise(d.right, t)) return node;
		return atOwnWidth(makeCall(runtimeRef(helperName(d.operator == "/" ? "msDiv" : "msMod", t), node.location), [d.left, d.right], node.location), t, node);
	}
	if (d.operator == "/=" || d.operator == "%=") {
		const t = integerRepr(d.left.nodeType);
		if (t == null || cannotRaise(d.right, t)) return node;
		const call = makeCall(runtimeRef(helperName(d.operator == "/=" ? "msDivAssign" : "msModAssign", t), node.location), [d.left, d.right], node.location);
		call.nodeType = d.left.nodeType;
		return call;
	}
	return node;
}

function lowerIntPow(node: Node, d: BinaryExprData, ctx: TransformContext): Node {
	const t = integerRepr(node.nodeType);
	if (t == null) return node;
	const prefix = ctx.rangeChecks ? "msPow" : "msPowWrap";
	return atOwnWidth(makeCall(runtimeRef(helperName(prefix, t), node.location), [d.left, d.right], node.location), t, node);
}

function integerRepr(t: Type | null): Type | null {
	const r = peelToRepr(t);
	if (r == null) return null;
	return match (r.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => r,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => r,
		_ => null,
	};
}

function isSigned(kind: TypeKind): boolean {
	return kind == TypeKind.Int8 || kind == TypeKind.Int16 || kind == TypeKind.Int32 || kind == TypeKind.Int64;
}

function is64(kind: TypeKind): boolean {
	return kind == TypeKind.Int64 || kind == TypeKind.Uint64;
}

function helperKind(t: Type): TypeKind {
	if (is64(t.kind)) return t.kind;
	return isSigned(t.kind) ? TypeKind.Int32 : TypeKind.Uint32;
}

function helperName(prefix: string, t: Type): string {
	const suffix = match (helperKind(t)) {
		TypeKind.Int32 => "I32",
		TypeKind.Int64 => "I64",
		TypeKind.Uint32 => "U32",
		_ => "U64",
	};
	return prefix + suffix;
}

function atOwnWidth(call: Node, t: Type, node: Node): Node {
	const hk = helperKind(t);
	call.nodeType = createPrimitive(hk);
	if (hk == t.kind) {
		call.nodeType = node.nodeType;
		return call;
	}
	return wrapInConv(call, node.nodeType != null ? node.nodeType : t);
}

// A literal divisor other than 0 and -1 can neither be zero nor overflow MIN / -1.
function cannotRaise(divisor: Node, t: Type): boolean {
	let n = divisor;
	while (n.kind == NodeKind.HiddenStdConv) n = (n.data as HiddenStdConvData).convExpr;
	if (n.kind != NodeKind.NumberLiteral) return false;
	const lit = n.data as NumberLiteralData;
	if (lit.isFloat) return false;
	if (lit.intVal == 0) return false;
	return !(isSigned(t.kind) && lit.intVal == -1);
}
