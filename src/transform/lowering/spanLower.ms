// Span Lowering - Transforms HiddenStdConv (Array -> Span) into explicit struct initializers
//
// Pattern: Nim's lowerOpenArray in ccgexprs.nim (handled during emission, but we move to Transform)
//
// Array -> Span: ObjectLiteral(SpanType, { data: arr.p->data, len: arr.len })
// SizedArray -> Span: ObjectLiteral(SpanType, { data: arr.data, len: N })
//
// Also handles:
// - Zero-copy slicing: arr[start..end] with Span result → { data: arr.data + start, len: end - start }
// - Stack-promoted literals: HiddenStdConv(ArrayLiteral, Span<T>) → SizedArray temp on stack

import {
	Node, NodeKind, DeclKind,
	HiddenStdConvData, ArrayAccessData, BinaryExprData,
	ArrayLiteralData, BlockStmtData,
} from "../../ast/node";
import { Type, TypeKind, createSizedArray, createPtr } from "../../checker/types";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import {
	makeMember, makeObjectLiteral, makeNumber, makeBinary,
	makeVarDecl, makeTypedIdent,
} from "../util";

export function spanLower(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		// Zero-copy slicing: ArrayAccess with range index and Span result type
		if (node.kind === NodeKind.ArrayAccess) {
			return lowerRangeAccess(node, ctx);
		}

		if (node.kind === NodeKind.HiddenStdConv || node.kind === NodeKind.HiddenSubConv) {
			const d = node.data as HiddenStdConvData;
			const targetType = d.convType;
			if (targetType === null) return node;

			if (targetType.kind === TypeKind.Span) {
				const srcType = d.convExpr.nodeType;
				if (srcType !== null) {
					const loc = node.location;

					// Stack-promoted literal: [1,2,3] → Span → SizedArray temp on stack
					if (d.convExpr.kind === NodeKind.ArrayLiteral) {
						return lowerLiteralToSpan(d.convExpr, targetType, ctx);
					}

					if (srcType.kind === TypeKind.Array) {
						// Array -> Span: { data: arr.p->data, len: arr.len }
						// Note: C backend handles .p->data for Array member access
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeMember(d.convExpr, "length", loc);
						const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
						spanInit.nodeType = targetType;
						return spanInit;
					} else if (srcType.kind === TypeKind.SizedArray) {
						// SizedArray -> Span: { data: arr.data, len: N }
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeNumber(srcType.typeFlags, loc);
						const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
						spanInit.nodeType = targetType;
						return spanInit;
					}
				}
			}
		}
		return node;
	});
}

// ===== Zero-Copy Slicing =====
// arr[start..end] where nodeType is Span → { data: arr.data + start, len: end - start }

function lowerRangeAccess(node: Node, ctx: TransformContext): Node {
	const d = node.data as ArrayAccessData;

	// Only handle range index (BinaryExpr with ".." operator)
	if (d.index.kind !== NodeKind.BinaryExpr) return node;
	const bd = d.index.data as BinaryExprData;
	if (bd.operator !== "..") return node;

	// Only handle when result type is Span
	const resultType = node.nodeType;
	if (resultType === null || resultType.kind !== TypeKind.Span) return node;

	const arrType = d.array.nodeType;
	if (arrType === null) return node;

	const loc = node.location;
	const startExpr = bd.left;
	const endExpr = bd.right;

	// Build data pointer: arr.data + start (pointer arithmetic in C)
	let dataBase: Node = null as unknown as Node;
	if (arrType.kind === TypeKind.Array) {
		// Heap array: arr.p->data + start (nativeLower rewrites .data to .p->data for Arrays)
		dataBase = makeMember(d.array, "data", loc);
	} else if (arrType.kind === TypeKind.SizedArray || arrType.kind === TypeKind.Span) {
		// Stack array or span: arr.data + start
		dataBase = makeMember(d.array, "data", loc);
	} else {
		return node;
	}

	// data = base + start
	const dataExpr = makeBinary(dataBase, "+", startExpr, loc);
	// Set pointer type for correct C emission
	if (resultType.typeReturn !== null) {
		dataExpr.nodeType = createPtr(resultType.typeReturn);
	}

	// len = end - start
	const lenExpr = makeBinary(endExpr, "-", startExpr, loc);

	const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
	spanInit.nodeType = resultType;
	return spanInit;
}

// ===== Stack-Promoted Literals =====
// HiddenStdConv(ArrayLiteral, Span<T>) → synthetic SizedArray on stack + Span view
//
// Before: sum([1, 2, 3])  →  heap-allocate msNumberArray, take span
// After:  sum([1, 2, 3])  →  stack T[3] = {1,2,3}, pass (data, 3)

function lowerLiteralToSpan(literal: Node, spanType: Type, ctx: TransformContext): Node {
	const ld = literal.data as ArrayLiteralData;
	const elemCount = ld.elements.length;
	if (elemCount === 0) {
		// Empty literal → null span
		const loc = literal.location;
		const dataExpr = makeNumber(0, loc); // NULL pointer
		const lenExpr = makeNumber(0, loc);
		const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
		spanInit.nodeType = spanType;
		return spanInit;
	}

	const loc = literal.location;
	const elemType = spanType.typeReturn;

	// Create SizedArray type: T[N]
	const sizedType = createSizedArray(elemType, elemCount);

	// Set the literal's nodeType to SizedArray so nativeLower skips heap allocation
	literal.nodeType = sizedType;

	// Create a temp variable: const $span_lit_N: T[elemCount] = [elements...]
	const tempName = freshTemp(ctx, "span_lit");
	const tempDecl = makeVarDecl(tempName, literal, DeclKind.Const, loc);
	tempDecl.nodeType = sizedType;

	// Create Span view of the temp: { data: temp.data, len: N }
	const tempRef = makeTypedIdent(tempName, sizedType, loc);
	const dataExpr = makeMember(tempRef, "data", loc);
	const lenExpr = makeNumber(elemCount, loc);
	const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
	spanInit.nodeType = spanType;

	// Wrap in a block expression: { const temp = [...]; { data: temp.data, len: N } }
	// Since we can't easily create block expressions, we use a pattern where
	// the temp decl is hoisted by returning a special "compound" node.
	// For now, return the span init and rely on the temp being created at statement level.
	// The parent spanParamExpand will extract the ObjectLiteral fields.
	//
	// Alternative: attach the temp decl to the span init via a wrapper.
	// We'll use a BlockStmt wrapper that evaluates to the last expression.

	// Actually, the simplest approach: since spanParamExpand extracts ObjectLiteral
	// { data, len } fields, we embed the temp decl's initializer directly.
	// The SizedArray literal stays as the array, and we take .data/.len from it.
	// No temp needed — the C compound literal (T[N]){e1,e2,...} is addressable.

	// Direct approach: create span from the literal itself as a SizedArray
	const dataExpr2 = makeMember(literal, "data", loc);
	const lenExpr2 = makeNumber(elemCount, loc);
	const spanInit2 = makeObjectLiteral(["data", "len"], [dataExpr2, lenExpr2], loc);
	spanInit2.nodeType = spanType;
	return spanInit2;
}
