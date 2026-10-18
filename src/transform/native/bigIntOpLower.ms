// bigint Operation Lowering (C backend) — msBigInt is an opaque heap value, so
// every operator becomes a runtime call. The checker has already rejected mixed
// arithmetic and equality, so only a relational comparison meets a non-bigint operand.
//
// Rewrites:
//   123n     →  msBigIntFromLit("123n")     (the runtime parser owns 0x/0b/0o/_)
//   a + b    →  msBigIntAdd(a, b)           (- * / % ** & | ^ << >> alike)
//   -a / ~a  →  msBigIntNeg(a) / msBigIntNot(a)
//   !a       →  msBigIntIsZero(a), or !msBigIntIsTruthy(a) when a is bigint | null
//   a < b    →  msBigIntCmp(a, b) < 0       (=== and !== compare against 0 too)
//   a == b   →  msBigIntEqualsNullable(a, b) (a side is bigint | null, a pointer
//               that is NULL for null; `== null` stays a pointer test)
//   a < x    →  msBigIntCompareFloat64(a, x, u) < 0   (x fractional; u is the
//               result when x is NaN, chosen so every comparison is false)
//   a += b   →  a = msBigIntAdd(a, b)
//   a++      →  a = msBigIntAdd(a, msBigIntFromLit("1n"))
//
// Compound assignment and ++/-- read their target twice, so they are restricted
// to side-effect-free targets; anything else is a diagnostic rather than silent
// pointer arithmetic in the emitted C.

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, BigIntLiteralData, ExprStmtData, MemberExprData, TypeAssertionData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { addError } from "../../checker/context";
import { booleanType, createPrimitive, int32Type, isNumeric, peelToRepr, typeDisplayName, isNullableBigInt } from "../../checker/types";
import { isNullExpr } from "../lowering/operatorLower";
import { nullAccessHead } from "./nullableLower";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeAssign, makeBinary, makeCall, makeNumber, makeString, makeUnary, runtimeRef } from "../util";
import { parseInput, checkedCtx } from "../testUtil";
import { CallExprData, IdentifierData, VariableDeclData } from "../../ast/node";
import { checkProgram } from "../../checker/checkPass";

export function lowerBigIntOps(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => rewriteBigIntOp(node, ctx));
	walkNode(program, (node: Node): Node => reportUnloweredUpdate(node, ctx));
	return program;
}

function isBigType(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.BigInt;
}

function isBigNode(n: Node | null): boolean {
	return n != null && isBigType(n.nodeType);
}

function isNullableBigNode(n: Node): boolean {
	return isNullableBigInt(n.nodeType);
}

function isNullOperand(n: Node): boolean {
	return isNullExpr(n) || (n.nodeType != null && n.nodeType.kind == TypeKind.Null);
}

function nullableBigOperator(node: Node, d: BinaryExprData, ctx: TransformContext): Node {
	const loc = node.location;
	const cmp = comparisonOp(d.operator);
	if (cmp != "===" && cmp != "!==") {
		addError(ctx.checkerCtx, "'" + d.operator + "' needs a bigint, not a value that may be null; compare it with null first", loc.line, loc.column);
		return node;
	}
	if (isNullOperand(d.left) || isNullOperand(d.right)) return node;
	const eq = bigCall("msBigIntEqualsNullable", [d.left, d.right], loc, booleanType());
	if (cmp == "===") return eq;
	const ne = makeUnary("!", eq, loc);
	ne.nodeType = booleanType();
	return ne;
}

function isFractionalSource(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (r.kind == TypeKind.Float32 || r.kind == TypeKind.Float64 || r.kind == TypeKind.Number);
}

function bigType(): Type {
	return createPrimitive(TypeKind.BigInt);
}

function bigCall(fnName: string, args: Node[], loc: SourceLocation, t: Type | null): Node {
	const call = makeCall(runtimeRef(fnName, loc), args, loc);
	call.nodeType = t;
	return call;
}

function fromLit(text: string, loc: SourceLocation): Node {
	return bigCall("msBigIntFromLit", [makeString(text, loc)], loc, bigType());
}

// Widen a non-bigint operand for a mixed comparison, or a source value for
// `x as bigint`. Arithmetic never reaches here — the checker rejects mixing.
function toBig(n: Node, ctx: TransformContext): Node {
	const loc = n.location;
	const t = n.nodeType;
	if (isBigType(t)) return n;
	if (t != null && (t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral)) {
		return bigCall("msBigIntFromLit", [n], loc, bigType());
	}
	if (t != null && t.kind == TypeKind.Uint64) return bigCall("msBigIntFromUint64", [n], loc, bigType());
	if (t != null && t.kind == TypeKind.Int64) return bigCall("msBigIntFromInt64", [n], loc, bigType());
	if (t != null && isNumeric(t)) return bigCall("msBigIntFromFloat64", [n], loc, bigType());
	addError(ctx.checkerCtx, "cannot convert " + typeDisplayName(t) + " to bigint", loc.line, loc.column);
	return n;
}

// `b as <numeric>` — the TypeAssertion node stays so codegen still narrows to
// the annotated C type; only its operand becomes the extraction call.
function fromBig(node: Node, ctx: TransformContext): Node {
	const d = node.data as TypeAssertionData;
	const dst = node.nodeType;
	const loc = node.location;
	if (dst != null && dst.kind == TypeKind.Float32) {
		d.asExpr = bigCall("msBigIntToFloat32", [d.asExpr], loc, dst);
		return node;
	}
	if (dst != null && (dst.kind == TypeKind.Float64 || dst.kind == TypeKind.Number)) {
		d.asExpr = bigCall("msBigIntToFloat64", [d.asExpr], loc, dst);
		return node;
	}
	const bits = signedBits(dst);
	if (bits > 0) {
		d.asExpr = bigCall("msBigIntToSigned", [d.asExpr, makeNumber(bits, loc)], loc, createPrimitive(TypeKind.Int64));
		return node;
	}
	if (dst != null && isNumeric(dst)) {
		d.asExpr = bigCall("msBigIntToInt64", [d.asExpr], loc, createPrimitive(TypeKind.Int64));
		return node;
	}
	addError(ctx.checkerCtx, "cannot convert bigint to " + typeDisplayName(dst), loc.line, loc.column);
	return node;
}

function signedBits(t: Type | null): int32 {
	if (t == null) return 0;
	return match (t.kind) {
		TypeKind.Int8 => 8,
		TypeKind.Int16 => 16,
		TypeKind.Int32 => 32,
		TypeKind.Int64 => 64,
		_ => 0,
	};
}

function arithFn(op: string): string {
	return match (op) {
		"+" | "+=" => "msBigIntAdd",
		"-" | "-=" => "msBigIntSub",
		"*" | "*=" => "msBigIntMul",
		"/" | "/=" => "msBigIntDiv",
		"%" | "%=" => "msBigIntMod",
		"**" | "**=" => "msBigIntPow",
		"&" | "&=" => "msBigIntAnd",
		"|" | "|=" => "msBigIntOr",
		"^" | "^=" => "msBigIntXor",
		"<<" | "<<=" => "msBigIntShl",
		">>" | ">>=" => "msBigIntShr",
		_ => "",
	};
}

function comparisonOp(op: string): string {
	return match (op) {
		"===" | "==" => "===",
		"!==" | "!=" => "!==",
		"<" => "<",
		">" => ">",
		"<=" => "<=",
		">=" => ">=",
		_ => "",
	};
}

function resultWhenUnordered(cmp: string): int32 {
	return cmp == ">" || cmp == ">=" ? -1 : 1;
}

function compareWithFraction(d: BinaryExprData, cmp: string, loc: SourceLocation): Node | null {
	const unordered = makeNumber(resultWhenUnordered(cmp), loc);
	let call: Node | null = null;
	if (isBigNode(d.left) && isFractionalSource(d.right.nodeType)) {
		call = bigCall("msBigIntCompareFloat64", [d.left, d.right, unordered], loc, int32Type());
	} else if (isFractionalSource(d.left.nodeType) && isBigNode(d.right)) {
		call = bigCall("msFloat64CompareBigInt", [d.left, d.right, unordered], loc, int32Type());
	}
	if (call == null) return null;
	const result = makeBinary(call, cmp, makeNumber(0, loc), loc);
	result.nodeType = booleanType();
	return result;
}

// A target read twice by `a += b` / `a++` must be free of side effects.
function isRereadableTarget(n: Node): boolean {
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		return isRereadableTarget(d.object);
	}
	return false;
}

function rewriteBigIntOp(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.BigIntLiteral) {
		const d = node.data as BigIntLiteralData;
		return fromLit(d.bigintValue, node.location);
	}

	if (node.kind == NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		if (d.unaryOp == "!" && isNullableBigNode(d.operand)) {
			const truthy = bigCall("msBigIntIsTruthy", [d.operand], node.location, booleanType());
			const not = makeUnary("!", truthy, node.location);
			not.nodeType = booleanType();
			return not;
		}
		if (!isBigNode(d.operand)) return node;
		if (d.unaryOp == "-") return bigCall("msBigIntNeg", [d.operand], node.location, bigType());
		if (d.unaryOp == "~") return bigCall("msBigIntNot", [d.operand], node.location, bigType());
		if (d.unaryOp == "!") {
			const zero = bigCall("msBigIntIsZero", [d.operand], node.location, booleanType());
			return zero;
		}
		return node;
	}

	if (node.kind == NodeKind.TypeAssertion) {
		const td = node.data as TypeAssertionData;
		if (td.asExpr == null) return node;
		const dstBig = node.nodeType != null && node.nodeType.kind == TypeKind.BigInt;
		const srcBig = isBigNode(td.asExpr);
		const carrier = td.asExpr.nodeType;
		if (dstBig && carrier != null && isNullableBigInt(carrier)) {
			const head = makeString(nullAccessHead(carrier), node.location);
			return bigCall("msBigIntNonNull", [td.asExpr, head, makeString("null", node.location)], node.location, bigType());
		}
		if (dstBig && isFractionalSource(td.asExpr.nodeType)) return bigCall("msBigIntFromNumber", [td.asExpr], node.location, bigType());
		if (dstBig && !srcBig) return toBig(td.asExpr, ctx);
		if (srcBig && !dstBig) return fromBig(node, ctx);
		return node;
	}

	if (node.kind == NodeKind.ExprStmt) {
		const sd = node.data as ExprStmtData;
		const inner = sd.expr;
		if (inner != null && inner.kind == NodeKind.UpdateExpr) {
			const ud = inner.data as UpdateExprData;
			if (isBigNode(ud.updateArg)) {
				if (!isRereadableTarget(ud.updateArg)) {
					addError(ctx.checkerCtx, "increment/decrement on bigint needs a plain variable or field target", inner.location.line, inner.location.column);
					return node;
				}
				const fnName = ud.updateOp == "++" ? "msBigIntAdd" : "msBigIntSub";
				const step = fromLit("1n", inner.location);
				const call = bigCall(fnName, [ud.updateArg, step], inner.location, bigType());
				sd.expr = makeAssign(ud.updateArg, call, inner.location);
				return node;
			}
		}
		return node;
	}

	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	const nullableOperand = isNullableBigNode(d.left) || isNullableBigNode(d.right);
	if (nullableOperand && (comparisonOp(d.operator) != "" || arithFn(d.operator) != "")) return nullableBigOperator(node, d, ctx);
	if (!isBigNode(d.left) && !isBigNode(d.right)) return node;

	const loc = node.location;
	const cmp = comparisonOp(d.operator);
	if (cmp != "") {
		const withFraction = compareWithFraction(d, cmp, loc);
		if (withFraction != null) return withFraction;
		const cmpCall = bigCall("msBigIntCmp", [toBig(d.left, ctx), toBig(d.right, ctx)], loc, int32Type());
		const result = makeBinary(cmpCall, cmp, makeNumber(0, loc), loc);
		result.nodeType = booleanType();
		return result;
	}

	const fnName = arithFn(d.operator);
	if (fnName == "") return node;

	const isCompound = d.operator.byteLength > 1 && d.operator.endsWith("=");
	if (isCompound) {
		if (!isRereadableTarget(d.left)) {
			addError(ctx.checkerCtx, "compound assignment on bigint needs a plain variable or field target; write `a = a " + d.operator.slice(0, d.operator.byteLength - 1) + " b` instead", loc.line, loc.column);
			return node;
		}
		const call = bigCall(fnName, [d.left, d.right], loc, bigType());
		return makeAssign(d.left, call, loc);
	}

	return bigCall(fnName, [d.left, d.right], loc, bigType());
}

function reportUnloweredUpdate(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.UpdateExpr) return node;
	const d = node.data as UpdateExprData;
	if (!isBigNode(d.updateArg)) return node;
	addError(ctx.checkerCtx, "increment/decrement on bigint is only supported as a statement", node.location.line, node.location.column);
	return node;
}

function extractionOf(target: string): string {
	const result = parseInput("function f(b: bigint): void { const r = b as " + target + "; }");
	if (!result.ok) return "";
	const ctx = checkedCtx(checkProgram(result.value));
	lowerBigIntOps(result.value, ctx);
	let callee = "";
	walkNode(result.value, (n: Node): Node => {
		if (n.kind != NodeKind.VariableDecl || (n.data as VariableDeclData).declName != "r") return n;
		const init = (n.data as VariableDeclData).initializer;
		const call = init.kind == NodeKind.TypeAssertion ? (init.data as TypeAssertionData).asExpr : init;
		if (call.kind == NodeKind.CallExpr) {
			const fn = (call.data as CallExprData).callee;
			if (fn.kind == NodeKind.Identifier) callee = (fn.data as IdentifierData).name;
		}
		return n;
	});
	return callee;
}

test "bigint to a signed integer checks the true value" {
	assert extractionOf("int8") == "msBigIntToSigned";
	assert extractionOf("int32") == "msBigIntToSigned";
	assert extractionOf("int64") == "msBigIntToSigned";
}

test "bigint to an unsigned integer wraps" {
	assert extractionOf("uint8") == "msBigIntToInt64";
	assert extractionOf("uint64") == "msBigIntToInt64";
}

test "bigint to float32 rounds once" {
	assert extractionOf("float32") == "msBigIntToFloat32";
	assert extractionOf("float64") == "msBigIntToFloat64";
}
