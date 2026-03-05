// String Concat Flatten — flattens nested string + chains into single concat call
// Follows reference string_concat_flatten.zig + Nim's transf pattern
//
// "hello " + name + "!"   →   msStringConcat(msStringConcat("hello ", name), "!")
// x + y                   →   x + y  (unchanged — can't prove string without type info)
//
// Conservative: only flattens when at least one operand is a StringLiteral.
// This guarantees the + chain is string concatenation (JS/TS coercion rules).
// Chains of length 2 are left as binary (no benefit from flattening).

import {
	Node, NodeKind,
	BinaryExprData, StringLiteralData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";
import { check } from "std/testing";
import { firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerStringConcatFlatten(program: Node, ctx: TransformContext): Node {
	walkNode(program, flattenConcat);
	return program;
}

function flattenConcat(node: Node): Node {
	if (node.kind !== NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator !== "+") return node;

	// Collect all parts of the + chain
	const parts: Node[] = [];
	collectParts(node, parts);

	// Only flatten if at least one part is a string literal (syntactic proof)
	let hasString = false;
	for (const p of parts) {
		if (p.kind === NodeKind.StringLiteral) {
			hasString = true;
		}
	}
	if (!hasString) return node;

	// 2-part concat is fine as binary — no benefit from call
	if (parts.length < 3) return node;

	// Build single variadic call: msStringConcatMany(N, a, b, c, ...)
	// One allocation, one pass — eliminates intermediate string allocations.
	const loc = node.location;
	const countNode = makeNumber(parts.length, loc);
	const allArgs: Node[] = [countNode];
	for (const p of parts) {
		allArgs.push(p);
	}
	return makeCall(makeIdent("msStringConcatMany", loc), allArgs, loc);
}

// Recursively collect parts from a left-associative + chain
function collectParts(node: Node, parts: Node[]): void {
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator === "+") {
			collectParts(d.left, parts);
			collectParts(d.right, parts);
			return;
		}
	}
	// Leaf node — add to parts
	parts.push(node);
}

// ===== Tests =====
test "variable addition unchanged" { check(firstExprKindAfter("x + y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr); }

test "non-binary unchanged" { check(firstExprKindAfter("f();", lowerStringConcatFlatten) === NodeKind.CallExpr); }

test "single stmt passthrough" { check(stmtCountAfter("const x = 1;", lowerStringConcatFlatten) === 1); }

test "non-string binary unchanged" { check(firstExprKindAfter("x * y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr); }

test "identifier unchanged" { check(firstExprKindAfter("x;", lowerStringConcatFlatten) === NodeKind.Identifier); }

test "two-part string stays binary" {
	// "a" + x is only 2 parts — no benefit from flattening
	check(firstExprKindAfter("\"a\" + x;", lowerStringConcatFlatten) === NodeKind.BinaryExpr);
}
