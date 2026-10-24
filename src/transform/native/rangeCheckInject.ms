// Range Check Injection — inserts runtime range checks for narrowing integer casts
//
// const x: i8 = bigNum as i8;
//   → const x: i8 = msCheckRangeI8(bigNum, -128, 127);
//
// TypeAssertion nodes (`expr as Type`) where the target type is a narrow integer
// get wrapped with a runtime range check call.

import { Node, NodeKind, SourceLocation, TypeAssertionData, HiddenStdConvData, Type, TypeKind, ExprStmtData, VariableDeclData, CallExprData } from "../../ast/node";
import { integerRank, isIntegerType, peelToRepr, enumOrdinalBounds, createPrimitive, distinctNumericBase } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeNumber, runtimeRef } from "../util";
import { isFloatKind } from "../numKinds";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts, checkedCtx } from "../testUtil";
import { checkProgram } from "../../checker/checkPass";

// ===== Helpers =====

// ===== Main Entry Point =====

export function injectRangeChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => { return rangeCheckVisitor(n, ctx); });
	return program;
}

export function injectEnumRangeChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => {
		if (n.kind == NodeKind.TypeAssertion) {
			const d = n.data as TypeAssertionData;
			if (n.nodeType != null && n.nodeType.kind == TypeKind.Enum && d.asExpr != null) d.asExpr = checkedEnumSource(ctx, d.asExpr, n.nodeType, true);
		} else if (n.kind == NodeKind.HiddenStdConv) {
			const d = n.data as HiddenStdConvData;
			if (d.convType != null && d.convType.kind == TypeKind.Enum && d.convExpr != null) d.convExpr = checkedEnumSource(ctx, d.convExpr, d.convType, true);
		}
		return n;
	});
	return program;
}

// Parity: standard reference's conversion transformation — convert HiddenStdConv with narrowing integer to range check.
// Standard reference checks if destination range covers source range to skip redundant checks.
// We use getRangeCheckForTypeKind which returns "" for non-narrowing types.
function getRangeCheckForTypeKind(kind: TypeKind): string {
	return match (kind) {
		TypeKind.Int8   => "msCheckRangeI8",
		TypeKind.Uint8 | TypeKind.Char => "msCheckRangeU8",
		TypeKind.Int16  => "msCheckRangeI16",
		TypeKind.Uint16 => "msCheckRangeU16",
		TypeKind.Int32  => "msCheckRangeI32",
		TypeKind.Uint32 => "msCheckRangeU32",
		_ => "",
	};
}

function getRangeMinForKind(kind: TypeKind): number {
	return match (kind) {
		TypeKind.Int8   => -128,
		TypeKind.Int16  => -32768,
		TypeKind.Int32  => -2147483648,
		_ => 0,
	};
}

function getRangeMaxForKind(kind: TypeKind): number {
	return match (kind) {
		TypeKind.Int8   => 127,
		TypeKind.Uint8 | TypeKind.Char => 255,
		TypeKind.Int16  => 32767,
		TypeKind.Uint16 => 65535,
		TypeKind.Int32  => 2147483647,
		TypeKind.Uint32 => 4294967295,
		_ => 0,
	};
}

function isUnsignedKind(kind: TypeKind): boolean {
	return kind == TypeKind.Uint8 || kind == TypeKind.Uint16 || kind == TypeKind.Uint32;
}

function destCovers(src: Type | null, dest: Type): boolean {
	const r = peelToRepr(src);
	if (r == null) return false;
	const s = r.kind == TypeKind.Char ? createPrimitive(TypeKind.Uint8) : r;
	if (s.kind == TypeKind.Enum) {
		const lo = getRangeMinForKind(dest.kind);
		const hi = getRangeMaxForKind(dest.kind);
		for (const member of s.typeChildren) {
			if (member == null) return false;
			const v = member.typeValue;
			if (v < lo || v > hi) return false;
		}
		return true;
	}
	if (!isIntegerType(s)) return false;
	if (dest.kind == TypeKind.Char) return s.kind == TypeKind.Uint8;
	return integerRank(s) <= integerRank(dest);
}

function isNumericSource(src: Type | null): boolean {
	const s = peelToRepr(src);
	return s != null && (isIntegerType(s) || s.kind == TypeKind.Char || s.kind == TypeKind.Enum || isFloatSource(s));
}

function isFloatSource(src: Type | null): boolean {
	const s = peelToRepr(src);
	if (s == null) return false;
	return isFloatKind(s.kind);
}

function isUint64Source(src: Type | null): boolean {
	const s = peelToRepr(src);
	return s != null && s.kind == TypeKind.Uint64;
}

function int64CheckFor(src: Type | null): string {
	const s = peelToRepr(src);
	if (s == null) return "";
	if (s.kind == TypeKind.Uint64) return "msCheckRangeI64FromU64";
	return isFloatSource(s) ? "msCheckRangeI64" : "";
}

function isInt64Check(fnName: string): boolean {
	return fnName == "msCheckRangeI64" || fnName == "msCheckRangeI64FromU64" || fnName == "msCheckRangeU64";
}

function enumCovers(src: Type | null, dest: Type): boolean {
	const s = peelToRepr(src);
	if (s == null) return true;
	const db = enumOrdinalBounds(dest);
	if (s.kind == TypeKind.Enum) {
		if (s == dest || (s.typeName != "" && s.typeName == dest.typeName && s.sym == dest.sym)) return true;
		const sb = enumOrdinalBounds(s);
		return sb[0] >= db[0] && sb[1] <= db[1];
	}
	return !isIntegerType(s) && s.kind != TypeKind.Number && s.kind != TypeKind.Float64 && s.kind != TypeKind.Float32;
}

export function rangeCheckHelper(src: Type | null, dest: Type, rangeChecks: boolean): string {
	if (!rangeChecks) return "";
	if (dest.kind == TypeKind.Enum) return dest.typeNames.length == 0 || enumCovers(src, dest) ? "" : "msCheckRangeI32";
	if (dest.kind == TypeKind.Int64) return int64CheckFor(src);
	if (dest.kind == TypeKind.Uint64) return isFloatSource(src) ? "msCheckRangeU64" : "";
	if (dest.kind == TypeKind.Char) return isNumericSource(src) && !destCovers(src, dest) ? "msCheckRangeU8" : "";
	const fnName = getRangeCheckForTypeKind(dest.kind);
	if (fnName == "") return "";
	if (isUnsignedKind(dest.kind)) return isFloatSource(src) ? fnName : "";
	return destCovers(src, dest) ? "" : fnName;
}

export function makeRangeCheckFor(
	fnName: string,
	expr: Node,
	dest: Type,
	loc: SourceLocation,
): Node {
	if (isInt64Check(fnName)) return makeCall(runtimeRef(fnName, loc), [expr], loc);
	if (dest.kind == TypeKind.Enum) {
		const bounds = enumOrdinalBounds(dest);
		return makeRangeCheck(expr, fnName, bounds[0], bounds[1], loc);
	}
	const lo = getRangeMinForKind(dest.kind);
	return makeRangeCheck(expr, fnName, lo, getRangeMaxForKind(dest.kind), loc);
}

function checkedConv(
	ctx: TransformContext,
	expr: Node,
	src: Type | null,
	dest: Type,
	node: Node,
): Node {
	const fnName = rangeCheckHelper(src, dest, ctx.rangeChecks);
	if (fnName == "") return node;
	const call = makeRangeCheckFor(fnName, expr, dest, node.location);
	if (isInt64Check(fnName)) call.nodeType = dest;
	return call;
}

function checkedEnumSource(ctx: TransformContext, expr: Node, dest: Type, untypedBridge: boolean = false): Node {
	const fnName = rangeCheckHelper(expr.nodeType, dest, ctx.rangeChecks);
	if (fnName == "") return expr;
	const fromU64 = untypedBridge && isUint64Source(expr.nodeType);
	const call = makeRangeCheckFor(fromU64 ? "msCheckRangeI32FromU64" : fnName, expr, dest, expr.location);
	call.nodeType = createPrimitive(TypeKind.Int32);
	return call;
}

function checkedDistinctSource(ctx: TransformContext, expr: Node, base: Type): Node {
	const checked = checkedConv(ctx, expr, expr.nodeType, base, expr);
	if (checked != expr) checked.nodeType = base;
	return checked;
}

function rangeCheckVisitor(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const src = d.asExpr != null ? d.asExpr.nodeType : null;
		if (node.nodeType == null) return node;
		if (node.nodeType.kind == TypeKind.Enum && d.asExpr != null) {
			d.asExpr = checkedEnumSource(ctx, d.asExpr, node.nodeType);
			return node;
		}
		const base = distinctNumericBase(node.nodeType);
		if (base != null && d.asExpr != null) {
			d.asExpr = checkedDistinctSource(ctx, d.asExpr, base);
			return node;
		}
		return checkedConv(ctx, d.asExpr, src, node.nodeType, node);
	}
	if (node.kind == NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType == null) return node;
		const src = d.convExpr != null ? d.convExpr.nodeType : null;
		if (d.convType.kind == TypeKind.Enum && d.convExpr != null) {
			d.convExpr = checkedEnumSource(ctx, d.convExpr, d.convType);
			return node;
		}
		return checkedConv(ctx, d.convExpr, src, d.convType, node);
	}
	return node;
}
// Helper: build a range check call (exported for C codegen use)
export function makeRangeCheck(expr: Node, fnName: string, minVal: number, maxVal: number, loc: SourceLocation): Node {
	const args: Node[] = [];
	args.push(expr);
	args.push(makeNumber(minVal, loc));
	args.push(makeNumber(maxVal, loc));
	return makeCall(runtimeRef(fnName, loc), args, loc);
}

// ===== Test Helpers =====

function castExprKind(input: string, rangeChecks: boolean = true): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const ctx = checkedCtx(checkProgram(result.value));
	ctx.rangeChecks = rangeChecks;
	injectRangeChecks(result.value, ctx);
	const found: NodeKind[] = [];
	walkNode(result.value, (n: Node): Node => {
		if (n.kind == NodeKind.VariableDecl && (n.data as VariableDeclData).declName == "r") found.push((n.data as VariableDeclData).initializer.kind);
		return n;
	});
	return found.length > 0 ? found[0] : NodeKind.Program;
}

function rangeHelperOf(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "";
	const ctx = checkedCtx(checkProgram(result.value));
	injectRangeChecks(result.value, ctx);
	let name = "";
	walkNode(result.value, (n: Node): Node => {
		if (n.kind == NodeKind.VariableDecl && (n.data as VariableDeclData).declName == "r") {
			const init = (n.data as VariableDeclData).initializer;
			const callee = init.kind == NodeKind.CallExpr ? (init.data as CallExprData).callee : null;
			if (callee != null && callee.resolvedSym != null) name = callee.resolvedSym.name;
		}
		return n;
	});
	return name;
}

function castOf(target: string): string {
	return "function f(v: float64): void { const r = v as " + target + "; }";
}

function parsedAsType(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "";
	const stmts = getStmts(result.value);
	if (stmts.length == 0) return "";
	if (stmts[0].kind != NodeKind.ExprStmt) return "";
	const sd = stmts[0].data as ExprStmtData;
	if (sd.expr.kind != NodeKind.TypeAssertion) return "";
	const td = sd.expr.data as TypeAssertionData;
	return td.asType;
}

// ===== Tests =====
test "non-cast unchanged" { assert firstExprKindAfter("x + y;", injectRangeChecks) == NodeKind.BinaryExpr; }

test "call unchanged" { assert firstExprKindAfter("f();", injectRangeChecks) == NodeKind.CallExpr; }

test "passthrough" { assert stmtCountAfter("const x = 1;", injectRangeChecks) == 1; }

test "member access unchanged" { assert firstExprKindAfter("obj.x;", injectRangeChecks) == NodeKind.MemberExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", injectRangeChecks) == NodeKind.Identifier; }

test "parser stores asType" { assert parsedAsType("x as int8;") == "int8"; }

test "parser stores asType number" { assert parsedAsType("x as number;") == "number"; }

test "parser stores asType union" { assert parsedAsType("x as string | null;") == "string | null"; }

test "cast to int8 becomes range check" { assert castExprKind(castOf("int8")) == NodeKind.CallExpr; }

test "a float converted to an unsigned type is range checked at every width" {
	assert rangeHelperOf(castOf("uint8")) == "msCheckRangeU8";
	assert rangeHelperOf(castOf("uint16")) == "msCheckRangeU16";
	assert rangeHelperOf(castOf("uint32")) == "msCheckRangeU32";
	assert rangeHelperOf(castOf("uint64")) == "msCheckRangeU64";
	assert rangeHelperOf("function f(v: float32): void { const r = v as uint8; }") == "msCheckRangeU8";
	assert rangeHelperOf("function f(v: number): void { const r = v as uint64; }") == "msCheckRangeU64";
}

test "an integer converted to an unsigned type wraps unchecked" {
	assert castExprKind("function f(v: int32): void { const r = v as uint8; }") == NodeKind.TypeAssertion;
	assert castExprKind("function f(v: int64): void { const r = v as uint32; }") == NodeKind.TypeAssertion;
	assert castExprKind("function f(v: int64): void { const r = v as uint64; }") == NodeKind.TypeAssertion;
	assert castExprKind("function f(v: uint64): void { const r = v as uint16; }") == NodeKind.TypeAssertion;
}

test "an integer or a float converted to char is range checked, as an unsigned byte that stops" {
	assert rangeHelperOf("function f(v: int32): void { const r = v as char; }") == "msCheckRangeU8";
	assert rangeHelperOf("function f(v: uint16): void { const r = v as char; }") == "msCheckRangeU8";
	assert rangeHelperOf("function f(v: int8): void { const r = v as char; }") == "msCheckRangeU8";
	assert rangeHelperOf(castOf("char")) == "msCheckRangeU8";
	assert castExprKind("function f(v: uint8): void { const r = v as char; }") == NodeKind.TypeAssertion;
}

test "a char converted to a signed type is checked only where the type cannot hold 255" {
	assert rangeHelperOf("function f(v: char): void { const r = v as int8; }") == "msCheckRangeI8";
	assert castExprKind("function f(v: char): void { const r = v as int16; }") == NodeKind.TypeAssertion;
	assert castExprKind("function f(v: char): void { const r = v as int32; }") == NodeKind.TypeAssertion;
	assert castExprKind("function f(v: char): void { const r = v as uint8; }") == NodeKind.TypeAssertion;
}

test "a float converted to an unsigned type stays a plain cast when range checks are off" {
	assert castExprKind(castOf("uint8"), false) == NodeKind.TypeAssertion;
	assert castExprKind(castOf("uint64"), false) == NodeKind.TypeAssertion;
}

test "cast to int8 stays a plain cast when range checks are off" { assert castExprKind(castOf("int8"), false) == NodeKind.TypeAssertion; }

test "cast to int32 becomes range check" { assert castExprKind(castOf("int32")) == NodeKind.CallExpr; }

test "cast to an alias of int8 becomes range check" { assert castExprKind("type SByte = int8;\n" + castOf("SByte")) == NodeKind.CallExpr; }

test "cast to number unchanged" { assert castExprKind(castOf("number")) == NodeKind.TypeAssertion; }

test "cast to string unchanged" { assert castExprKind("function f(v: string): void { const r = v as string; }") == NodeKind.TypeAssertion; }
