// Range Check Injection — inserts runtime range checks for narrowing integer casts
//
// const x: i8 = bigNum as i8;
//   → const x: i8 = msCheckRangeI8(bigNum, -128, 127);
//
// TypeAssertion nodes (`expr as Type`) where the target type is a narrow integer
// get wrapped with a runtime range check call.

import { Node, NodeKind, SourceLocation, TypeAssertionData, HiddenStdConvData, Type, TypeKind } from "../../ast/node";
import { integerRank, isIntegerType, peelToRepr } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber, runtimeRef } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { ExprStmtData, VariableDeclData } from "../../ast/node";
import { createTransformContextWithChecker } from "../context";
import { checkProgram } from "../../checker/checkPass";

// ===== Helpers =====

// ===== Main Entry Point =====

export function injectRangeChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => { return rangeCheckVisitor(n, ctx); });
	return program;
}

// Parity: standard reference's conversion transformation — convert HiddenStdConv with narrowing integer to range check.
// Standard reference checks if destination range covers source range to skip redundant checks.
// We use getRangeCheckForTypeKind which returns "" for non-narrowing types.
function getRangeCheckForTypeKind(kind: TypeKind): string {
	return match (kind) {
		TypeKind.Int8   => "msCheckRangeI8",
		TypeKind.Uint8  => "msCheckRangeU8",
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
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 => 0,
		_ => 0,
	};
}

function getRangeMaxForKind(kind: TypeKind): number {
	return match (kind) {
		TypeKind.Int8   => 127,
		TypeKind.Uint8  => 255,
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
	const s = peelToRepr(src);
	if (s == null) return false;
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
	return integerRank(s) <= integerRank(dest);
}

function isFloatSource(src: Type | null): boolean {
	const s = peelToRepr(src);
	if (s == null) return false;
	return s.kind == TypeKind.Float32 || s.kind == TypeKind.Float64 || s.kind == TypeKind.Number;
}

export function rangeCheckHelper(src: Type | null, dest: Type, rangeChecks: boolean): string {
	if (!rangeChecks) return "";
	if (dest.kind == TypeKind.Int64) return isFloatSource(src) ? "msCheckRangeI64" : "";
	const fnName = getRangeCheckForTypeKind(dest.kind);
	if (fnName == "" || isUnsignedKind(dest.kind) || destCovers(src, dest)) return "";
	return fnName;
}

export function makeRangeCheckFor(
	fnName: string,
	expr: Node,
	dest: Type,
	loc: SourceLocation,
): Node {
	if (fnName == "msCheckRangeI64") return makeCall(runtimeRef(fnName, loc), [expr], loc);
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
	if (fnName == "msCheckRangeI64") call.nodeType = dest;
	return call;
}

function rangeCheckVisitor(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const src = d.asExpr != null ? d.asExpr.nodeType : null;
		if (node.nodeType == null) return node;
		return checkedConv(ctx, d.asExpr, src, node.nodeType, node);
	}
	if (node.kind == NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType == null) return node;
		const src = d.convExpr != null ? d.convExpr.nodeType : null;
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
	const ctx = createTransformContextWithChecker(checkProgram(result.value));
	ctx.rangeChecks = rangeChecks;
	injectRangeChecks(result.value, ctx);
	const found: NodeKind[] = [];
	walkNode(result.value, (n: Node): Node => {
		if (n.kind == NodeKind.VariableDecl && (n.data as VariableDeclData).declName == "r") found.push((n.data as VariableDeclData).initializer.kind);
		return n;
	});
	return found.length > 0 ? found[0] : NodeKind.Program;
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

test "cast to uint16 stays a plain cast" { assert castExprKind(castOf("uint16")) == NodeKind.TypeAssertion; }

test "cast to uint8 stays a plain cast" { assert castExprKind(castOf("uint8")) == NodeKind.TypeAssertion; }

test "cast to uint32 stays a plain cast" { assert castExprKind(castOf("uint32")) == NodeKind.TypeAssertion; }

test "cast to int8 stays a plain cast when range checks are off" { assert castExprKind(castOf("int8"), false) == NodeKind.TypeAssertion; }

test "cast to int32 becomes range check" { assert castExprKind(castOf("int32")) == NodeKind.CallExpr; }

test "cast to an alias of int8 becomes range check" { assert castExprKind("type SByte = int8;\n" + castOf("SByte")) == NodeKind.CallExpr; }

test "cast to number unchanged" { assert castExprKind(castOf("number")) == NodeKind.TypeAssertion; }

test "cast to string unchanged" { assert castExprKind("function f(v: string): void { const r = v as string; }") == NodeKind.TypeAssertion; }
