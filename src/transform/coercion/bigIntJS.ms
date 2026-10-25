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

import { Node, NodeKind, NumberLiteralData, BigIntLiteralData, TypeAssertionData, HiddenStdConvData, BinaryExprData, UnaryExprData, UpdateExprData, SourceLocation, TypeKind, Type, createNode, NodeData } from "../../ast/node";
import { TokenKind, createToken } from "../../lexer/token";
import { TransformContext } from "../context";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeMember, makeNumber, generatedRef, runtimeRef } from "../util";
import { createPrimitive, isIntegerType, peelToRepr, literalUnionBase } from "../../checker/types";
import { int64ToDecimal, uint64ToDecimal } from "../../utils/string";
import { cloneIfPure } from "../place";
import { is64Kind, isSignedKind, isFloatKind, isNarrowIntKind, bitsOfKind } from "../numKinds";
import { isEagerAssignOp, isComparisonOp, isShiftOp } from "../../ast/operators";
import { makeRangeCheckFor } from "../native/rangeCheckInject";

export function lowerBigIntJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => materializeBigInt(node, ctx));
	return program;
}

function reprKind(t: Type | null): TypeKind {
	const r = peelToRepr(t);
	if (r == null) return TypeKind.Unknown;
	return match (r.kind) {
		TypeKind.Enum => TypeKind.Int32,
		TypeKind.Char => TypeKind.Uint8,
		_ => r.kind,
	};
}

function is64Type(t: Type | null): boolean {
	return is64Kind(reprKind(t));
}

function isNarrowIntType(t: Type | null): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Char || (isIntegerType(t) && !is64Kind(t.kind));
}

function isFloatLikeType(t: Type | null): boolean {
	return t != null && isFloatKind(t.kind);
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
		const convK = reprKind(d.convType);
		const convSrcK = reprKind(srcT);
		if (!is64Kind(convK) && !is64Kind(convSrcK)) return node;
		return bigConvert(d.convExpr, convSrcK, convK, node.location);
	}
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const bigCast = bigintCast(node, d, ctx.rangeChecks);
		if (bigCast != null) return bigCast;
		const dstK = reprKind(node.nodeType);
		if (dstK == TypeKind.Unknown || d.asExpr == null) return node;
		const srcK = reprKind(d.asExpr.nodeType);
		if (srcK == TypeKind.Unknown || readsUnionMember(d)) return node;
		if (!is64Kind(dstK) && !is64Kind(srcK)) return node;
		return bigConvert(d.asExpr, srcK, dstK, node.location);
	}
	if (node.kind == NodeKind.BinaryExpr) return binaryAsBigInt(node, ctx);
	if (node.kind == NodeKind.UnaryExpr) return unaryAsBigInt(node);
	if (node.kind == NodeKind.UpdateExpr) return updateAsBigInt(node, ctx);
	return node;
}

// ===== Literals =====

function literalAsBigInt(node: Node): Node {
	const k = reprKind(node.nodeType);
	if (!is64Kind(k)) return node;
	const d = node.data as NumberLiteralData;
	if (d.isFloat) return node;
	const text = k == TypeKind.Uint64
		? uint64ToDecimal(d.intVal as uint64)
		: int64ToDecimal(d.intVal);
	return bigLit(text + "n", k, node.location);
}

function bigLit(text: string, kind: TypeKind, loc: SourceLocation): Node {
	const tok = createToken(TokenKind.Ident, "", loc.line);
	const lit = createNode(NodeKind.BigIntLiteral, { bigintValue: text } as NodeData, tok);
	lit.location = loc;
	lit.nodeType = createPrimitive(kind);
	return lit;
}

// ===== Conversions (genConv rows, exact-C narrow variant) =====

export function readsUnionMember(d: TypeAssertionData): boolean {
	if (d.asExpr == null) return false;
	if (d.asExpr.kind == NodeKind.HiddenSubConv) return true;
	const t = d.asExpr.nodeType;
	return t != null && t.kind == TypeKind.Union && literalUnionBase(t) == null;
}

function bigintCast(node: Node, d: TypeAssertionData, rangeChecks: boolean): Node | null {
	if (d.asExpr == null) return null;
	const srcT = d.asExpr.nodeType;
	const dstBig = reprKind(node.nodeType) == TypeKind.BigInt;
	const srcBig = srcT != null && srcT.kind == TypeKind.BigInt;
	if (!dstBig && !srcBig) return null;
	const loc = node.location;
	if (dstBig) {
		if (srcBig || srcT == null) return d.asExpr;
		if (is64Kind(srcT.kind)) return d.asExpr;
		if (isFloatKind(reprKind(srcT))) return typedCall("msBigIntFromNumber", [d.asExpr], TypeKind.Int64, loc);
		return bigIntOf(d.asExpr, loc);
	}
	const dstK = reprKind(node.nodeType);
	if (dstK == TypeKind.Int64) return typedCall("msBigIntToSigned", [d.asExpr, makeNumber(64, loc)], dstK, loc);
	if (dstK == TypeKind.Uint64) return asN(true, 64, d.asExpr, loc);
	const dstRepr = peelToRepr(node.nodeType);
	if (rangeChecks && dstRepr != null && dstRepr.kind == TypeKind.Char) {
		return numberOf(makeRangeCheckFor("msCheckRangeU8", d.asExpr, dstRepr, loc), loc);
	}
	const bits = bitsOfKind(dstK);
	if (bits > 0) return numberOf(asN(!isSignedKind(dstK), bits, d.asExpr, loc), loc);
	if (dstK == TypeKind.Float32) return typedCall("msBigIntToFloat32", [d.asExpr], dstK, loc);
	return numberOf(d.asExpr, loc);
}

function typedCall(fnName: string, args: Node[], kind: TypeKind, loc: SourceLocation): Node {
	const call = makeCall(runtimeRef(fnName, loc), args, loc);
	call.nodeType = createPrimitive(kind);
	return call;
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
		else if (isSignedKind(srcK)) { r = asN(true, 64, bigIntOf(inner, loc), loc); }
		else if (isNarrowIntKind(srcK)) { r = bigIntOf(inner, loc); }
		else { return inner; }
		r.nodeType = createPrimitive(dstK);
		return r;
	}
	if (!is64Kind(srcK)) return inner;
	// 64-bit source into a narrower slot.
	const bits = bitsOfKind(dstK);
	let r = inner;
	if (bits > 0) {
		r = numberOf(asN(!isSignedKind(dstK), bits, inner, loc), loc);
	} else if (dstK == TypeKind.Float32) {
		r = makeCall(runtimeRef(srcK == TypeKind.Uint64 ? "msUint64ToFloat32" : "msInt64ToFloat32", loc), [inner], loc);
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
	if (isEagerAssignOp(d.operator)) return assignAsBigInt(node, ctx);
	if (isComparisonOp(d.operator)) {
		if (is64Type(leftT) && isNarrowIntType(rightT)) { d.right = bigIntOf(d.right, node.location); return node; }
		if (is64Type(rightT) && isNarrowIntType(leftT)) { d.left = bigIntOf(d.left, node.location); return node; }
		// int64 against a float compares as double on C; Number() mirrors that.
		if (is64Type(leftT) && isFloatLikeType(rightT)) { d.left = numberOf(d.left, node.location); return node; }
		if (is64Type(rightT) && isFloatLikeType(leftT)) { d.right = numberOf(d.right, node.location); return node; }
		return node;
	}
	if (isShiftOp(d.operator)) {
		const leftRepr = peelToRepr(leftT);
		if (leftRepr == null || !is64Kind(leftRepr.kind)) return node;
		return shiftAsBigInt(node, leftRepr);
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
	if (reprKind(node.nodeType) == TypeKind.Uint64 && wrapsOnUint64(d.operator)) {
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
		return shifted;
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
	if (d.operator == "<<=" || d.operator == ">>=" || d.operator == ">>>=") {
		const base = d.operator.slice(0, d.operator.length - 1);
		const readBack = cloneIfPure(d.left);
		if (readBack == null) {
			if (ctx.checkerCtx != null) {
				addError(ctx.checkerCtx, "integer '" + d.operator + "' needs a left side that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
			}
			return node;
		}
		const shifted = shiftAsBigInt(makeBinary(readBack, base, d.right, node.location), peelToRepr(leftT)!);
		return makeBinary(d.left, "=", shifted, node.location);
	}
	if (isNarrowIntType(rightT)) d.right = bigIntOf(d.right, node.location);
	if (needsUint64CompoundWrap(d)) return compoundAtUint64(node, d, ctx);
	return node;
}

// `x op= y` stores what `x = x op y` stores (NIM-REF CK-152). The reference
// wraps mInc/mDec on uint64 in place and lowers `*=` to the wrapped `*`.
export function needsUint64CompoundWrap(d: BinaryExprData): boolean {
	if (d.left == null || reprKind(d.left.nodeType) != TypeKind.Uint64) return false;
	return d.operator == "+=" || d.operator == "-=" || d.operator == "*=";
}

function compoundAtUint64(node: Node, d: BinaryExprData, ctx: TransformContext): Node {
	const readBack = cloneIfPure(d.left);
	if (readBack == null) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "integer '" + d.operator + "' needs a left side that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	const loc = node.location;
	const widened = makeBinary(readBack, d.operator.slice(0, 1), d.right, loc);
	return makeBinary(d.left, "=", asTyped(asN(true, 64, widened, loc), TypeKind.Uint64), loc);
}

// A postfix step reads back the value before the step: the wrapped new value
// stepped back and wrapped again, as updateAtWidth does for the narrow widths.
function updateAsBigInt(node: Node, ctx: TransformContext): Node {
	const d = node.data as UpdateExprData;
	if (reprKind(d.updateArg.nodeType) != TypeKind.Uint64) return node;
	const readBack = cloneIfPure(d.updateArg);
	if (readBack == null) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "integer '" + d.updateOp + "' needs an operand that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	const loc = node.location;
	const step = d.updateOp == "++" ? "+" : "-";
	const next = makeBinary(readBack, step, bigLit("1n", TypeKind.Uint64, loc), loc);
	const stored = makeBinary(d.updateArg, "=", asTyped(asN(true, 64, next, loc), TypeKind.Uint64), loc);
	if (d.isPrefix) return stored;
	const back = makeBinary(stored, d.updateOp == "++" ? "-" : "+", bigLit("1n", TypeKind.Uint64, loc), loc);
	return asTyped(asN(true, 64, back, loc), TypeKind.Uint64);
}

function unaryAsBigInt(node: Node): Node {
	if (reprKind(node.nodeType) != TypeKind.Uint64) return node;
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "-" && d.unaryOp != "~") return node;
	return asTyped(asN(true, 64, node, node.location), TypeKind.Uint64);
}

// ===== Emission helpers =====

function bigIntOf(inner: Node, loc: SourceLocation): Node {
	const call = makeCall(generatedRef("BigInt", loc), [inner], loc);
	call.nodeType = createPrimitive(TypeKind.Int64);
	return call;
}

function numberOf(inner: Node, loc: SourceLocation): Node {
	const call = makeCall(generatedRef("Number", loc), [inner], loc);
	call.nodeType = createPrimitive(TypeKind.Float64);
	return call;
}

function mathTrunc(inner: Node, loc: SourceLocation): Node {
	return makeCall(makeMember(generatedRef("Math", loc), "trunc", loc), [inner], loc);
}

function asN(unsigned: boolean, bits: int32, inner: Node, loc: SourceLocation): Node {
	const fn = unsigned ? "asUintN" : "asIntN";
	return makeCall(makeMember(generatedRef("BigInt", loc), fn, loc), [makeNumber(bits, loc), inner], loc);
}

function asTyped(node: Node, kind: TypeKind): Node {
	node.nodeType = createPrimitive(kind);
	return node;
}

// ===== Classifiers =====

