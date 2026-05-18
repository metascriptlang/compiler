// Result Field Check — wraps $result_N.value/.error with discriminant safety checks
// Follows reference implementation pattern for checked field expressions
//
// $result_0.value  →  { msResultCheckValue($result_0); $result_0.value; }
// $result_0.error  →  { msResultCheckError($result_0); $result_0.error; }
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
		"value" => wrapWithCheck(node, d.object, "msResultCheckValue"),
		"error" => wrapWithCheck(node, d.object, "msResultCheckError"),
		_ => node,
	};
}

function isResultTemp(name: string): boolean {
	return name.startsWith("$result");
}

function wrapWithCheck(accessNode: Node, resultObj: Node, checkFnName: string): Node {
	const loc = accessNode.location;
	// Build: { checkFn($result_N); $result_N.value; }
	const checkCall = makeCall(makeIdent(checkFnName, loc), [resultObj], loc);
	const checkStmt = makeExprStmt(checkCall, loc);
	// The original member access becomes the last expression in the block
	return makeBlock([checkStmt, makeExprStmt(accessNode, loc)], loc);
}

// ===== Tests =====
test "non-member unchanged" { assert firstExprKindAfter("x + y;", lowerResultFieldCheck) === NodeKind.BinaryExpr; }

test "regular member unchanged" { assert firstExprKindAfter("obj.name;", lowerResultFieldCheck) === NodeKind.MemberExpr; }

test "non-result .value unchanged" { assert firstExprKindAfter("obj.value;", lowerResultFieldCheck) === NodeKind.MemberExpr; }

test "passthrough for non-expr" { assert stmtCountAfter("const x = 1;", lowerResultFieldCheck) === 1; }

test "call expr unchanged" { assert firstExprKindAfter("f();", lowerResultFieldCheck) === NodeKind.CallExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerResultFieldCheck) === NodeKind.Identifier; }
