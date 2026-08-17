// Integer division materialization (JS backend) — docs/JS-NUMERIC.md §5.
//
// MS spells integer and float division with the same `/`, so which one is meant
// is only knowable from the operand types — see docs/NIM-REF.md, the row on the
// operator surface. C reads that type and truncates; JS is handed a double and
// keeps the fraction, so `7 / 2` was 3.5 and a digit loop `n = n / 10` decayed
// through denormals instead of reaching 0.
//
// Truncating is also the FAST path here: measured over 15 interleaved rounds,
// the bare `a / b` is 1.49x slower than every truncating form, because it
// accumulates doubles.
//
// Sibling of intConvJS.ms, which materializes the conversion nodes; both share
// its width table and both are gated on the JS backend. Tests live in
// src/test/js/intArith.ms — every decision here reads a resolved type, which a
// parse-only fixture cannot supply.

import { Node, NodeKind, BinaryExprData, IdentifierData, MemberExprData, ArrayAccessData, NumberLiteralData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeIdent, makeMember, makeArrayAccess, makeNumber } from "../util";
import { truncateTo, isIntConvKind } from "./intConvJS";

export function lowerIntArithJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, materializeIntDiv);
	return program;
}

function materializeIntDiv(node: Node): Node {
	if (node.kind !== NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator === "/") return divideAsInteger(node);
	if (d.operator === "/=") return compoundDivideAsInteger(node, d);
	return node;
}

function divideAsInteger(node: Node): Node {
	const t = node.nodeType;
	if (t === null || !isIntConvKind(t.kind)) return node;
	return truncateTo(node, t.kind, node.location);
}

// `a /= b` has no expression-level rewrite that stays correct for an arbitrary
// left side: the value has to be read as well as written, and reading it twice
// re-runs whatever the lvalue evaluates. Only side-effect-free shapes are
// rewritten; anything else keeps the untruncated `/=`, which docs/JS-NUMERIC.md
// records as the one hole left in this phase.
function compoundDivideAsInteger(node: Node, d: BinaryExprData): Node {
	const t = d.left.nodeType;
	if (t === null || !isIntConvKind(t.kind)) return node;
	const readBack = cloneIfPure(d.left);
	if (readBack === null) return node;
	const quotient = makeBinary(readBack, "/", d.right, node.location);
	quotient.nodeType = t;
	return makeBinary(d.left, "=", truncateTo(quotient, t.kind, node.location), node.location);
}

// A second read of the lvalue is only safe when re-evaluating it cannot call
// anything or move anything — identifiers, field chains over them, and indexes
// that are themselves identifiers or literals.
function cloneIfPure(node: Node): Node | null {
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const c = makeIdent(d.name, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const obj = cloneIfPure(d.object);
		if (obj === null) return null;
		const c = makeMember(obj, d.property, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const arr = cloneIfPure(d.array);
		if (arr === null) return null;
		const idx = cloneIfPure(d.index);
		if (idx === null) return null;
		const c = makeArrayAccess(arr, idx, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	if (node.kind === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const c = makeNumber(d.value, node.location);
		c.nodeType = node.nodeType;
		return c;
	}
	return null;
}
