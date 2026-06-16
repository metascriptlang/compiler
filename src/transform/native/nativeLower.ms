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

import { Node, NodeKind, ArrayAccessData, MemberExprData, ArrayLiteralData, VariableDeclData, BinaryExprData, NumberLiteralData, Type, TypeKind, SymbolKind, createNode } from "../../ast/node";
import { isNumeric, unwrapRefNullUnion } from "../../checker/types";
import { findChar } from "../../utils/string";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber, makeMember, syntheticToken } from "../util";

// reference array: a Ref<Array> receiver reaching access/length lowering (e.g. a node
// synthesized by forOfLower after the checker already ran) is a msXxxArray* pointer, but
// the runtime access macros / `.len` field read want the value struct. Deref the Ref so
// codegen emits `(*arr)`. A receiver already dereferenced by the checker is a value Array
// here, so this is a no-op for it (guards against double-deref).
function unwrapRefArrayRecv(recv: Node): Node {
	const t = recv.nodeType;
	if (t !== null && t.kind === TypeKind.Ref && t.typeReturn !== null
			&& t.typeReturn.kind === TypeKind.Array) {
		const deref = createNode(NodeKind.HiddenDeref, { expr: recv }, syntheticToken(recv.location));
		deref.nodeType = t.typeReturn;
		return deref;
	}
	return recv;
}

// ===== Main Entry Point =====

export function lowerNativeAccess(program: Node, ctx: TransformContext): Node {
	// Pre-pass: propagate SizedArray type from declarations/assignments to ArrayLiteral initializers.
	// Without this, ArrayLiterals infer TypeKind.Array and get heap-allocated by rewriteArrayLiteral.
	walkNode(program, propagateSizedArrayType);
	walkNode(program, rewriteAccess);
	return program;
}

// Propagate SizedArray type to ArrayLiteral initializers so rewriteArrayLiteral skips them.
function propagateSizedArrayType(node: Node): Node {
	// VariableDecl: const fixed: number[3] = [10, 20, 30]
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.SizedArray) {
			if (d.initializer !== null && d.initializer.kind === NodeKind.ArrayLiteral) {
				d.initializer.nodeType = node.nodeType;
			}
		}
	}
	// Assignment: fixed = [10, 20, 30]
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator === "=") {
			if (d.left.nodeType !== null && d.left.nodeType.kind === TypeKind.SizedArray) {
				if (d.right !== null && d.right.kind === NodeKind.ArrayLiteral) {
					d.right.nodeType = d.left.nodeType;
				}
			}
		}
	}
	return node;
}

// ===== Rewriter =====

function rewriteAccess(node: Node): Node {
	if (node.kind === NodeKind.ArrayAccess) return rewriteArrayAccess(node);
	if (node.kind === NodeKind.MemberExpr) return rewriteMemberExpr(node);
	if (node.kind === NodeKind.ArrayLiteral) return rewriteArrayLiteral(node);
	if (node.kind === NodeKind.NewExpr) return rewriteNewExpr(node);
	if (node.kind === NodeKind.CallExpr) return rewriteExternArrayReturn(node);
	return node;
}

// An extern (FFI) function whose return is typed Ref<Array> returns the array BY VALUE at
// the C ABI (msXxxArray); box that value into a refcounted cell so the pointer-typed
// destination matches — same shape as a fresh array literal / new Array().
function rewriteExternArrayReturn(node: Node): Node {
	const refType = node.nodeType;
	if (refType === null || refType.kind !== TypeKind.Ref || refType.typeReturn === null
			|| refType.typeReturn.kind !== TypeKind.Array) return node;
	const sym = node.resolvedSym;
	if (sym === null || sym.nativeName === ""
			|| sym.symbolKind === SymbolKind.Variable
			|| sym.symbolKind === SymbolKind.Parameter
			|| sym.symbolKind === SymbolKind.Property) return node;
	if (findChar(sym.nativeName, "(") >= 0) return node;
	node.nodeType = refType.typeReturn;
	const box = makeCall(makeIdent("msBoxRefArray", node.location), [node], node.location);
	box.nodeType = refType;
	return box;
}

// new Array(N) / new Array<T>() typed as Ref<Array<T>>: the inner NewExpr builds a
// value array (codegen calloc); box it into a refcounted cell, same as an array literal.
function rewriteNewExpr(node: Node): Node {
	const refType = node.nodeType;
	if (refType !== null && refType.kind === TypeKind.Ref && refType.typeReturn !== null
			&& refType.typeReturn.kind === TypeKind.Array) {
		node.nodeType = refType.typeReturn;
		const box = makeCall(makeIdent("msBoxRefArray", node.location), [node], node.location);
		box.nodeType = refType;
		return box;
	}
	return node;
}

// ===== Array/String Index Access =====

function rewriteArrayAccess(node: Node): Node {
	const d = node.data as ArrayAccessData;
	d.array = unwrapRefArrayRecv(d.array);
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

	// Tuple index: t[0] → t._0 (rewrite ArrayAccess → MemberExpr)
	if (arrType.kind === TypeKind.Tuple) {
		if (d.index.kind === NodeKind.NumberLiteral) {
			const idx = (d.index.data as NumberLiteralData).value;
			const fieldName = "_" + idx.toString();
			const result = makeMember(d.array, fieldName, loc);
			if (arrType.typeChildren !== null && idx < arrType.typeChildren.length) {
				result.nodeType = arrType.typeChildren[idx];
			}
			return result;
		}
		return node;
	}

	return node;
}

// Determine macro name from array element type
function getArrayMacroName(elemType: Type | null): string {
	if (elemType === null) return "msRefArrayAccess";
	if (elemType.kind === TypeKind.Uint8) return "msArrayAccess";
	if (isNumeric(elemType)) return "msArrayAccess";
	if (elemType.kind === TypeKind.String) return "msArrayAccess";
	// Pointer element types (classes, refs) use msRefArray — void* indirection
	if (elemType.kind === TypeKind.Ref || elemType.kind === TypeKind.Ptr) return "msRefArrayAccess";
	// Union(Ref<T>, Null) collapses to T* in C — same representation as Ref<T>.
	if (elemType.kind === TypeKind.Union && unwrapRefNullUnion(elemType) !== null) return "msRefArrayAccess";
	// Value-type struct elements use per-type array typedefs
	return "msArrayAccess";
}

// ===== Property Remapping =====

function rewriteMemberExpr(node: Node): Node {
	const d = node.data as MemberExprData;
	d.object = unwrapRefArrayRecv(d.object);
	const objType = d.object.nodeType;
	if (objType === null) return node;

	// .length on CString → strlen(s) (C standard library)
	// .length on String → msStringLength(s) (UTF-16 code units, TypeScript parity)
	// .length on arrays → .len (element count)
	if (d.property === "length") {
		if (objType.kind === TypeKind.CString) {
			const loc = node.location;
			const result = makeCall(makeIdent("strlen", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		if (objType.kind === TypeKind.String) {
			const loc = node.location;
			const result = makeCall(makeIdent("msStringLength", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		if (objType.kind === TypeKind.Array || objType.kind === TypeKind.SizedArray ||
			objType.kind === TypeKind.Span) {
			d.property = "len";
		}
		return node;
	}

	// .byteLength on String → .len (raw UTF-8 byte count)
	if (d.property === "byteLength") {
		if (objType.kind === TypeKind.String) {
			d.property = "len";
		}
		return node;
	}

	// .unicodeLength on String → msStringUnicodeLength(s) (codepoint count)
	if (d.property === "unicodeLength") {
		if (objType.kind === TypeKind.String) {
			const loc = node.location;
			const result = makeCall(makeIdent("msStringUnicodeLength", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		return node;
	}

	// .data → .p->data for Array (pointer dereference through p field)
	// SizedArray/Span: .data stays as .data (direct field)
	if (d.property === "data") {
		if (objType.kind === TypeKind.Array) {
			d.property = "p->data";
		}
	}

	return node;
}

// ===== Array Literal Lowering =====
// Rewrites typed array literals to variadic runtime calls:
//   [1, 2, 3]  on number[]  →  CallExpr("msNumberArrayFrom", [3, 1, 2, 3])
//   ["a", "b"] on string[]  →  CallExpr("msStringArrayFromArr", [2, "a", "b"])
//                              (codegen rewrites to stack-local array + msStringArrayFromArr(arr, N)
//                               — avoids variadic 16-byte struct ABI bug on aarch64-windows-gnu)
// Other types (object[], ref[]) stay as ArrayLiteral for codegen's Temp+Push pattern.

function rewriteArrayLiteral(node: Node): Node {
	const d = node.data as ArrayLiteralData;

	// reference array Ref<Array<T>>: lower the inner value array, then box it onto the
	// heap via msBoxRefArray (refcounted cell) so the variable holds a shared pointer.
	const refType = node.nodeType;
	if (refType !== null && refType.kind === TypeKind.Ref && refType.typeReturn !== null
			&& refType.typeReturn.kind === TypeKind.Array) {
		node.nodeType = refType.typeReturn;
		const inner = rewriteArrayLiteral(node);
		const box = makeCall(makeIdent("msBoxRefArray", node.location), [inner], node.location);
		box.nodeType = refType;
		return box;
	}

	if (d.elements.length === 0) return node;

	const arrType = node.nodeType;
	if (arrType === null || arrType.kind !== TypeKind.Array) return node;
	const elemType = arrType.typeReturn;
	if (elemType === null) return node;

	const loc = node.location;

	// number[]/float64[] → msNumberArrayFrom(count, e1, e2, ...)
	if (elemType.kind === TypeKind.Number || elemType.kind === TypeKind.Float64) {
		const args: Node[] = [makeNumber(d.elements.length, loc)];
		for (let i = 0; i < d.elements.length; i += 1) {
			args.push(d.elements[i]);
		}
		const call = makeCall(makeIdent("msNumberArrayFrom", loc), args, loc);
		call.nodeType = node.nodeType;
		return call;
	}

	// string[] → msStringArrayFromArr(count, e1, e2, ...)
	if (elemType.kind === TypeKind.String) {
		const args: Node[] = [makeNumber(d.elements.length, loc)];
		for (let i = 0; i < d.elements.length; i += 1) {
			args.push(d.elements[i]);
		}
		const call = makeCall(makeIdent("msStringArrayFromArr", loc), args, loc);
		call.nodeType = node.nodeType;
		return call;
	}

	return node;
}

// Tests stripped — require reference compiler (test "name" { } keyword form needs fix)
