// Integer arithmetic materialization (JS backend) — docs/JS-NUMERIC.md §5.
//
// Two separate defects share this pass, because both are decided by the
// operand types and both are spelled with the same width table:
//
//   division — MS spells integer and float division with one `/`, so only the
//   type says which is meant. C truncates; JS kept the fraction, and a digit
//   loop `n = n / 10` decayed through denormals instead of reaching 0.
//
//   uint32 — C wraps mod 2^32, while every JS operator hands back either an
//   int32 (bitwise, shifts) or an unbounded double (+ - *). uint8/uint16 are
//   NOT in this pass: MS follows C's integer promotion, so `uint8 200+100` is
//   300 on both backends already. uint32 is the only width MS actually wraps.
//
// Reference parity is deliberate and partial. The reference emits, for uint32,
// `(a OP b) >>> 0` for the bitwise trio, `~(a) >>> 0`, and — the trick worth
// copying — `a >>> b` for a right shift, substituting the OPERATOR because no
// trailing mask can undo an arithmetic shift of the int32 view. It also emits
// `(a * b) >>> 0` for multiplication, and that one is a defect measured against
// its own C backend: 4294967295² is 1 in C and 0 in JS. Math.imul is exact, so
// MS uses it. See docs/NIM-REF.md for the row.
//
// Signed overflow is deliberately absent: C-debug traps on it (measured, rc=255
// with a source location) and C-danger is undefined behaviour that is not even
// self-consistent — `+` did not wrap while `*` did. There is no value to match,
// so emitting a wrap here would invent a specification the C backend does not
// have. It belongs to the check tier.
//
// Tests: src/test/js/intArith.ms — every decision reads a resolved type, which
// a parse-only fixture cannot supply.

import { Node, NodeKind, BinaryExprData, UnaryExprData, IdentifierData, MemberExprData, ArrayAccessData, NumberLiteralData, HiddenDerefData, SourceLocation, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeIdent, makeMember, makeArrayAccess, makeNumber, makeHiddenDeref, makeHiddenAddr } from "../util";
import { truncateTo, isIntConvKind } from "./intConvJS";

export function lowerIntArithJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => materializeIntOp(node, ctx));
	return program;
}

function materializeIntOp(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.UnaryExpr) return unaryAsUnsigned(node);
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	const base = compoundBaseOf(d.operator);
	if (base != "") return compoundAsInteger(node, d, base, ctx);
	if (d.operator == "/") return divideAsInteger(node);
	return binaryAsUnsigned(node);
}

function divideAsInteger(node: Node): Node {
	const t = node.nodeType;
	if (t == null || !isIntConvKind(t.kind)) return node;
	// BigInt division already truncates; Math.trunc on a BigInt throws.
	if (t.kind == TypeKind.Int64 || t.kind == TypeKind.Uint64) return node;
	return truncateTo(node, t.kind, node.location);
}

function binaryAsUnsigned(node: Node): Node {
	const d = node.data as BinaryExprData;
	const t = node.nodeType;
	if (t == null || t.kind != TypeKind.Uint32) return node;
	if (d.operator == ">>") {
		d.operator = ">>>";
		return node;
	}
	if (d.operator == "*") return truncateTo(exactMul(d.left, d.right, node.location), t.kind, node.location);
	if (!wrapsOnUint32(d.operator)) return node;
	return truncateTo(node, t.kind, node.location);
}

function unaryAsUnsigned(node: Node): Node {
	const t = node.nodeType;
	if (t == null || t.kind != TypeKind.Uint32) return node;
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "-" && d.unaryOp != "~") return node;
	return truncateTo(node, t.kind, node.location);
}

// `%` is absent on purpose: a remainder is bounded by its operands, so it never
// leaves the width. Comparisons and logical operators do not produce integers.
function wrapsOnUint32(op: string): boolean {
	return match (op) {
		"+" | "-" | "<<" => true,
		"&" | "|" | "^" => true,
		_ => false,
	};
}

// A double multiply of two uint32 operands can reach 2^64, and the low bits are
// already gone by the time any mask sees the result. Math.imul is an exact
// 32-bit multiply; it answers signed, so the width mask still follows.
function exactMul(left: Node, right: Node, loc: SourceLocation): Node {
	return makeCall(makeMember(makeIdent("Math", loc), "imul", loc), [left, right], loc);
}

function compoundBaseOf(op: string): string {
	return match (op) {
		"/=" => "/",
		"+=" => "+",
		"-=" => "-",
		"*=" => "*",
		_ => "",
	};
}

// `a OP= b` has no expression-level rewrite that stays correct for an arbitrary
// left side: the value has to be read as well as written, and reading it twice
// re-runs whatever the lvalue evaluates. Only side-effect-free shapes are
// rewritten; anything else would silently keep C's value and JS's, so it is
// refused by name instead.
function compoundAsInteger(node: Node, d: BinaryExprData, base: string, ctx: TransformContext): Node {
	const t = d.left.nodeType;
	if (t == null || !isIntConvKind(t.kind)) return node;
	if (t.kind == TypeKind.Int64 || t.kind == TypeKind.Uint64) return node;
	const unsigned = t.kind == TypeKind.Uint32;
	if (base != "/" && !unsigned) return node;
	const readBack = cloneIfPure(d.left);
	if (readBack == null) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "integer '" + base + "=' needs a left side that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	// makeBinary carries the left operand's type onto the result, which is what
	// keeps this synthesized node visible to the width table above.
	const widened = base == "*" && unsigned
		? exactMul(readBack, d.right, node.location)
		: makeBinary(readBack, base, d.right, node.location);
	return makeBinary(d.left, "=", truncateTo(widened, t.kind, node.location), node.location);
}

// A second read of the lvalue is only safe when re-evaluating it cannot call
// anything or move anything — identifiers, field chains over them, and indexes
// that are themselves identifiers or literals.
function cloneIfPure(node: Node): Node | null {
	if (node.kind == NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const c = makeIdent(d.name, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const obj = cloneIfPure(d.object);
		if (obj == null) return null;
		const c = makeMember(obj, d.property, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const arr = cloneIfPure(d.array);
		if (arr == null) return null;
		const idx = cloneIfPure(d.index);
		if (idx == null) return null;
		const c = makeArrayAccess(arr, idx, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	if (node.kind == NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const c = makeNumber(d.value, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	// A deref/addr wrapper evaluates nothing of its own, so re-reading it costs
	// exactly what re-reading its operand costs. conditionalExprLower walks the
	// same pair transparently when it hoists assignment-target effects.
	if (node.kind == NodeKind.HiddenDeref || node.kind == NodeKind.HiddenAddr) {
		const d = node.data as HiddenDerefData;
		const inner = cloneIfPure(d.expr);
		if (inner == null) return null;
		const c = node.kind == NodeKind.HiddenDeref ? makeHiddenDeref(inner, node.location) : makeHiddenAddr(inner, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	return null;
}
