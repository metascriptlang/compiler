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
// Self-append fast paths (route to in-place amortized append):
//   x = x + y                         → msStringAppend(&x, y)
//   x += y                            → msStringAppend(&x, y)
//   x = msStringConcat(x, p)          → msStringAppend(&x, p)
//   x = msStringConcatArr(N, x, ...)  → msStringAppendArr(&x, N-1, ...)
//                                       (covers `x + a + b + c` chains and
//                                        `` `${x}${a}${b}` `` templates that
//                                        stringConcatFlatten already flattened)
//
// isSameIdent handles Identifier, MemberExpr, ArrayAccess, NumberLiteral —
// conservative syntactic match. Side-effecting indexes (arr[i++]) fall through.

import { Node, NodeKind, SourceLocation, BinaryExprData, ArrayAccessData, StringLiteralData, IdentifierData, MemberExprData, NumberLiteralData, CallExprData, HiddenDerefData, TypeKind } from "../../ast/node";
import { isNumeric, isStringLike } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeUnary, makeNumber } from "../util";

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

	// Post-flatten self-append: stringConcatFlatten (runs before this pass) turned
	// `x = x + a + b + c` and `x = `${x}${a}${b}`` into `x = msStringConcatArr(N, x, ...)`
	// or the 2-part coerced form `x = msStringConcat(x, p)`. Detect those shapes
	// AFTER flattening so the fast path still fires for chains and templates.
	if (d.operator === "=" && isStringTyped(d.left) && d.right.kind === NodeKind.CallExpr) {
		const cd = d.right.data as CallExprData;
		if (cd.callee.kind === NodeKind.Identifier) {
			const calleeName = (cd.callee.data as IdentifierData).name;
			const loc = node.location;
			// msStringConcat(x, p) — 2-part with self-first → msStringAppend(&x, p)
			if (calleeName === "msStringConcat" && cd.arguments.length === 2
					&& isSameIdent(d.left, cd.arguments[0])) {
				const addrOf = makeUnary("&", d.left, loc);
				const result = makeCall(makeIdent("msStringAppend", loc),
						[addrOf, cd.arguments[1]], loc);
				result.nodeType = node.nodeType;
				return result;
			}

			// msStringConcatArr(count, x, a, b, ...) — N-part with self-first
			// → msStringAppendArr(&x, N-1, a, b, ...)
			if (calleeName === "msStringConcatArr" && cd.arguments.length >= 3
					&& isSameIdent(d.left, cd.arguments[1])) {
				const newCount = cd.arguments.length - 2;
				const addrOf = makeUnary("&", d.left, loc);
				const newArgs: Node[] = [addrOf, makeNumber(newCount, loc)];
				let i = 2;
				while (i < cd.arguments.length) {
					newArgs.push(cd.arguments[i]);
					i += 1;
				}
				const result = makeCall(makeIdent("msStringAppendArr", loc), newArgs, loc);
				result.nodeType = node.nodeType;
				return result;
			}
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
	return isStringLike(node.nodeType);
}

// Check if two nodes refer to the same lvalue path (syntactic equality).
// Handles Identifier, MemberExpr, ArrayAccess, NumberLiteral — the shapes
// that appear in lvalue chains without side effects. Side-effecting forms
// (CallExpr, UpdateExpr like i++, assignment-as-expression) return false
// so the caller never rewrites something with a hidden side effect.
//
// HiddenDeref / HiddenAddr are transparent wrappers the checker inserts for
// Ref<Struct> field access (e.g. on interface[]). Unwrap them at the start
// so `arr[0].buf` on both sides compares as equal even when one side has
// the hidden node and the other has been freshly synthesized.
function isSameIdent(a: Node, b: Node): boolean {
	while (a !== null && (a.kind === NodeKind.HiddenDeref || a.kind === NodeKind.HiddenAddr)) {
		a = (a.data as HiddenDerefData).expr;
	}
	while (b !== null && (b.kind === NodeKind.HiddenDeref || b.kind === NodeKind.HiddenAddr)) {
		b = (b.data as HiddenDerefData).expr;
	}
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
	if (a.kind === NodeKind.ArrayAccess) {
		const ad = a.data as ArrayAccessData;
		const bd = b.data as ArrayAccessData;
		return isSameIdent(ad.array, bd.array) && isSameIdent(ad.index, bd.index);
	}
	if (a.kind === NodeKind.NumberLiteral) {
		const ad = a.data as NumberLiteralData;
		const bd = b.data as NumberLiteralData;
		return ad.value === bd.value;
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
