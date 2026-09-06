// BigInt materialization (JS backend) — docs/JS-NUMERIC.md P4.
//
// Under the flag int64/uint64 values are native BigInt, and a Number reaching
// a BigInt operator throws (arithmetic) or silently answers false (`===`).
// The checker marks every 64-bit boundary with a HiddenStdConv (fitNode wraps
// widening as well as narrowing); this pass consumes those marks plus the
// operand shapes the checker does not mark (mixed comparisons, shift counts).
//
// Reference: jsgen.nim arithAux + genConv, no-overflow-check rows only.
// One deliberate divergence: 64→narrow conversions emit
// Number(BigInt.asIntN(bits, x)) instead of the reference's bare Number(x) —
// the reference form diverges from its own C backend past 2^53, ours matches
// C's mod-2^N wrap exactly.
//
// `Math`, `BigInt`, `Number` receivers stay symbol-less on purpose: binding
// them would reach prelude classes and mangle. Runs after resolveRuntimeIdents.

import { Node, NodeKind, NumberLiteralData, BigIntLiteralData, TypeAssertionData, HiddenStdConvData, BinaryExprData, UnaryExprData, SourceLocation, TypeKind, Type, createNode, NodeData } from "../../ast/node";
import { TokenKind, createToken } from "../../lexer/token";
import { TransformContext } from "../context";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeIdent, makeMember, makeNumber } from "../util";
import { createPrimitive, isIntegerType } from "../../checker/types";
import { int64ToDecimal, uint64ToDecimal } from "../../utils/string";

export function lowerBigIntJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => materializeBigInt(node, ctx));
	return program;
}

function is64Kind(kind: TypeKind): boolean {
	return kind == TypeKind.Int64 || kind == TypeKind.Uint64;
}

function is64Type(t: Type | null): boolean {
	return t != null && is64Kind(t.kind);
}

function isNarrowIntType(t: Type | null): boolean {
	if (t == null) return false;
	return isIntegerType(t) && !is64Kind(t.kind);
}

function isFloatLikeType(t: Type | null): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Number || t.kind == TypeKind.Float64 || t.kind == TypeKind.Float32;
}

function materializeBigInt(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.NumberLiteral) return literalAsBigInt(node);
	if (node.kind == NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType == null || d.convExpr == null) return node;
		const srcT = d.convExpr.nodeType;
		if (srcT == null) return node;
		// Conversions clear of the 64-bit space belong to lowerIntConvJS, which
		// runs next and needs the node still standing.
		if (!is64Kind(d.convType.kind) && !is64Kind(srcT.kind)) return node;
		return bigConvert(d.convExpr, srcT.kind, d.convType.kind, node.location);
	}
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const bigCast = bigintCast(node, d);
		if (bigCast != null) return bigCast;
		const dstK = intKindOfName(d.asType);
		if (dstK == TypeKind.Unknown || d.asExpr == null) return node;
		const srcT = d.asExpr.nodeType;
		if (srcT == null) return node;
		if (!is64Kind(dstK) && !is64Type(srcT)) return node;
		return bigConvert(d.asExpr, srcT.kind, dstK, node.location);
	}
	if (node.kind == NodeKind.BinaryExpr) return binaryAsBigInt(node, ctx);
	if (node.kind == NodeKind.UnaryExpr) return unaryAsBigInt(node);
	return node;
}

// ===== Literals =====

function literalAsBigInt(node: Node): Node {
	const t = node.nodeType;
	if (!is64Type(t)) return node;
	const d = node.data as NumberLiteralData;
	if (d.isFloat) return node;
	const text = t.kind == TypeKind.Uint64
		? uint64ToDecimal(d.intVal as uint64)
		: int64ToDecimal(d.intVal);
	return bigLit(text + "n", t.kind, node.location);
}

function bigLit(text: string, kind: TypeKind, loc: SourceLocation): Node {
	const tok = createToken(TokenKind.Ident, "", loc.line);
	const lit = createNode(NodeKind.BigIntLiteral, { bigintValue: text } as NodeData, tok);
	lit.location = loc;
	lit.nodeType = createPrimitive(kind);
	return lit;
}

// ===== Conversions (genConv rows, exact-C narrow variant) =====

// `x as bigint` / `b as <numeric>`. int64 and uint64 are already native BigInt
// on this backend, so those legs only need the width clamp C applies.
function bigintCast(node: Node, d: TypeAssertionData): Node | null {
	if (d.asExpr == null) return null;
	const srcT = d.asExpr.nodeType;
	const dstBig = d.asType == "bigint";
	const srcBig = srcT != null && srcT.kind == TypeKind.BigInt;
	if (!dstBig && !srcBig) return null;
	const loc = node.location;
	if (dstBig) {
		if (srcBig || srcT == null) return d.asExpr;
		if (is64Kind(srcT.kind)) return d.asExpr;
		return bigIntOf(d.asExpr, loc);
	}
	const dstK = intKindOfName(d.asType);
	if (dstK == TypeKind.Int64) return asN(false, 64, d.asExpr, loc);
	if (dstK == TypeKind.Uint64) return asN(true, 64, d.asExpr, loc);
	const bits = narrowBits(dstK);
	if (bits > 0) return numberOf(asN(!isSignedNarrowKind(dstK), bits, d.asExpr, loc), loc);
	return numberOf(d.asExpr, loc);
}

function bigConvert(inner: Node, srcK: TypeKind, dstK: TypeKind, loc: SourceLocation): Node {
	if (srcK == dstK) return inner;
	if (dstK == TypeKind.Int64) {
		let r = inner;
		if (srcK == TypeKind.Uint64) { r = asN(false, 64, inner, loc); }
		else if (isFloatKind(srcK)) { r = bigIntOf(mathTrunc(inner, loc), loc); }
		else if (isNarrowIntKind(srcK)) { r = bigIntOf(inner, loc); }
		else { return inner; }
		r.nodeType = createPrimitive(dstK);
		return r;
	}
	if (dstK == TypeKind.Uint64) {
		let r = inner;
		if (srcK == TypeKind.Int64) { r = asN(true, 64, inner, loc); }
		else if (isFloatKind(srcK)) { r = asN(true, 64, bigIntOf(mathTrunc(inner, loc), loc), loc); }
		else if (isSignedNarrowKind(srcK)) { r = asN(true, 64, bigIntOf(inner, loc), loc); }
		else if (isNarrowIntKind(srcK)) { r = bigIntOf(inner, loc); }
		else { return inner; }
		r.nodeType = createPrimitive(dstK);
		return r;
	}
	if (!is64Kind(srcK)) return inner;
	// 64-bit source into a narrower slot.
	const bits = narrowBits(dstK);
	let r = inner;
	if (bits > 0) {
		r = numberOf(asN(!isSignedNarrowKind(dstK), bits, inner, loc), loc);
	} else if (isFloatKind(dstK)) {
		r = numberOf(inner, loc);
	} else {
		return inner;
	}
	r.nodeType = createPrimitive(dstK);
	return r;
}

// ===== Operators (arithAux rows) =====

function binaryAsBigInt(node: Node, ctx: TransformContext): Node {
	const d = node.data as BinaryExprData;
	const leftT = d.left != null ? d.left.nodeType : null;
	const rightT = d.right != null ? d.right.nodeType : null;
	if (isAssignOp(d.operator)) return assignAsBigInt(node, ctx);
	if (isComparisonOp(d.operator)) {
		if (is64Type(leftT) && isNarrowIntType(rightT)) { d.right = bigIntOf(d.right, node.location); return node; }
		if (is64Type(rightT) && isNarrowIntType(leftT)) { d.left = bigIntOf(d.left, node.location); return node; }
		// int64 against a float compares as double on C; Number() mirrors that.
		if (is64Type(leftT) && isFloatLikeType(rightT)) { d.left = numberOf(d.left, node.location); return node; }
		if (is64Type(rightT) && isFloatLikeType(leftT)) { d.right = numberOf(d.right, node.location); return node; }
		return node;
	}
	if (isShiftOp(d.operator)) {
		if (leftT == null || !is64Kind(leftT.kind)) return node;
		return shiftAsBigInt(node, leftT);
	}
	// Float-typed result with a 64-bit operand: C promotes the integer to double.
	if (isFloatLikeType(node.nodeType)) {
		if (is64Type(leftT)) d.left = numberOf(d.left, node.location);
		if (is64Type(rightT)) d.right = numberOf(d.right, node.location);
		return node;
	}
	if (!is64Type(node.nodeType)) return node;
	if (is64Type(leftT) && isNarrowIntType(rightT)) d.right = bigIntOf(d.right, node.location);
	if (is64Type(rightT) && isNarrowIntType(leftT)) d.left = bigIntOf(d.left, node.location);
	if (node.nodeType.kind == TypeKind.Uint64 && wrapsOnUint64(d.operator)) {
		return asTyped(asN(true, 64, node, node.location), TypeKind.Uint64);
	}
	return node;
}

// + - * / wrap on uint64 exactly as the reference's binaryUintExpr does; % is
// bounded by its operands and & | ^ cannot leave the 64-bit two's-complement
// range when both operands are in it.
function wrapsOnUint64(op: string): boolean {
	return match (op) {
		"+" | "-" | "*" | "/" => true,
		_ => false,
	};
}

function shiftAsBigInt(node: Node, leftT: Type): Node {
	const d = node.data as BinaryExprData;
	const loc = node.location;
	const unsigned = leftT.kind == TypeKind.Uint64;
	const count = maskedCount(d.right, loc);
	if (d.operator == "<<") {
		const shifted = makeBinary(d.left, "<<", count, loc);
		shifted.nodeType = leftT;
		return asTyped(asN(unsigned, 64, shifted, loc), leftT.kind);
	}
	if (d.operator == ">>") {
		d.right = count;
		node.nodeType = leftT;
		return node;
	}
	if (d.operator == ">>>") {
		if (unsigned) {
			d.operator = ">>";
			d.right = count;
			node.nodeType = leftT;
			return node;
		}
		const unsignedView = asN(true, 64, d.left, loc);
		const shifted = makeBinary(unsignedView, ">>", count, loc);
		shifted.nodeType = createPrimitive(TypeKind.Uint64);
		return asTyped(asN(false, 64, shifted, loc), TypeKind.Int64);
	}
	return node;
}

function maskedCount(right: Node, loc: SourceLocation): Node {
	const asBig = is64Type(right.nodeType) ? right : bigIntOf(right, loc);
	const masked = makeBinary(asBig, "&", bigLit("63n", TypeKind.Int64, loc), loc);
	masked.nodeType = createPrimitive(TypeKind.Int64);
	return masked;
}

function assignAsBigInt(node: Node, ctx: TransformContext): Node {
	const d = node.data as BinaryExprData;
	const leftT = d.left != null ? d.left.nodeType : null;
	const rightT = d.right != null ? d.right.nodeType : null;
	if (!is64Type(leftT)) return node;
	if (d.operator == "<<=" || d.operator == ">>=") {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "compound shift on int64/uint64 is not supported on the js target; write `a = a " + d.operator.slice(0, d.operator.length - 1) + " b` instead", node.location.line, node.location.column);
		}
		return node;
	}
	if (isNarrowIntType(rightT)) d.right = bigIntOf(d.right, node.location);
	return node;
}

function unaryAsBigInt(node: Node): Node {
	const t = node.nodeType;
	if (t == null || t.kind != TypeKind.Uint64) return node;
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "-" && d.unaryOp != "~") return node;
	return asTyped(asN(true, 64, node, node.location), TypeKind.Uint64);
}

// ===== Emission helpers =====

function bigIntOf(inner: Node, loc: SourceLocation): Node {
	const call = makeCall(makeIdent("BigInt", loc), [inner], loc);
	call.nodeType = createPrimitive(TypeKind.Int64);
	return call;
}

function numberOf(inner: Node, loc: SourceLocation): Node {
	const call = makeCall(makeIdent("Number", loc), [inner], loc);
	call.nodeType = createPrimitive(TypeKind.Float64);
	return call;
}

function mathTrunc(inner: Node, loc: SourceLocation): Node {
	return makeCall(makeMember(makeIdent("Math", loc), "trunc", loc), [inner], loc);
}

function asN(unsigned: boolean, bits: int32, inner: Node, loc: SourceLocation): Node {
	const fn = unsigned ? "asUintN" : "asIntN";
	return makeCall(makeMember(makeIdent("BigInt", loc), fn, loc), [makeNumber(bits, loc), inner], loc);
}

function asTyped(node: Node, kind: TypeKind): Node {
	node.nodeType = createPrimitive(kind);
	return node;
}

// ===== Classifiers =====

export function isFloatKind(kind: TypeKind): boolean {
	return kind == TypeKind.Number || kind == TypeKind.Float64 || kind == TypeKind.Float32;
}

function isNarrowIntKind(kind: TypeKind): boolean {
	return match (kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 => true,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 => true,
		_ => false,
	};
}

function isSignedNarrowKind(kind: TypeKind): boolean {
	return kind == TypeKind.Int8 || kind == TypeKind.Int16 || kind == TypeKind.Int32;
}

function narrowBits(kind: TypeKind): int32 {
	return match (kind) {
		TypeKind.Int8 | TypeKind.Uint8 => 8,
		TypeKind.Int16 | TypeKind.Uint16 => 16,
		TypeKind.Int32 | TypeKind.Uint32 => 32,
		_ => 0,
	};
}

function isAssignOp(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" => true,
		"<<=" | ">>=" | "&=" | "|=" | "^=" => true,
		_ => false,
	};
}

function isComparisonOp(op: string): boolean {
	return match (op) {
		"===" | "!==" | "==" | "!=" => true,
		"<" | "<=" | ">" | ">=" => true,
		_ => false,
	};
}

function isShiftOp(op: string): boolean {
	return op == "<<" || op == ">>" || op == ">>>";
}

function intKindOfName(name: string): TypeKind {
	return match (name) {
		"int8" => TypeKind.Int8,
		"int16" => TypeKind.Int16,
		"int32" => TypeKind.Int32,
		"int64" => TypeKind.Int64,
		"uint8" => TypeKind.Uint8,
		"uint16" => TypeKind.Uint16,
		"uint32" => TypeKind.Uint32,
		"uint64" => TypeKind.Uint64,
		"number" => TypeKind.Unknown,
		_ => TypeKind.Unknown,
	};
}
