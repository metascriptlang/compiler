// Range Check Injection — inserts runtime range checks for narrowing integer casts
// Follows reference range_check_inject.zig
//
// const x: i8 = bigNum as i8;
//   → const x: i8 = msCheckRangeI8(bigNum, -128, 127);
//
// TypeAssertion nodes (`expr as Type`) where the target type is a narrow integer
// get wrapped with a runtime range check call.

import { Node, NodeKind, SourceLocation, TypeAssertionData, HiddenStdConvData, Type, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { ExprStmtData } from "../../ast/node";
import { createTransformContext } from "../context";
import { typeNameOf } from "../../checker/types";

// ===== Helpers =====

// Get the range check function name for a narrow integer type
function getRangeCheckFn(typeName: string): string {
	return match (typeName) {
		"int8" => "msCheckRangeI8",
		"uint8" => "msCheckRangeU8",
		"int16" => "msCheckRangeI16",
		"uint16" => "msCheckRangeU16",
		"int32" => "msCheckRangeI32",
		"uint32" => "msCheckRangeU32",
		_ => "",
	};
}

// Get the minimum value for a narrow integer type
function getRangeMin(typeName: string): number {
	return match (typeName) {
		"int8" => -128,
		"int16" => -32768,
		"int32" => -2147483648,
		"uint8" | "uint16" | "uint32" => 0,
		_ => 0,
	};
}

// Get the maximum value for a narrow integer type
function getRangeMax(typeName: string): number {
	return match (typeName) {
		"int8" => 127,
		"uint8" => 255,
		"int16" => 32767,
		"uint16" => 65535,
		"int32" => 2147483647,
		"uint32" => 4294967295,
		_ => 0,
	};
}

// ===== Main Entry Point =====

export function injectRangeChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, rangeCheckVisitor);
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

function rangeCheckVisitor(node: Node): Node {
	// Explicit casts: x as int8 → msCheckRangeI8(x, -128, 127)
	if (node.kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const fnName = getRangeCheckFn(d.asType);
		if (fnName === "") return node;
		return makeRangeCheck(d.asExpr, fnName, getRangeMin(d.asType), getRangeMax(d.asType), node.location);
	}
	// Parity: standard reference's implicit narrowing transformation
	if (node.kind === NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType === null) return node;
		const fnName = getRangeCheckForTypeKind(d.convType.kind);
		if (fnName === "") return node;
		return makeRangeCheck(d.convExpr, fnName, getRangeMinForKind(d.convType.kind), getRangeMaxForKind(d.convType.kind), node.location);
	}
	return node;
}

// Helper: build a range check call (exported for C codegen use)
export function makeRangeCheck(expr: Node, fnName: string, minVal: number, maxVal: number, loc: SourceLocation): Node {
	const args: Node[] = [];
	args.push(expr);
	args.push(makeNumber(minVal, loc));
	args.push(makeNumber(maxVal, loc));
	return makeCall(makeIdent(fnName, loc), args, loc);
}

// ===== Test Helpers =====

function castExprKind(input: string): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const ctx = createTransformContext();
	injectRangeChecks(result.value, ctx);
	const stmts = getStmts(result.value);
	if (stmts.length === 0) return NodeKind.Program;
	if (stmts[0].kind !== NodeKind.ExprStmt) return NodeKind.Program;
	const sd = stmts[0].data as ExprStmtData;
	return sd.expr.kind;
}

function parsedAsType(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "";
	const stmts = getStmts(result.value);
	if (stmts.length === 0) return "";
	if (stmts[0].kind !== NodeKind.ExprStmt) return "";
	const sd = stmts[0].data as ExprStmtData;
	if (sd.expr.kind !== NodeKind.TypeAssertion) return "";
	const td = sd.expr.data as TypeAssertionData;
	return td.asType;
}

// ===== Tests =====
test "non-cast unchanged" { assert firstExprKindAfter("x + y;", injectRangeChecks) === NodeKind.BinaryExpr; }

test "call unchanged" { assert firstExprKindAfter("f();", injectRangeChecks) === NodeKind.CallExpr; }

test "passthrough" { assert stmtCountAfter("const x = 1;", injectRangeChecks) === 1; }

test "member access unchanged" { assert firstExprKindAfter("obj.x;", injectRangeChecks) === NodeKind.MemberExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", injectRangeChecks) === NodeKind.Identifier; }

test "parser stores asType" { assert parsedAsType("x as int8;") === "int8"; }

test "parser stores asType number" { assert parsedAsType("x as number;") === "number"; }

test "parser stores asType union" { assert parsedAsType("x as string | null;") === "string | null"; }

test "cast to int8 becomes range check" { assert castExprKind("x as int8;") === NodeKind.CallExpr; }

test "cast to uint16 becomes range check" { assert castExprKind("x as uint16;") === NodeKind.CallExpr; }

test "cast to int32 becomes range check" { assert castExprKind("x as int32;") === NodeKind.CallExpr; }

test "cast to number unchanged" { assert castExprKind("x as number;") === NodeKind.TypeAssertion; }

test "cast to string unchanged" { assert castExprKind("x as string;") === NodeKind.TypeAssertion; }
