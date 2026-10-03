// Span Lowering - Transforms HiddenStdConv (Array -> Span) into explicit struct initializers
//
// Pattern: standard reference implementation (handled during emission, but moved to Transform)
//
// Array -> Span: ObjectLiteral(SpanType, { data: arr.p->data, len: arr.len })
// SizedArray -> Span: ObjectLiteral(SpanType, { data: arr.data, len: N })
// String -> Span<char>: ObjectLiteral(SpanType, { data: str.p->data, len: str.len })
//
// Also handles:
// - Zero-copy slicing: arr[start..end] with Span result → { data: arr.data + start, len: end - start }
// - Stack-promoted literals: HiddenStdConv(ArrayLiteral, Span<T>) → SizedArray temp on stack

import { Node, NodeKind, DeclKind, HiddenStdConvData, ArrayAccessData, BinaryExprData, ArrayLiteralData, CallExprData, ObjectLiteralData, VariableDeclData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { createSizedArray, createPtr, createPrimitive, peelToStructOrUnion } from "../../checker/types";
import { takesAddressAtCArg, nonNullMemberOfNullable } from "../../checker/compat";
import { TransformContext, freshTempSym } from "../context";
import { walkNode } from "../walker";
import {
	makeMember, makeTypedObjectLiteral, makeNumber, makeBinary, makeCall, makeIdent,
	makeVarDecl, makeIdentResolved, makeHiddenAddr, makeObjectLiteral,
	makeConditional, makeNull, makeHiddenStdConv, runtimeRef, overloadWinner,
} from "../util";

export function spanLower(program: Node, ctx: TransformContext): Node {
	walkNode(program, wrapSpanCoercions);
	return walkNode(program, (node: Node): Node => {
		// Zero-copy slicing: ArrayAccess with range index and Span result type
		if (node.kind == NodeKind.ArrayAccess) {
			return ctx.jsBackend ? lowerRangeAccessJS(node) : lowerRangeAccess(node, ctx);
		}

		if (node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv) {
			const d = node.data as HiddenStdConvData;
			const targetType = d.convType;
			if (targetType == null) return node;

			// Unwrap Var/out modifier — reference parity: var openArray → openArray
			let spanTarget = targetType;
			if ((spanTarget.kind == TypeKind.Var || spanTarget.kind == TypeKind.Sink || spanTarget.kind == TypeKind.Lent) && spanTarget.typeReturn != null) {
				spanTarget = spanTarget.typeReturn;
			}
			if (spanTarget.kind == TypeKind.Span) {
				let srcType = d.convExpr.nodeType;
				if (srcType != null && srcType.kind == TypeKind.Ref && srcType.typeReturn != null) srcType = srcType.typeReturn;
				if (srcType != null && ctx.jsBackend) {
					const view = spanViewJS(d.convExpr, srcType, node.location);
					if (view != null) {
						view.nodeType = targetType;
						return view;
					}
				} else if (srcType != null) {
					const loc = node.location;

					// Stack-promoted literal: [1,2,3] → Span → SizedArray temp on stack
					if (d.convExpr.kind == NodeKind.ArrayLiteral) {
						return lowerLiteralToSpan(d.convExpr, targetType, ctx);
					}

					if (srcType.kind == TypeKind.Array) {
						const dataExpr = makeCall(runtimeRef("msArrDataOr0", loc), [makeMember(d.convExpr, "p", loc)], loc);
						dataExpr.nodeType = createPtr(spanTarget.typeReturn);
						const lenExpr = makeMember(d.convExpr, "length", loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], targetType, loc);
					} else if (srcType.kind == TypeKind.SizedArray) {
						// SizedArray -> Span: { data: arr.data, len: N }
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeNumber(srcType.typeValue, loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], targetType, loc);
					} else if (srcType.kind == TypeKind.String) {
						// String -> Span<char>: { data: msArrDataOr0(str.p), len: str.len }
						const dataExpr2 = makeCall(runtimeRef("msArrDataOr0", loc), [makeMember(d.convExpr, "p", loc)], loc);
						dataExpr2.nodeType = createPtr(spanTarget.typeReturn);
						const lenExpr2 = makeMember(d.convExpr, "len", loc);
						return makeTypedObjectLiteral(["data", "len"], [dataExpr2, lenExpr2], targetType, loc);
					}
				}
			}

			if (ctx.jsBackend) return node;
			// Borrow promotion: HiddenStdConv(expr, Borrow<T>) → HiddenAddr(expr) (takes &expr in C)
			if (targetType.kind == TypeKind.Borrow) {
				const loc = node.location;
				const addr = makeHiddenAddr(d.convExpr, loc);
				addr.nodeType = targetType;
				return addr;
			}
			if (takesAddressAtCArg(d.convExpr.nodeType, targetType)) {
				const addr = makeHiddenAddr(d.convExpr, node.location);
				addr.nodeType = nonNullMemberOfNullable(targetType);
				return addr;
			}
		}

		return node;
	});
}

function calleeFnType(node: Node): Type {
	const cd = node.data as CallExprData;
	if (node.resolvedSym != null) {
		const t = overloadWinner(node.resolvedSym, cd.resolvedOverloadIdx).symbolType;
		if (t != null && t.kind == TypeKind.Function) return t;
	}
	if (cd.callee != null && cd.callee.nodeType != null && cd.callee.nodeType.kind == TypeKind.Function) {
		return cd.callee.nodeType;
	}
	return null as unknown as Type;
}

function isSpanValued(t: Type): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Span) return true;
	if ((t.kind == TypeKind.Var || t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) && t.typeReturn != null) {
		return t.typeReturn.kind == TypeKind.Span;
	}
	return false;
}

function wrapSpanCoercions(node: Node): Node {
	if (node.kind == NodeKind.VariableDecl) return wrapSpanDeclInit(node);
	if (node.kind == NodeKind.BinaryExpr) return wrapSpanAssign(node);
	if (node.kind == NodeKind.ObjectLiteral) return wrapSpanObjectFields(node);
	if (node.kind != NodeKind.CallExpr) return node;
	const fnType = calleeFnType(node);
	if (fnType == null) return node;
	const cd = node.data as CallExprData;
	let i = 0;
	while (i < cd.arguments.length) {
		if (i < fnType.typeChildren.length) {
			const formal = fnType.typeChildren[i];
			if (formal != null && formal.kind == TypeKind.Span && formal.typeReturn != null) {
				const arg = cd.arguments[i];
				if (arg != null && arg.nodeType != null && !isSpanValued(arg.nodeType)) {
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
	if (bd.operator != "=") return node;
	if (bd.left.nodeType == null || bd.left.nodeType.kind != TypeKind.Span || bd.left.nodeType.typeReturn == null) return node;
	const rhs = bd.right;
	if (rhs != null && rhs.nodeType != null && !isSpanValued(rhs.nodeType)) {
		bd.right = makeHiddenStdConv(rhs, bd.left.nodeType, rhs.location);
	}
	return node;
}

function wrapSpanDeclInit(node: Node): Node {
	let declType = node.nodeType;
	if (declType == null && node.resolvedSym != null) declType = node.resolvedSym.symbolType;
	if (declType == null || declType.kind != TypeKind.Span || declType.typeReturn == null) return node;
	const vd = node.data as VariableDeclData;
	const init = vd.initializer;
	if (init != null && init.nodeType != null && !isSpanValued(init.nodeType)) {
		vd.initializer = makeHiddenStdConv(init, declType, init.location);
	}
	return node;
}

function wrapSpanObjectFields(node: Node): Node {
	if (node.nodeType != null && node.nodeType.kind == TypeKind.Span) return node;
	const t = peelToStructOrUnion(node.nodeType);
	if (t == null || t.kind != TypeKind.Struct) return node;
	const names = t.typeNames;
	const children = t.typeChildren;
	if (names == null || children == null) return node;
	const d = node.data as ObjectLiteralData;
	let i = 0;
	while (i < d.properties.length) {
		const keyName = i < d.keys.length ? d.keys[i] : "";
		if (keyName != "" && keyName != "..." && keyName != "__computed__") {
			let ni = 0;
			while (ni < names.length) {
				if (names[ni] == keyName) {
					if (ni < children.length) {
						const fieldType = children[ni];
						if (fieldType != null && fieldType.kind == TypeKind.Span && fieldType.typeReturn != null) {
							const prop = d.properties[i];
							if (prop != null && prop.nodeType != null && !isSpanValued(prop.nodeType)) {
								d.properties[i] = makeHiddenStdConv(prop, fieldType, prop.location);
							}
						}
					}
					break;
				}
				ni = ni + 1;
			}
		}
		i = i + 1;
	}
	return node;
}

// ===== Zero-Copy Slicing =====
// arr[start..end] where nodeType is Span → { data: arr.data + start, len: end - start }

function lowerRangeAccess(node: Node, ctx: TransformContext): Node {
	const d = node.data as ArrayAccessData;

	// Only handle range index (BinaryExpr with ".." or "..." operator)
	if (d.index.kind != NodeKind.BinaryExpr) return node;
	const bd = d.index.data as BinaryExprData;
	if (bd.operator != ".." && bd.operator != "...") return node;

	// Only handle when result type is Span
	const resultType = node.nodeType;
	if (resultType == null || resultType.kind != TypeKind.Span) return node;

	const arrType = d.array.nodeType;
	if (arrType == null) return node;

	const loc = node.location;
	const startExpr = bd.left;
	const endExpr = bd.right;

	// Build data pointer: arr.data + start (pointer arithmetic in C)
	let dataBase: Node | null = null;
	if (arrType.kind == TypeKind.Array) {
		// Heap array: arr.p->data + start (nativeLower rewrites .data to .p->data for Arrays)
		dataBase = makeMember(d.array, "data", loc);
	} else if (arrType.kind == TypeKind.SizedArray || arrType.kind == TypeKind.Span) {
		// Stack array or span: arr.data + start
		dataBase = makeMember(d.array, "data", loc);
	} else if (arrType.kind == TypeKind.String) {
		// String: msArrDataOr0(str.p) + start — msString holds the bytes in its payload
		dataBase = makeCall(runtimeRef("msArrDataOr0", loc), [makeMember(d.array, "p", loc)], loc);
	} else {
		return node;
	}

	// data = base + start
	const dataExpr = makeBinary(dataBase, "+", startExpr, loc);
	// Set pointer type for correct C emission
	if (resultType.typeReturn != null) {
		dataExpr.nodeType = createPtr(resultType.typeReturn);
	}

	const endExclusive = bd.operator == "..." ? makeBinary(endExpr, "+", makeNumber(1, loc), loc) : endExpr;
	const sourceLen = arrType.kind == TypeKind.SizedArray ? makeNumber(arrType.typeValue, loc) : makeMember(d.array, "len", loc);
	const lenExpr = makeCall(runtimeRef("msSliceLen", loc), [startExpr, endExclusive, sourceLen], loc);
	lenExpr.nodeType = createPrimitive(TypeKind.Int64);

	return makeTypedObjectLiteral(["data", "len"], [dataExpr, lenExpr], resultType, loc);
}

function borrowedJS(src: Node, srcType: Type): Node {
	const addr = makeHiddenAddr(src, src.location);
	addr.nodeType = createPtr(srcType);
	return addr;
}

function spanViewJS(src: Node, srcType: Type, loc: SourceLocation): Node | null {
	if (srcType.kind == TypeKind.Span) return src;
	if (src.kind == NodeKind.ArrayLiteral || srcType.kind == TypeKind.Array || srcType.kind == TypeKind.SizedArray) {
		return makeCall(runtimeRef("msSpanOf", loc), [borrowedJS(src, srcType)], loc);
	}
	if (srcType.kind == TypeKind.String) {
		return makeCall(runtimeRef("asBytes", loc), [src], loc);
	}
	return null;
}

function lowerRangeAccessJS(node: Node): Node {
	const d = node.data as ArrayAccessData;
	if (d.index.kind != NodeKind.BinaryExpr) return node;
	const bd = d.index.data as BinaryExprData;
	if (bd.operator != ".." && bd.operator != "...") return node;
	const resultType = node.nodeType;
	if (resultType == null || resultType.kind != TypeKind.Span) return node;
	let arrType = d.array.nodeType;
	if (arrType != null && arrType.kind == TypeKind.Ref && arrType.typeReturn != null) arrType = arrType.typeReturn;
	if (arrType == null) return node;

	const loc = node.location;
	const endExclusive = bd.operator == "..." ? makeBinary(bd.right, "+", makeNumber(1, loc), loc) : bd.right;
	let slice: Node | null = null;
	if (arrType.kind == TypeKind.Span) {
		slice = makeCall(runtimeRef("msSliceSpan", loc), [d.array, bd.left, endExclusive], loc);
	} else if (arrType.kind == TypeKind.Array || arrType.kind == TypeKind.SizedArray) {
		slice = makeCall(runtimeRef("msSliceOf", loc), [borrowedJS(d.array, arrType), bd.left, endExclusive], loc);
	} else if (arrType.kind == TypeKind.String) {
		slice = makeCall(runtimeRef("msSliceSpan", loc), [makeCall(runtimeRef("asBytes", loc), [d.array], loc), bd.left, endExclusive], loc);
	}
	if (slice == null) return node;
	slice.nodeType = resultType;
	return slice;
}

// ===== Stack-Promoted Literals =====
// HiddenStdConv(ArrayLiteral, Span<T>) → synthetic SizedArray on stack + Span view
//
// Before: sum([1, 2, 3])  →  heap-allocate msNumberArray, take span
// After:  sum([1, 2, 3])  →  stack T[3] = {1,2,3}, pass (data, 3)

function lowerLiteralToSpan(literal: Node, spanType: Type, ctx: TransformContext): Node {
	const ld = literal.data as ArrayLiteralData;
	const elemCount = ld.elements.length;
	if (elemCount == 0) {
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
