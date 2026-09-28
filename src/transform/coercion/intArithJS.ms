// Integer arithmetic materialization (JS backend) — docs/JS-NUMERIC.md §5.
//
// Two separate defects share this pass, because both are decided by the
// operand types and both are spelled with the same width table:
//
//   division — MS spells integer and float division with one `/`, so only the
//   type says which is meant. C truncates; JS kept the fraction, and a digit
//   loop `n = n / 10` decayed through denormals instead of reaching 0.
//
//   uint32 and the 8/16-bit widths — C wraps them (the 8/16-bit results are
//   cast back to their own width), while every JS operator hands back either an
//   int32 (bitwise, shifts) or an unbounded double (+ - *).
//
// Reference parity is deliberate and partial. The reference emits, for uint32,
// `(a OP b) >>> 0` for the bitwise trio, `~(a) >>> 0`, and — the trick worth
// copying — `a >>> b` for a right shift, substituting the OPERATOR because no
// trailing mask can undo an arithmetic shift of the int32 view. It also emits
// `(a * b) >>> 0` for multiplication, and that one is a defect measured against
// its own C backend: 4294967295² is 1 in C and 0 in JS. Math.imul is exact, so
// MS uses it. See NIM-REF CG-13.
//
// Signed overflow is deliberately absent: C-debug traps on it (measured, rc=255
// with a source location) and C-danger is undefined behaviour that is not even
// self-consistent — `+` did not wrap while `*` did. There is no value to match,
// so emitting a wrap here would invent a specification the C backend does not
// have. It belongs to the check tier.
//
// Tests: src/test/js/intArith.ms — every decision reads a resolved type, which
// a parse-only fixture cannot supply.

import { Node, NodeKind, BinaryExprData, UnaryExprData, UpdateExprData, IdentifierData, MemberExprData, ArrayAccessData, NumberLiteralData, BigIntLiteralData, HiddenDerefData, HiddenStdConvData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { peelToRepr, createPrimitive } from "../../checker/types";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, cloneIdent, runtimeRef, makeMember, makeArrayAccess, makeNumber, makeHiddenDeref, makeHiddenAddr } from "../util";
import { truncateTo, isIntConvKind } from "./intConvJS";

export function lowerIntArithJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => materializeIntOp(node, ctx));
	return program;
}

function materializeIntOp(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.UnaryExpr) return unaryAsUnsigned(node);
	if (node.kind == NodeKind.UpdateExpr) return updateAtWidth(node, ctx);
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	const base = compoundBaseOf(d.operator);
	if (base != "") return compoundAsInteger(node, d, base, ctx);
	if (d.operator == "/" || d.operator == "%" || d.operator == "**") return divideAsInteger(node, d);
	if (isShiftOp(d.operator) && subIntKind(d.left.nodeType) != TypeKind.Unknown) return shiftAtLeftWidth(node, d);
	const narrow = subIntKind(node.nodeType);
	if (narrow != TypeKind.Unknown && wrapsAtWidth(d.operator)) return wrapTo(node, narrow, node.location);
	return binaryAsUnsigned(node);
}

function divideAsInteger(node: Node, d: BinaryExprData): Node {
	const t = peelToRepr(node.nodeType);
	if (t == null || !isIntConvKind(t.kind)) return node;
	if (d.operator == "**" || !cannotRaise(d.right, t)) return checkedIntOp(d.operator, d.left, d.right, t, node.nodeType, node.location);
	if (d.operator != "/") return node;
	// BigInt division already truncates; Math.trunc on a BigInt throws.
	if (is64(t.kind)) return node;
	const narrow = subIntKind(t);
	if (narrow != TypeKind.Unknown) return wrapTo(node, narrow, node.location);
	return truncateTo(node, t.kind, node.location);
}

// The same helpers as C (runtime/core/checkedArith.h), declared for JS in
// std/core/system/index.jms: a zero divisor, MIN / -1 and an overflowing power raise.
function checkedIntOp(op: string, left: Node, right: Node, t: Type, resultType: Type | null, loc: SourceLocation): Node {
	const prefix = match (op) {
		"/" => "msDiv",
		"%" => "msMod",
		_ => "msPow",
	};
	const hk = is64(t.kind) ? t.kind : (isSignedKind(t.kind) ? TypeKind.Int32 : TypeKind.Uint32);
	const suffix = match (hk) {
		TypeKind.Int32 => "I32",
		TypeKind.Int64 => "I64",
		TypeKind.Uint32 => "U32",
		_ => "U64",
	};
	const call = makeCall(runtimeRef(prefix + suffix, loc), [left, right], loc);
	call.nodeType = createPrimitive(hk);
	const narrow = subIntKind(t);
	if (narrow != TypeKind.Unknown) return wrapTo(call, narrow, loc);
	if (resultType != null) call.nodeType = resultType;
	return call;
}

function is64(kind: TypeKind): boolean {
	return kind == TypeKind.Int64 || kind == TypeKind.Uint64;
}

function isSignedKind(kind: TypeKind): boolean {
	return kind == TypeKind.Int8 || kind == TypeKind.Int16 || kind == TypeKind.Int32 || kind == TypeKind.Int64;
}

// A literal divisor other than 0 and -1 can neither be zero nor overflow MIN / -1.
function cannotRaise(divisor: Node, t: Type): boolean {
	let n = divisor;
	while (n.kind == NodeKind.HiddenStdConv) n = (n.data as HiddenStdConvData).convExpr;
	if (n.kind == NodeKind.BigIntLiteral) {
		const text = (n.data as BigIntLiteralData).bigintValue;
		return text != "0n" && text != "-1n" && text.charAt(0) != "-";
	}
	if (n.kind != NodeKind.NumberLiteral) return false;
	const lit = n.data as NumberLiteralData;
	if (lit.isFloat || lit.intVal == 0) return false;
	return !(isSignedKind(t.kind) && lit.intVal == -1);
}

function subIntKind(t: Type | null): TypeKind {
	const r = peelToRepr(t);
	if (r == null) return TypeKind.Unknown;
	return match (r.kind) {
		TypeKind.Int8 | TypeKind.Uint8 | TypeKind.Int16 | TypeKind.Uint16 => r.kind,
		_ => TypeKind.Unknown,
	};
}

function subIntBits(kind: TypeKind): number {
	return kind == TypeKind.Int8 || kind == TypeKind.Uint8 ? 8 : 16;
}

function wrapsAtWidth(op: string): boolean {
	return op == "+" || op == "-" || op == "*";
}

function isShiftOp(op: string): boolean {
	return op == "<<" || op == ">>" || op == ">>>";
}

function wrapTo(inner: Node, kind: TypeKind, loc: SourceLocation): Node {
	if (kind == TypeKind.Uint8 || kind == TypeKind.Uint16) return truncateTo(inner, kind, loc);
	const up = 32 - subIntBits(kind);
	const result = makeBinary(makeBinary(inner, "<<", makeNumber(up, loc), loc), ">>", makeNumber(up, loc), loc);
	result.nodeType = createPrimitive(kind);
	return result;
}

// The count is masked to the left operand's width and the result wraps there,
// before it widens to the node's type, as C computes it.
function shiftAtLeftWidth(node: Node, d: BinaryExprData): Node {
	const kind = subIntKind(d.left.nodeType);
	const bits = subIntBits(kind);
	const loc = node.location;
	const count = makeBinary(d.right, "&", makeNumber(bits - 1, loc), loc);
	const unsigned = kind == TypeKind.Uint8 || kind == TypeKind.Uint16;
	if (d.operator == "<<") return wrapTo(makeBinary(d.left, "<<", count, loc), kind, loc);
	if (d.operator == ">>") return makeBinary(d.left, unsigned ? ">>>" : ">>", count, loc);
	if (unsigned) return makeBinary(d.left, ">>>", count, loc);
	const asUnsigned = makeBinary(d.left, "&", makeNumber(bits == 8 ? 255 : 65535, loc), loc);
	return wrapTo(makeBinary(asUnsigned, ">>>", count, loc), kind, loc);
}

function binaryAsUnsigned(node: Node): Node {
	const d = node.data as BinaryExprData;
	const t = peelToRepr(node.nodeType);
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
	const t = peelToRepr(node.nodeType);
	if (t == null) return node;
	const d = node.data as UnaryExprData;
	if (d.unaryOp != "-" && d.unaryOp != "~") return node;
	const narrow = subIntKind(t);
	if (narrow != TypeKind.Unknown) return wrapTo(node, narrow, node.location);
	if (t.kind != TypeKind.Uint32) return node;
	return truncateTo(node, t.kind, node.location);
}

// A postfix step reads back the value before the step: on a wrapping width that
// is the wrapped new value stepped back, so no temporary is needed.
function updateAtWidth(node: Node, ctx: TransformContext): Node {
	const d = node.data as UpdateExprData;
	const t = peelToRepr(d.updateArg.nodeType);
	if (t == null) return node;
	if (subIntKind(t) == TypeKind.Unknown && t.kind != TypeKind.Uint32) return node;
	const readBack = cloneIfPure(d.updateArg);
	if (readBack == null) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "integer '" + d.updateOp + "' needs an operand that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	const loc = node.location;
	const step = d.updateOp == "++" ? "+" : "-";
	const stored = makeBinary(d.updateArg, "=", atWidth(makeBinary(readBack, step, makeNumber(1, loc), loc), t, loc), loc);
	if (d.isPrefix) return stored;
	return atWidth(makeBinary(stored, d.updateOp == "++" ? "-" : "+", makeNumber(1, loc), loc), t, loc);
}

function atWidth(inner: Node, t: Type, loc: SourceLocation): Node {
	const narrow = subIntKind(t);
	return narrow != TypeKind.Unknown ? wrapTo(inner, narrow, loc) : truncateTo(inner, t.kind, loc);
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
	return makeCall(makeMember(runtimeRef("Math", loc), "imul", loc), [left, right], loc);
}

function compoundBaseOf(op: string): string {
	return match (op) {
		"/=" => "/",
		"%=" => "%",
		"+=" => "+",
		"-=" => "-",
		"*=" => "*",
		_ => "",
	};
}

export function needsIntegerCompoundRewrite(d: BinaryExprData): boolean {
	const base = compoundBaseOf(d.operator);
	if (base == "") return false;
	const t = peelToRepr(d.left.nodeType);
	if (t == null || !isIntConvKind(t.kind)) return false;
	if ((base == "/" || base == "%") && !cannotRaise(d.right, t)) return true;
	if (base == "%" || is64(t.kind)) return false;
	return base == "/" || t.kind == TypeKind.Uint32 || subIntKind(t) != TypeKind.Unknown;
}

function compoundAsInteger(node: Node, d: BinaryExprData, base: string, ctx: TransformContext): Node {
	if (!needsIntegerCompoundRewrite(d)) return node;
	const t = peelToRepr(d.left.nodeType);
	if (t == null) return node;
	const checked = (base == "/" || base == "%") && !cannotRaise(d.right, t);
	const unsigned = t.kind == TypeKind.Uint32;
	const narrow = subIntKind(t);
	const readBack = cloneIfPure(d.left);
	if (readBack == null) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "integer '" + base + "=' needs a left side that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	if (checked) return makeBinary(d.left, "=", checkedIntOp(base, readBack, d.right, t, d.left.nodeType, node.location), node.location);
	// makeBinary carries the left operand's type onto the result, which is what
	// keeps this synthesized node visible to the width table above.
	const widened = base == "*" && unsigned
		? exactMul(readBack, d.right, node.location)
		: makeBinary(readBack, base, d.right, node.location);
	const stored = narrow != TypeKind.Unknown ? wrapTo(widened, narrow, node.location) : truncateTo(widened, t.kind, node.location);
	return makeBinary(d.left, "=", stored, node.location);
}

// A second read of the lvalue is only safe when re-evaluating it cannot call
// anything or move anything — identifiers, field chains over them, and indexes
// that are themselves identifiers or literals.
export function cloneIfPure(node: Node): Node | null {
	if (node.kind == NodeKind.Identifier) {
		return cloneIdent(node, node.location);
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
