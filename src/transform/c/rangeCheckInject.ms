// Range Check Injection — inserts runtime range checks for narrowing integer casts
// Follows reference range_check_inject.zig
//
// const x: i8 = bigNum as i8;
//   → const x: i8 = ms_chck_range_i8(bigNum, -128, 127);
//
// TypeAssertion nodes (`expr as Type`) where the target type is a narrow integer
// get wrapped with a runtime range check call.
//
// Current limitation: TypeAssertionData only stores the expression being cast,
// not the target type name. Full implementation requires the type annotation to be
// accessible. For now, this pass is a structural placeholder that C codegen can
// extend once type annotations are threaded through TypeAssertion nodes.

import {
	Node, NodeKind,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";
import { test, check, testGroup } from "std/testing";
import { firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Integer Type Ranges =====
// When we can access the target type, these are the ranges to check:
// i8:  -128 to 127
// u8:  0 to 255
// i16: -32768 to 32767
// u16: 0 to 65535
// i32: -2147483648 to 2147483647
// u32: 0 to 4294967295

// ===== Main Entry Point =====

export function injectRangeChecks(program: Node, ctx: TransformContext): Node {
	walkNode(program, rangeCheckVisitor);
	return program;
}

function rangeCheckVisitor(node: Node): Node {
	if (node.kind !== NodeKind.TypeAssertion) return node;

	// TODO: When TypeAssertionData includes the target type name,
	// match against narrow integer types and replace:
	//   expr as i8  →  ms_chck_range_i8(expr, -128, 127)
	//   expr as u8  →  ms_chck_range_u8(expr, 0, 255)
	//   etc.
	// For now, C codegen handles range checks based on type info from the checker.

	return node;
}

// Helper: build a range check call (exported for C codegen use)
export function makeRangeCheck(expr: Node, fnName: string, minVal: number, maxVal: number, loc: Node["location"]): Node {
	return makeCall(
		makeIdent(fnName, loc),
		[expr, makeNumber(minVal, loc), makeNumber(maxVal, loc)],
		loc,
	);
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
});
