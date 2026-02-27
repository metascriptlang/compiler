// Range Check Injection — inserts runtime range checks for narrowing integer casts
// Follows reference range_check_inject.zig
//
// const x: i8 = bigNum as i8;
//   → const x: i8 = ms_chck_range_i8(bigNum, -128, 127);
//
// TypeAssertion nodes (`expr as Type`) where the target type is a narrow integer
// get wrapped with a runtime range check call.

import {
	Node, NodeKind, TypeAssertionData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";
import { test, check, testGroup } from "std/testing";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { ExprStmtData } from "../../ast/node";
import { createTransformContext } from "../context";

// ===== Helpers =====

// Get the range check function name for a narrow integer type
function getRangeCheckFn(typeName: string): string {
	return match (typeName) {
		"int8" => "ms_chck_range_i8",
		"uint8" => "ms_chck_range_u8",
		"int16" => "ms_chck_range_i16",
		"uint16" => "ms_chck_range_u16",
		"int32" => "ms_chck_range_i32",
		"uint32" => "ms_chck_range_u32",
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

function rangeCheckVisitor(node: Node): Node {
	if (node.kind !== NodeKind.TypeAssertion) return node;
	const d = node.data as TypeAssertionData;
	const fnName = getRangeCheckFn(d.asType);
	if (fnName === "") return node;
	return makeRangeCheck(d.asExpr, fnName, getRangeMin(d.asType), getRangeMax(d.asType), node.location);
}

// Helper: build a range check call (exported for C codegen use)
export function makeRangeCheck(expr: Node, fnName: string, minVal: number, maxVal: number, loc: Node["location"]): Node {
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

testGroup("Range Check Inject", () => {
	test("non-cast unchanged", () => {
		check(firstExprKindAfter("x + y;", injectRangeChecks) === NodeKind.BinaryExpr);
	});
	test("call unchanged", () => {
		check(firstExprKindAfter("f();", injectRangeChecks) === NodeKind.CallExpr);
	});
	test("passthrough", () => {
		check(stmtCountAfter("const x = 1;", injectRangeChecks) === 1);
	});
	test("member access unchanged", () => {
		check(firstExprKindAfter("obj.x;", injectRangeChecks) === NodeKind.MemberExpr);
	});
	test("identifier unchanged", () => {
		check(firstExprKindAfter("x;", injectRangeChecks) === NodeKind.Identifier);
	});
	test("parser stores asType", () => {
		check(parsedAsType("x as int8;") === "int8");
	});
	test("parser stores asType number", () => {
		check(parsedAsType("x as number;") === "number");
	});
	test("parser stores asType union", () => {
		check(parsedAsType("x as string | null;") === "string | null");
	});
	test("cast to int8 becomes range check", () => {
		check(castExprKind("x as int8;") === NodeKind.CallExpr);
	});
	test("cast to uint16 becomes range check", () => {
		check(castExprKind("x as uint16;") === NodeKind.CallExpr);
	});
	test("cast to int32 becomes range check", () => {
		check(castExprKind("x as int32;") === NodeKind.CallExpr);
	});
	test("cast to number unchanged", () => {
		check(castExprKind("x as number;") === NodeKind.TypeAssertion);
	});
	test("cast to string unchanged", () => {
		check(castExprKind("x as string;") === NodeKind.TypeAssertion);
	});
});
