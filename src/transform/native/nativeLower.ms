// Native Access Lowering — rewrite typed array/string access to runtime macro calls
// Runs AFTER DRC (which needs ArrayAccess for RC operations), BEFORE codegen.
//
// Rewrites:
//   arr[i]    on number[]     →  CallExpr("msNumberArrayAccess", [arr, i])
//   arr[i]    on string[]     →  CallExpr("msStringArrayAccess", [arr, i])
//   arr[i]    on ref[]        →  CallExpr("msRefArrayAccess", [arr, i])
//   arr[i]    on SizedArray   →  CallExpr("msSizedArrayAccess", [arr, i, size])
//   arr[i]    on Span         →  CallExpr("msSpanAccess", [arr, i])
//   s[i]      on string       →  CallExpr("msStringCharAccess", [s, i])
//   x.length  on array/string →  x.len  (property mutation)
//
// Runtime macros are GCC statement expressions returning lvalues (read + write).

import {
	Node, NodeKind,
	ArrayAccessData, MemberExprData,
} from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber } from "../util";

// ===== Main Entry Point =====

export function lowerNativeAccess(program: Node, ctx: TransformContext): Node {
	walkNode(program, rewriteAccess);
	return program;
}

// ===== Rewriter =====

function rewriteAccess(node: Node): Node {
	if (node.kind === NodeKind.ArrayAccess) return rewriteArrayAccess(node);
	if (node.kind === NodeKind.MemberExpr) return rewriteMemberExpr(node);
	return node;
}

// ===== Array/String Index Access =====

function rewriteArrayAccess(node: Node): Node {
	const d = node.data as ArrayAccessData;
	const arrType = d.array.nodeType;
	if (arrType === null) return node;

	const loc = node.location;

	if (arrType.kind === TypeKind.Array) {
		const elemType = arrType.typeReturn;
		const macroName = getArrayMacroName(elemType);
		const result = makeCall(makeIdent(macroName, loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind === TypeKind.SizedArray) {
		const size = arrType.typeFlags;
		const result = makeCall(makeIdent("msSizedArrayAccess", loc), [d.array, d.index, makeNumber(size, loc)], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind === TypeKind.Span) {
		const result = makeCall(makeIdent("msSpanAccess", loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind === TypeKind.String) {
		const result = makeCall(makeIdent("msStringCharAccess", loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	return node;
}

// Determine macro name from array element type
function getArrayMacroName(elemType: Type): string {
	if (elemType === null) return "msRefArrayAccess";
	if (elemType.kind === TypeKind.Number) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.Int32) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.Int64) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.Uint32) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.Float32) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.Float64) return "msNumberArrayAccess";
	if (elemType.kind === TypeKind.String) return "msStringArrayAccess";
	return "msRefArrayAccess";
}

// ===== Property Remapping =====

function rewriteMemberExpr(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property !== "length") return node;

	const objType = d.object.nodeType;
	if (objType === null) return node;

	if (objType.kind === TypeKind.Array || objType.kind === TypeKind.SizedArray ||
		objType.kind === TypeKind.Span || objType.kind === TypeKind.String) {
		d.property = "len";
	}
	return node;
}

// Tests stripped — require reference compiler (test "name" { } keyword form needs fix)
