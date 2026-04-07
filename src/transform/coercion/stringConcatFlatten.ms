// String Concat Flatten — flattens nested string + chains into single concat call
// Follows reference string_concat_flatten.zig + standard reference transform pattern
//
// "hello " + name + "!"   →   msStringConcat(msStringConcat("hello ", name), "!")
// x + y                   →   x + y  (unchanged — can't prove string without type info)
//
// Conservative: only flattens when at least one operand is a StringLiteral.
// This guarantees the + chain is string concatenation (JS/TS coercion rules).
// Chains of length 2 are left as binary (no benefit from flattening).

import { Node, NodeKind, SourceLocation, BinaryExprData, CallExprData, IdentifierData, collectConcatParts } from "../../ast/node";
import { stringType, isStringLike } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber, makeMember } from "../util";
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
	const parts = collectConcatParts(node);

	// Only flatten if at least one part is a string literal or has string type
	let hasString = false;
	let hasNonString = false;
	for (const p of parts) {
		if (p.kind === NodeKind.StringLiteral) {
			hasString = true;
		} else if (p.nodeType !== null && isStringLike(p.nodeType)) {
			hasString = true;
		} else if (p.kind === NodeKind.CallExpr) {
			// Already-flattened msStringConcatMany call is a string
			const cd = p.data as CallExprData;
			if (cd.callee.kind === NodeKind.Identifier) {
				const cn = (cd.callee.data as IdentifierData).name;
				if (cn === "msStringConcatMany" || cn === "msStringConcat") hasString = true;
			}
		}
		if (needsCoercion(p)) hasNonString = true;
	}
	if (!hasString) return node;

	const loc = node.location;

	// 2-part: use msStringConcat(a, b) — still need coercion for non-string parts
	if (parts.length === 2) {
		if (!hasNonString) return node; // both strings, binary + is fine
		const args: Node[] = [coerceToString(parts[0], loc), coerceToString(parts[1], loc)];
		const call2 = makeCall(makeIdent("msStringConcat", loc), args, loc);
		call2.nodeType = stringType();
		return call2;
	}

	// 3+ parts: msStringConcatMany(N, a, b, c, ...)
	const countNode = makeNumber(parts.length, loc);
	const allArgs: Node[] = [countNode];
	for (const p of parts) {
		allArgs.push(coerceToString(p, loc));
	}
	const callN = makeCall(makeIdent("msStringConcatMany", loc), allArgs, loc);
	callN.nodeType = stringType();
	return callN;
}

// Check if a node needs string coercion (is non-string in a string concat context)
function needsCoercion(node: Node): boolean {
	if (node.kind === NodeKind.StringLiteral) return false;
	if (node.kind === NodeKind.NumberLiteral) return true;
	if (node.nodeType !== null) {
		if (isStringLike(node.nodeType)) return false;
		// Any non-string typed value needs coercion
		return true;
	}
	return false;
}

// Wrap non-string parts in .toString() calls — builtinLower/extensionMethodLower resolve later
function coerceToString(node: Node, loc: SourceLocation): Node {
	if (node.kind === NodeKind.StringLiteral) return node;
	if (node.nodeType !== null && isStringLike(node.nodeType)) return node;
	// Already-coerced string concat calls — no double-wrapping
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee.kind === NodeKind.Identifier) {
			const cn = (cd.callee.data as IdentifierData).name;
			if (cn === "msStringConcatMany" || cn === "msStringConcat") return node;
		}
	}
	// Emit obj.toString() — pipeline resolves: builtinLower(primitives/enum) → extensionMethodLower(user ext)
	const member = makeMember(node, "toString", loc);
	const call = makeCall(member, [], loc);
	call.nodeType = stringType();
	return call;
}


// ===== Tests =====
test "variable addition unchanged" { assert firstExprKindAfter("x + y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr; }

test "non-binary unchanged" { assert firstExprKindAfter("f();", lowerStringConcatFlatten) === NodeKind.CallExpr; }

test "single stmt passthrough" { assert stmtCountAfter("const x = 1;", lowerStringConcatFlatten) === 1; }

test "non-string binary unchanged" { assert firstExprKindAfter("x * y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerStringConcatFlatten) === NodeKind.Identifier; }

test "two-part string stays binary" {
	// "a" + x is only 2 parts — no benefit from flattening
	assert firstExprKindAfter("\"a\" + x;", lowerStringConcatFlatten) === NodeKind.BinaryExpr;
}
