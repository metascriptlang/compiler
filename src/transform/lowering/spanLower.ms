// Span Lowering - Transforms HiddenStdConv (Array -> Span) into explicit struct initializers
//
// Pattern: standard reference implementation (handled during emission, but moved to Transform)
//
// Array -> Span: ObjectLiteral(SpanType, { data: arr.p->data, len: arr.len })
// SizedArray -> Span: ObjectLiteral(SpanType, { data: arr.data, len: N })
//
// Also handles:
// - Zero-copy slicing: arr[start..end] with Span result → { data: arr.data + start, len: end - start }
// - Stack-promoted literals: HiddenStdConv(ArrayLiteral, Span<T>) → SizedArray temp on stack

import { Node, NodeKind, DeclKind, HiddenStdConvData, ArrayAccessData, BinaryExprData, ArrayLiteralData, CallExprData, VariableDeclData, Type, TypeKind } from "../../ast/node";
import { createSizedArray, createPtr } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { walkNode } from "../walker";
import {
	makeMember, makeTypedObjectLiteral, makeNumber, makeBinary, makeCall, makeIdent,
	makeVarDecl, makeIdentResolved, makeHiddenAddr, makeObjectLiteral,
	makeConditional, makeNull, makeHiddenStdConv,
} from "../util";

export function spanLower(program: Node, ctx: TransformContext): Node {
	walkNode(program, wrapSpanCoercions);
	return walkNode(program, (node: Node): Node => {
		// Zero-copy slicing: ArrayAccess with range index and Span result type
		if (node.kind === NodeKind.ArrayAccess) {
			return lowerRangeAccess(node, ctx);
		}

		if (node.kind === NodeKind.HiddenStdConv || node.kind === NodeKind.HiddenSubConv) {
			const d = node.data as HiddenStdConvData;
			const targetType = d.convType;
			if (targetType === null) return node;

			// Unwrap Var/out modifier — reference parity: var openArray → openArray
			let spanTarget = targetType;
			if (spanTarget.kind === TypeKind.Var || spanTarget.kind === TypeKind.Sink || spanTarget.kind === TypeKind.Lent) {
				spanTarget = spanTarget.typeReturn;
			}
			if (spanTarget.kind === TypeKind.Span) {
				let srcType = d.convExpr.nodeType;
				if (srcType !== null && srcType.kind === TypeKind.Ref && srcType.typeReturn !== null) srcType = srcType.typeReturn;
				if (srcType !== null) {
					const loc = node.location;

					// Stack-promoted literal: [1,2,3] → Span → SizedArray temp on stack
					if (d.convExpr.kind === NodeKind.ArrayLiteral) {
						return lowerLiteralToSpan(d.convExpr, targetType, ctx);
					}

					if (srcType.kind === TypeKind.Array) {
						const dataExpr = makeCall(makeIdent("msArrDataOr0", loc), [makeMember(d.convExpr, "p", loc)], loc);
						dataExpr.nodeType = createPtr(spanTarget.typeReturn);
						const lenExpr = makeMember(d.convExpr, "length", loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], targetType, loc);
					} else if (srcType.kind === TypeKind.SizedArray) {
						// SizedArray -> Span: { data: arr.data, len: N }
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeNumber(srcType.typeFlags, loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], targetType, loc);
					} else if (srcType.kind === TypeKind.String) {
						// String -> Span<char>: { data: str.data, len: str.len }
						const dataExpr2 = makeMember(d.convExpr, "data", loc);
						const lenExpr2 = makeMember(d.convExpr, "len", loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr2, lenExpr2], targetType, loc);
					}
				}
			}

			// Borrow promotion: HiddenStdConv(expr, Borrow<T>) → HiddenAddr(expr) (takes &expr in C)
			if (targetType.kind === TypeKind.Borrow) {
				const loc = node.location;
				const addr = makeHiddenAddr(d.convExpr, loc);
				addr.nodeType = targetType;
				return addr;
			}
		}

		return node;
	});
}

function calleeFnType(node: Node): Type {
	if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
		const t = node.resolvedSym.symbolType;
		if (t.kind === TypeKind.Function) return t;
	}
	const cd = node.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType;
	}
	return null as unknown as Type;
}

function isSpanValued(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Span) return true;
	if ((t.kind === TypeKind.Var || t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) && t.typeReturn !== null) {
		return t.typeReturn.kind === TypeKind.Span;
	}
	return false;
}

function wrapSpanCoercions(node: Node): Node {
	if (node.kind === NodeKind.VariableDecl) return wrapSpanDeclInit(node);
	if (node.kind === NodeKind.BinaryExpr) return wrapSpanAssign(node);
	if (node.kind !== NodeKind.CallExpr) return node;
	const fnType = calleeFnType(node);
	if (fnType === null) return node;
	const cd = node.data as CallExprData;
	let i = 0;
	while (i < cd.arguments.length) {
		if (i < fnType.typeChildren.length) {
			const formal = fnType.typeChildren[i];
			if (formal !== null && formal.kind === TypeKind.Span && formal.typeReturn !== null) {
				const arg = cd.arguments[i];
				if (arg !== null && arg.kind !== NodeKind.HiddenStdConv && arg.kind !== NodeKind.HiddenSubConv
						&& arg.nodeType !== null && !isSpanValued(arg.nodeType)) {
					cd.arguments[i] = makeHiddenStdConv(arg, formal, arg.location);
				}
			}
		}
		i = i + 1;
	}
	return node;
}

function wrapSpanAssign(node: Node): Node {
	const bd = node.data as BinaryExprData;
	if (bd.operator !== "=") return node;
	if (bd.left.nodeType === null || bd.left.nodeType.kind !== TypeKind.Span || bd.left.nodeType.typeReturn === null) return node;
	const rhs = bd.right;
	if (rhs !== null && rhs.kind !== NodeKind.HiddenStdConv && rhs.kind !== NodeKind.HiddenSubConv
			&& rhs.nodeType !== null && !isSpanValued(rhs.nodeType)) {
		bd.right = makeHiddenStdConv(rhs, bd.left.nodeType, rhs.location);
	}
	return node;
}

function wrapSpanDeclInit(node: Node): Node {
	let declType = node.nodeType;
	if (declType === null && node.resolvedSym !== null) declType = node.resolvedSym.symbolType;
	if (declType === null || declType.kind !== TypeKind.Span || declType.typeReturn === null) return node;
	const vd = node.data as VariableDeclData;
	const init = vd.initializer;
	if (init !== null && init.kind !== NodeKind.HiddenStdConv && init.kind !== NodeKind.HiddenSubConv
			&& init.nodeType !== null && !isSpanValued(init.nodeType)) {
		vd.initializer = makeHiddenStdConv(init, declType, init.location);
	}
	return node;
}

// ===== Zero-Copy Slicing =====
// arr[start..end] where nodeType is Span → { data: arr.data + start, len: end - start }

function lowerRangeAccess(node: Node, ctx: TransformContext): Node {
	const d = node.data as ArrayAccessData;

	// Only handle range index (BinaryExpr with ".." or "..." operator)
	if (d.index.kind !== NodeKind.BinaryExpr) return node;
	const bd = d.index.data as BinaryExprData;
	if (bd.operator !== ".." && bd.operator !== "...") return node;

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
	} else if (arrType.kind === TypeKind.String) {
		// String: str.data + start (nativeLower rewrites .data to .p->data for Strings)
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

	// len = end - start (exclusive ..) or (end - start) + 1 (inclusive ...)
	let lenExpr = makeBinary(endExpr, "-", startExpr, loc);
	if (bd.operator === "...") {
		lenExpr = makeBinary(lenExpr, "+", makeNumber(1, loc), loc);
	}

	return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], resultType, loc);
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
		return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], spanType, loc);
	}

	const loc = literal.location;
	const elemType = spanType.typeReturn;

	// Create SizedArray type: T[N]
	const sizedType = createSizedArray(elemType, elemCount);

	// Set the literal's nodeType to SizedArray so nativeLower skips heap allocation
	literal.nodeType = sizedType;

	// Create a temp variable: const $span_lit_N: T[elemCount] = [elements...]
	const sym = freshTempSym(ctx, "span_lit", sizedType);
	const tempDecl = makeVarDecl(sym.name, literal, DeclKind.Const, loc);
	tempDecl.resolvedSym = sym;
	tempDecl.nodeType = sizedType;

	// Create Span view of the temp: { data: temp.data, len: N }
	const tempRef = makeIdentResolved(sym, loc);
	const dataExpr = makeMember(tempRef, "data", loc);
	const lenExpr = makeNumber(elemCount, loc);
	const spanInit = makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], spanType, loc);

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
