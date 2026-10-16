// Integer division, modulo and power on the C backend:
//
//   a / b    → msDivI32(a, b)         (a zero divisor and MIN / -1 raise)
//   a % b    → msModI32(a, b)
//   a /= b   → msDivAssignI32(a, b)   (the left side is evaluated once)
//   a ** b   → msPowI64(a, b)         (msPowWrapI64 under --danger)
//   x ** y   → msPowF64(x, y)         (a float power, ECMAScript's NaN cases)
//   a **= b  → msPowAssignI64(a, b)   (msPowAssignF64 on a float target, msPowWrapAssign under --danger)
//   f %= b   → msModAssignF64(f, b)   (a float target; fmod, the left side evaluated once)
//   n |= b   → msOrAssignF64(n, b)    (a number target of & | ^ << >> >>>, as n = n | b)
//
// Division by a literal that is neither 0 nor -1 cannot raise and stays an operator,
// as do all divisions under --danger. An 8- or 16-bit operation runs at 32 bits
// and its result is converted back, so it wraps at its own width.

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, HiddenStdConvData, NumberLiteralData, Type, TypeKind } from "../../ast/node";
import { peelToRepr, createPrimitive } from "../../checker/types";
import { wrapInConv, isBitwiseBinaryOp, isBitwiseCompoundOp } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, runtimeRef, makeNumber } from "../util";

export function lowerNumberBitwiseOperands(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => toInt32Visitor(n));
	return program;
}

function toInt32Visitor(node: Node): Node {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isBitwiseCompoundOp(d.operator)) {
			d.right = toInt32Operand(d.right);
			return node;
		}
		if (!isBitwiseBinaryOp(d.operator)) return node;
		d.left = toInt32Operand(d.left);
		d.right = toInt32Operand(d.right);
	} else if (node.kind == NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		if (d.unaryOp == "~") d.operand = toInt32Operand(d.operand);
	}
	return node;
}

function toInt32Operand(operand: Node): Node {
	if (operand == null || operand.kind != NodeKind.HiddenStdConv) return operand;
	const d = operand.data as HiddenStdConvData;
	const dest = peelToRepr(d.convType);
	if (dest == null || dest.kind != TypeKind.Int32 || d.convExpr == null) return operand;
	const src = peelToRepr(d.convExpr.nodeType);
	if (src == null || !(src.kind == TypeKind.Number || src.kind == TypeKind.Float64 || src.kind == TypeKind.Float32)) return operand;
	const call = makeCall(runtimeRef("msToInt32", operand.location), [d.convExpr], operand.location);
	call.nodeType = d.convType;
	return call;
}

export function injectIntChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => intCheckVisitor(n, ctx));
	return program;
}

function intCheckVisitor(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.UnaryExpr) return ctx.rangeChecks ? checkedNegate(node) : node;
	if (node.kind == NodeKind.UpdateExpr) return ctx.rangeChecks ? checkedStep(node) : node;
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator == "**") return lowerPow(node, d, ctx);
	if (d.operator == "**=") return lowerPowAssign(node, d, ctx);
	const floatAssign = floatAssignHelper(d);
	if (floatAssign != "") {
		const call = makeCall(runtimeRef(floatAssign, node.location), [d.left, d.right], node.location);
		call.nodeType = d.left.nodeType;
		return call;
	}
	if (!ctx.rangeChecks) return node;
	if (d.operator == "/" || d.operator == "%") {
		const t = integerRepr(node.nodeType);
		if (t == null || cannotRaise(d.right, t)) return node;
		if (d.operator == "/" && isSubIntSigned(t.kind)) return typedCall(ownWidthName("msDiv", t), [d.left, d.right], node);
		return atOwnWidth(makeCall(runtimeRef(helperName(d.operator == "/" ? "msDiv" : "msMod", t), node.location), [d.left, d.right], node.location), t, node);
	}
	if (d.operator == "/=" || d.operator == "%=") {
		const t = integerRepr(d.left.nodeType);
		if (t == null || cannotRaise(d.right, t)) return node;
		const name = d.operator == "/=" && isSubIntSigned(t.kind) ? ownWidthName("msDivAssign", t) : helperName(d.operator == "/=" ? "msDivAssign" : "msModAssign", t);
		const call = makeCall(runtimeRef(name, node.location), [d.left, d.right], node.location);
		call.nodeType = d.left.nodeType;
		return call;
	}
	const arith = overflowPrefix(d.operator);
	if (arith != "") {
		const t = signedRepr(node.nodeType);
		if (t == null) return node;
		return typedCall(ownWidthName(arith, t), [d.left, d.right], node);
	}
	const assign = overflowAssign(d.operator);
	if (assign != "" && signedRepr(d.left.nodeType) != null) {
		const call = makeCall(runtimeRef(assign, node.location), [d.left, d.right], node.location);
		call.nodeType = d.left.nodeType;
		return call;
	}
	return node;
}

function overflowPrefix(op: string): string {
	return match (op) {
		"+" => "msAdd",
		"-" => "msSub",
		"*" => "msMul",
		_ => "",
	};
}

function overflowAssign(op: string): string {
	return match (op) {
		"+=" => "msAddAssign",
		"-=" => "msSubAssign",
		"*=" => "msMulAssign",
		_ => "",
	};
}

function checkedNegate(node: Node): Node {
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "-" || isLiteral(d.operand)) return node;
	const t = signedRepr(node.nodeType);
	if (t == null) return node;
	return typedCall(ownWidthName("msNeg", t), [d.operand], node);
}

function checkedStep(node: Node): Node {
	const d = node.data as UpdateExprData;
	if (signedRepr(d.updateArg.nodeType) == null) return node;
	const increment = d.updateOp == "++";
	if (!d.isPrefix) return typedCall(increment ? "msPostInc" : "msPostDec", [d.updateArg], node);
	return typedCall(increment ? "msAddAssign" : "msSubAssign", [d.updateArg, makeNumber(1, node.location)], node);
}

function typedCall(name: string, args: Node[], node: Node): Node {
	const call = makeCall(runtimeRef(name, node.location), args, node.location);
	call.nodeType = node.nodeType;
	return call;
}

function isLiteral(n: Node): boolean {
	let e = n;
	while (e.kind == NodeKind.HiddenStdConv) e = (e.data as HiddenStdConvData).convExpr;
	return e.kind == NodeKind.NumberLiteral;
}

function floatAssignHelper(d: BinaryExprData): string {
	const t = peelToRepr(d.left.nodeType);
	if (t == null) return "";
	const isFloat = t.kind == TypeKind.Number || t.kind == TypeKind.Float64 || t.kind == TypeKind.Float32;
	if (d.operator == "%=") return isFloat ? "msModAssignF64" : "";
	if (t.kind != TypeKind.Number) return "";
	return match (d.operator) {
		"&=" => "msAndAssignF64",
		"|=" => "msOrAssignF64",
		"^=" => "msXorAssignF64",
		"<<=" => "msShlAssignF64",
		">>=" => "msShrAssignF64",
		">>>=" => "msShrUAssignF64",
		_ => "",
	};
}

function lowerPow(node: Node, d: BinaryExprData, ctx: TransformContext): Node {
	const t = integerRepr(node.nodeType);
	if (t != null) {
		const prefix = ctx.rangeChecks ? "msPow" : "msPowWrap";
		if (ctx.rangeChecks && isSubIntSigned(t.kind)) return typedCall(ownWidthName(prefix, t), [d.left, d.right], node);
		return atOwnWidth(makeCall(runtimeRef(helperName(prefix, t), node.location), [d.left, d.right], node.location), t, node);
	}
	if (!isFloatRepr(node.nodeType)) return node;
	const call = makeCall(runtimeRef("msPowF64", node.location), [d.left, d.right], node.location);
	call.nodeType = node.nodeType;
	return call;
}

function lowerPowAssign(node: Node, d: BinaryExprData, ctx: TransformContext): Node {
	const t = integerRepr(d.left.nodeType);
	let helper = "msPowAssignF64";
	if (t != null && ctx.rangeChecks && isSubIntSigned(t.kind)) helper = ownWidthName("msPowAssign", t);
	else if (t != null) helper = helperName(ctx.rangeChecks ? "msPowAssign" : "msPowWrapAssign", t);
	else if (!isFloatRepr(d.left.nodeType)) return node;
	const call = makeCall(runtimeRef(helper, node.location), [d.left, d.right], node.location);
	call.nodeType = d.left.nodeType;
	return call;
}

function isFloatRepr(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (r.kind == TypeKind.Number || r.kind == TypeKind.Float64 || r.kind == TypeKind.Float32);
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

function signedRepr(t: Type | null): Type | null {
	const r = integerRepr(t);
	return r != null && isSigned(r.kind) ? r : null;
}

function isSubIntSigned(kind: TypeKind): boolean {
	return kind == TypeKind.Int8 || kind == TypeKind.Int16;
}

function ownWidthName(prefix: string, t: Type): string {
	const suffix = match (t.kind) {
		TypeKind.Int8 => "I8",
		TypeKind.Int16 => "I16",
		TypeKind.Int32 => "I32",
		_ => "I64",
	};
	return prefix + suffix;
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
