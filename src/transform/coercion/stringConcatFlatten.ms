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
	Node, NodeKind, SourceLocation,
	BinaryExprData, StringLiteralData,
} from "../../ast/node";
import { TypeKind } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";
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
	// Non-string parts get wrapped in msNumberToString/msBoolToString.
	const loc = node.location;
	const countNode = makeNumber(parts.length, loc);
	const allArgs: Node[] = [countNode];
	for (const p of parts) {
		allArgs.push(coerceToString(p, loc));
	}
	return makeCall(makeIdent("msStringConcatMany", loc), allArgs, loc);
}

// Wrap non-string parts in conversion calls for C backend
function coerceToString(node: Node, loc: SourceLocation): Node {
	// Already a string literal — no conversion needed
	if (node.kind === NodeKind.StringLiteral) return node;
	// Check nodeType (set by checker) for numeric/boolean types
	if (node.nodeType !== null) {
		if (node.nodeType.kind === TypeKind.Number || node.nodeType.kind === TypeKind.Int32 ||
			node.nodeType.kind === TypeKind.Float32 || node.nodeType.kind === TypeKind.Float64) {
			return makeCall(makeIdent("msNumberToString", loc), [node], loc);
		}
		if (node.nodeType.kind === TypeKind.Boolean) {
			return makeCall(makeIdent("msNumberToString", loc), [node], loc);
		}
	}
	// Syntactic fallback: NumberLiteral → always numeric
	if (node.kind === NodeKind.NumberLiteral) {
		return makeCall(makeIdent("msNumberToString", loc), [node], loc);
	}
	return node;
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
test "variable addition unchanged" { expect(firstExprKindAfter("x + y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr); }

test "non-binary unchanged" { expect(firstExprKindAfter("f();", lowerStringConcatFlatten) === NodeKind.CallExpr); }

test "single stmt passthrough" { expect(stmtCountAfter("const x = 1;", lowerStringConcatFlatten) === 1); }

test "non-string binary unchanged" { expect(firstExprKindAfter("x * y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr); }

test "identifier unchanged" { expect(firstExprKindAfter("x;", lowerStringConcatFlatten) === NodeKind.Identifier); }

test "two-part string stays binary" {
	// "a" + x is only 2 parts — no benefit from flattening
	expect(firstExprKindAfter("\"a\" + x;", lowerStringConcatFlatten) === NodeKind.BinaryExpr);
}
