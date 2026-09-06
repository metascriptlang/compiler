// bigint Operation Lowering (C backend) — msBigInt is an opaque heap value, so
// every operator becomes a runtime call. The checker has already rejected mixed
// operands, so any bigint-typed operand means both sides are bigint.
//
// Rewrites:
//   123n     →  msBigIntFromLit("123n")     (the runtime parser owns 0x/0b/0o/_)
//   a + b    →  msBigIntAdd(a, b)           (- * / % ** & | ^ << >> alike)
//   -a / ~a  →  msBigIntNeg(a) / msBigIntNot(a)
//   a < b    →  msBigIntCmp(a, b) < 0       (=== and !== compare against 0 too)
//   a += b   →  a = msBigIntAdd(a, b)
//   a++      →  a = msBigIntAdd(a, msBigIntFromLit("1n"))
//
// Compound assignment and ++/-- read their target twice, so they are restricted
// to side-effect-free targets; anything else is a diagnostic rather than silent
// pointer arithmetic in the emitted C.

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, BigIntLiteralData, ExprStmtData, MemberExprData, TypeAssertionData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { addError } from "../../checker/context";
import { booleanType, createPrimitive, int32Type, isNumeric, typeDisplayName } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeAssign, makeBinary, makeCall, makeIdent, makeNumber, makeString } from "../util";

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

function bigType(): Type {
	return createPrimitive(TypeKind.BigInt);
}

function bigCall(fnName: string, args: Node[], loc: SourceLocation, t: Type | null): Node {
	const call = makeCall(makeIdent(fnName, loc), args, loc);
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
	if (dst != null && (dst.kind == TypeKind.Float64 || dst.kind == TypeKind.Float32 || dst.kind == TypeKind.Number)) {
		d.asExpr = bigCall("msBigIntToFloat64", [d.asExpr], loc, dst);
		return node;
	}
	if (dst != null && isNumeric(dst)) {
		d.asExpr = bigCall("msBigIntToInt64", [d.asExpr], loc, createPrimitive(TypeKind.Int64));
		return node;
	}
	addError(ctx.checkerCtx, "cannot convert bigint to " + typeDisplayName(dst), loc.line, loc.column);
	return node;
}

function arithFn(op: string): string {
	return match (op) {
		"+" | "+=" => "msBigIntAdd",
		"-" | "-=" => "msBigIntSub",
		"*" | "*=" => "msBigIntMul",
		"/" | "/=" => "msBigIntDiv",
		"%" | "%=" => "msBigIntMod",
		"**" => "msBigIntPow",
		"&" => "msBigIntAnd",
		"|" => "msBigIntOr",
		"^" => "msBigIntXor",
		"<<" => "msBigIntShl",
		">>" => "msBigIntShr",
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
	if (!isBigNode(d.left) && !isBigNode(d.right)) return node;

	const loc = node.location;
	const cmp = comparisonOp(d.operator);
	if (cmp != "") {
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
