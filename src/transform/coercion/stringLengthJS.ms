// String TS-tier coherence (JS backend) — LANG.md "The Index-Space Contract".
// JS strings are UTF-8 byte arrays, so the native property/index fall in BYTE
// space; the TS-named surface must be UTF-16 code units:
//   .length on String  → msStringLength(s)   (C routes via nativeLower, JS-only gap)
//   s[i]    on String  → charAt(s, i)        (C emits msStringArrayAccess already)
// Range access s[a..b] (Span<char>, byte tier) is left alone.

import { Node, NodeKind, MemberExprData, ArrayAccessData, BinaryExprData, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";

export function lowerStringLengthJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, rewriteStringTsTier);
	return program;
}

function rewriteStringTsTier(node: Node): Node {
	if (node.kind === NodeKind.MemberExpr) return rewriteLength(node);
	if (node.kind === NodeKind.ArrayAccess) return rewriteIndex(node);
	return node;
}

function rewriteLength(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property !== "length" && d.property !== "byteLength" && d.property !== "unicodeLength") return node;
	const objType = d.object.nodeType;
	if (objType === null || objType.kind !== TypeKind.String) return node;
	const callee = d.property === "length" ? "msStringLength" : d.property;
	const result = makeCall(makeIdent(callee, node.location), [d.object], node.location);
	result.nodeType = node.nodeType;
	return result;
}

function rewriteIndex(node: Node): Node {
	const d = node.data as ArrayAccessData;
	const objType = d.array.nodeType;
	if (objType === null || objType.kind !== TypeKind.String) return node;
	if (d.index.kind === NodeKind.BinaryExpr) {
		const bd = d.index.data as BinaryExprData;
		if (bd.operator === ".." || bd.operator === "...") return node;
	}
	const result = makeCall(makeIdent("charAt", node.location), [d.array, d.index], node.location);
	result.nodeType = node.nodeType;
	return result;
}
