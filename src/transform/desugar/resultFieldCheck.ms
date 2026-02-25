// Result Field Check — wraps $result_N.value/.error with discriminant safety checks
// Follows reference result_field_check.zig (Nim's nkCheckedFieldExpr pattern)
//
// $result_0.value  →  { ms_result_check_value($result_0); $result_0.value; }
// $result_0.error  →  { ms_result_check_error($result_0); $result_0.error; }
// $result_0.ok     →  $result_0.ok  (unchanged — ok IS the discriminant)
//
// Only transforms access on variables named $result_* (our freshTemp convention).
// This avoids false positives on arbitrary .value/.error access.

import {
	Node, NodeKind,
	MemberExprData, IdentifierData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeBlock, makeExprStmt } from "../util";
import { test, check, testGroup } from "std/testing";
import { firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerResultFieldCheck(program: Node, ctx: TransformContext): Node {
	walkNode(program, checkResultField);
	return program;
}

function checkResultField(node: Node): Node {
	if (node.kind !== NodeKind.MemberExpr) return node;
	const d = node.data as MemberExprData;

	// Only check our own result temps ($result_N)
	if (d.object.kind !== NodeKind.Identifier) return node;
	const id = d.object.data as IdentifierData;
	if (!isResultTemp(id.name)) return node;

	return match (d.property) {
		"ok" => node,
		"value" => wrapWithCheck(node, d.object, "ms_result_check_value"),
		"error" => wrapWithCheck(node, d.object, "ms_result_check_error"),
		_ => node,
	};
}

function isResultTemp(name: string): boolean {
	// Match $result_N pattern from freshTemp(ctx, "result")
	if (name.length < 8) return false;
	const prefix = "$result";
	let i = 0;
	while (i < prefix.length) {
		if (i >= name.length) return false;
		if (name.charAt(i) !== prefix.charAt(i)) return false;
		i += 1;
	}
	return true;
}

function wrapWithCheck(accessNode: Node, resultObj: Node, checkFnName: string): Node {
	const loc = accessNode.location;
	// Build: { checkFn($result_N); $result_N.value; }
	const checkCall = makeCall(makeIdent(checkFnName, loc), [resultObj], loc);
	const checkStmt = makeExprStmt(checkCall, loc);
	// The original member access becomes the last expression in the block
	// For now, just return the check + original as a block
	return makeBlock([checkStmt, makeExprStmt(accessNode, loc)], loc);
}

// ===== Tests =====

testGroup("Result Field Check", () => {
	test("non-member unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerResultFieldCheck) === NodeKind.BinaryExpr);
	});
	test("regular member unchanged", () => {
		check(firstExprKindAfter("obj.name;", lowerResultFieldCheck) === NodeKind.MemberExpr);
	});
	test("non-result .value unchanged", () => {
		check(firstExprKindAfter("obj.value;", lowerResultFieldCheck) === NodeKind.MemberExpr);
	});
	test("passthrough for non-expr", () => {
		check(stmtCountAfter("const x = 1;", lowerResultFieldCheck) === 1);
	});
	test("call expr unchanged", () => {
		check(firstExprKindAfter("f();", lowerResultFieldCheck) === NodeKind.CallExpr);
	});
	test("identifier unchanged", () => {
		check(firstExprKindAfter("x;", lowerResultFieldCheck) === NodeKind.Identifier);
	});
});
