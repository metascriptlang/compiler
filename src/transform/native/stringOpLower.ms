// String Operation Lowering — rewrite string operators to runtime function calls
// Moves business logic from codegen to transform phase (standard dumb codegen parity)
//
// Rewrites:
//   s == t       →  msStringEquals(s, t)
//   s !== t      →  !msStringEquals(s, t)
//   s == ""      →  s.length === 0        (optimization)
//   s < t        →  msStringCompare(s, t) < 0
//   s + t        →  msStringConcat(s, t)  (2-part; 3+ already handled by stringConcatFlatten)
//   s[i] = ch    →  msStringPrepareMutation(&s), msStringSetChar(&s, i, ch)
//
// Only runs for C backend (JS handles string ops natively).

import { Node, NodeKind, SourceLocation, BinaryExprData, ArrayAccessData, StringLiteralData, IdentifierData, MemberExprData, TypeKind } from "../../ast/node";
import { isNumeric } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeBinary, makeMember, makeUnary } from "../util";

// ===== Main Entry Point =====

export function lowerStringOps(program: Node, ctx: TransformContext): Node {
	walkNode(program, rewriteStringOp);
	return program;
}

// ===== Rewriter =====

function rewriteStringOp(node: Node): Node {
	if (node.kind !== NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;

	// String indexed assignment: s[i] = ch → msStringSetChar call
	if (d.operator === "=" && d.left.kind === NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		if (isStringTyped(ad.array)) {
			return rewriteStringIndexAssign(ad.array, ad.index, d.right, node);
		}
	}

	// String self-append: x = x + y → msStringAppend(&x, y)
	// Reference parity: standard compiler recognizes this pattern and rewrites to in-place append.
	// Avoids O(n) allocation per concat — uses amortized O(1) append with capacity growth.
	if (d.operator === "=" && d.right.kind === NodeKind.BinaryExpr) {
		const rd = d.right.data as BinaryExprData;
		if (rd.operator === "+" && isStringTyped(d.left) && isSameIdent(d.left, rd.left)) {
			const loc = node.location;
			const addrOf = makeUnary("&", d.left, loc);
			const right = coercePartToString(rd.right, loc);
			const result = makeCall(makeIdent("msStringAppend", loc), [addrOf, right], loc);
			result.nodeType = node.nodeType;
			return result;
		}
	}

	// Need at least one string-typed operand
	if (!isStringTyped(d.left) && !isStringTyped(d.right)) return node;

	const loc = node.location;

	// String equality/inequality/comparison: handled by operator overloads in prelude
	// (`==`, `<`, `<=` defined in .cms/.jms, found via lowerOperators extension registry)
	// Derived operators (!=, >, >=) auto-derived by lowerOperators.

	// String concatenation: s + t → msStringConcat(s, t)
	// Note: 3+ chains already handled by stringConcatFlatten (runs earlier)
	// Coerce non-string operands (number/boolean) to string
	if (d.operator === "+") {
		const left = coercePartToString(d.left, loc);
		const right = coercePartToString(d.right, loc);
		const result = makeCall(makeIdent("msStringConcat", loc), [left, right], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	// String compound assignment: s += t → msStringAppend(&s, t)
	// Reference parity: semantic analysis resolves &= to an append call with a hidden address.
	// We do the same rewrite here so DRC sees a normal call (no special-casing)
	// and codegen emits a normal call (no special-casing).
	if (d.operator === "+=" && isStringTyped(d.left)) {
		const addrOf = makeUnary("&", d.left, loc);
		const right = coercePartToString(d.right, loc);
		const result = makeCall(makeIdent("msStringAppend", loc), [addrOf, right], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	return node;
}

// ===== String Index Assignment =====
// s[i] = ch → (msStringPrepareMutation(&s), msStringSetChar(&s, i, ch))
// Produces a comma expression wrapped in parentheses

function rewriteStringIndexAssign(arr: Node, idx: Node, val: Node, original: Node): Node {
	const loc = original.location;
	// Build: msStringSetChar(s, i, ch) — codegen will handle & for the first arg
	// since mutating methods use the & prefix convention
	const setCall = makeCall(makeIdent("msStringSetChar", loc), [arr, idx, val], loc);
	setCall.nodeType = original.nodeType;
	return setCall;
}

// ===== Helpers =====

// Coerce non-string operands in string concat context
function coercePartToString(node: Node, loc: SourceLocation): Node {
	if (node.kind === NodeKind.StringLiteral) return node;
	if (node.nodeType !== null && node.nodeType.kind === TypeKind.String) return node;
	if (node.nodeType !== null) {
		if (isNumeric(node.nodeType)) {
			return makeCall(makeIdent("msNumberToString", loc), [node], loc);
		}
		if (node.nodeType.kind === TypeKind.Boolean) {
			return makeCall(makeIdent("msBoolToString", loc), [node], loc);
		}
	}
	if (node.kind === NodeKind.NumberLiteral) {
		return makeCall(makeIdent("msNumberToString", loc), [node], loc);
	}
	return node;
}

function isStringTyped(node: Node): boolean {
	if (node === null) return false;
	if (node.nodeType === null) return false;
	return node.nodeType.kind === TypeKind.String;
}

// Check if two nodes refer to the same identifier (by name) or same member access chain.
function isSameIdent(a: Node, b: Node): boolean {
	if (a === null || b === null) return false;
	if (a.kind !== b.kind) return false;
	if (a.kind === NodeKind.Identifier) {
		return (a.data as IdentifierData).name === (b.data as IdentifierData).name;
	}
	if (a.kind === NodeKind.MemberExpr) {
		const ad = a.data as MemberExprData;
		const bd = b.data as MemberExprData;
		return ad.property === bd.property && isSameIdent(ad.object, bd.object);
	}
	return false;
}

function isEmptyStringLiteral(node: Node): boolean {
	if (node.kind !== NodeKind.StringLiteral) return false;
	const d = node.data as StringLiteralData;
	return d.value === "";
}

import { createNode } from "../../ast/node";
import { createToken, TokenKind } from "../../lexer/token";

function makeNumberLit(val: number, loc: SourceLocation): Node {
	const tok = createToken(TokenKind.Number, val.toString(), loc.line);
	return createNode(NodeKind.NumberLiteral, { value: val, isFloat: val % 1 !== 0 }, tok);
}
