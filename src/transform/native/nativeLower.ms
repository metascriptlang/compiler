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
//   x.length  on SizedArray   →  NumberLiteral(size)
//
// Runtime macros are GCC statement expressions returning lvalues (read + write).

import { Node, NodeKind, NodeFlag, ArrayAccessData, CallExprData, MemberExprData, ArrayLiteralData, VariableDeclData, BinaryExprData, NumberLiteralData, NewExprData, Symbol, Type, TypeKind, SymbolKind, createNode, makeLoc } from "../../ast/node";
import { isNumeric, unwrapRefNullUnion, isAtomicRef, isLockedRef, peelTransparentInstance, setRepr, isUnknownType, isUncountedPtrElement, createArray, createSizedArray, createSpan, createRef, createStruct, int32Type } from "../../checker/types";
import { findChar } from "../../utils/string";
import { TransformContext, createTransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeNumber, makeMember, syntheticToken, runtimeRef, makeTypedIdent, makeArrayAccess, makeHiddenSubConv, isRuntimeProcCall } from "../util";
import { checkVariantReads } from "./unionProjectLower";

// reference array: a Ref<Array> receiver reaching access/length lowering (e.g. a node
// synthesized by forOfLower after the checker already ran) is a msXxxArray* pointer, but
// the runtime access macros / `.len` field read want the value struct. Deref the Ref so
// codegen emits `(*arr)`. A receiver already dereferenced by the checker is a value Array
// here, so this is a no-op for it (guards against double-deref).
function unwrapRefArrayRecv(recv: Node): Node {
	const t = recv.nodeType != null ? peelTransparentInstance(recv.nodeType) : null;
	if (t != null && t.kind == TypeKind.Ref && t.typeReturn != null
			&& t.typeReturn.kind == TypeKind.Array) {
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
	checkVariantReads(program, ctx);
	walkNode(program, (n: Node): Node => { return rewriteAccess(n, ctx); });
	return program;
}

// Propagate SizedArray type to ArrayLiteral initializers so rewriteArrayLiteral skips them.
function propagateSizedArrayType(node: Node): Node {
	// VariableDecl: const fixed: number[3] = [10, 20, 30]
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (node.nodeType != null && node.nodeType.kind == TypeKind.SizedArray) {
			if (d.initializer != null && d.initializer.kind == NodeKind.ArrayLiteral) {
				d.initializer.nodeType = node.nodeType;
			}
		}
	}
	// Assignment: fixed = [10, 20, 30]
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=") {
			if (d.left.nodeType != null && d.left.nodeType.kind == TypeKind.SizedArray) {
				if (d.right != null && d.right.kind == NodeKind.ArrayLiteral) {
					d.right.nodeType = d.left.nodeType;
				}
			}
		}
	}
	return node;
}

// ===== Rewriter =====

function rewriteAccess(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.ArrayAccess) return rewriteArrayAccess(node, ctx.boundChecks);
	if (!ctx.boundChecks && isRuntimeProcCall(node, "msSliceLen")) return uncheckedSliceLen(node);
	if (!ctx.rangeChecks && node.kind == NodeKind.HiddenSubConv && node.variantSlot > 0) node.flags = node.flags.incl(NodeFlag.NoFieldCheck);
	if (node.kind == NodeKind.MemberExpr) return rewriteMemberExpr(node);
	if (node.kind == NodeKind.ArrayLiteral) return rewriteArrayLiteral(node);
	if (node.kind == NodeKind.NewExpr) return rewriteNewExpr(node);
	if (node.kind == NodeKind.CallExpr) return rewriteExternArrayReturn(rewriteArrayEvictCall(node));
	return node;
}

// An extern (FFI) function whose return is typed Ref<Array> returns the array BY VALUE at
// the C ABI (msXxxArray); box that value into a refcounted cell so the pointer-typed
// destination matches — same shape as a fresh array literal / new Array().
function rewriteExternArrayReturn(node: Node): Node {
	const refType = node.nodeType;
	if (refType == null || refType.kind != TypeKind.Ref || refType.typeReturn == null
			|| refType.typeReturn.kind != TypeKind.Array) return node;
	const sym = node.resolvedSym;
	if (sym == null || sym.nativeName == ""
			|| sym.symbolKind == SymbolKind.Variable
			|| sym.symbolKind == SymbolKind.Temp
			|| sym.symbolKind == SymbolKind.Parameter
			|| sym.symbolKind == SymbolKind.Property) return node;
	if (findChar(sym.nativeName, "(") >= 0) return node;
	if (returnsTypeParam(sym)) return node;
	node.nodeType = refType.typeReturn;
	const box = makeCall(runtimeRef("msBoxRefArray", node.location), [node], node.location);
	box.nodeType = refType;
	return box;
}

function returnsTypeParam(sym: Symbol): boolean {
	const fn = sym.symbolType;
	return fn != null && fn.typeReturn != null && fn.typeReturn.kind == TypeKind.GenericParam;
}

// new Array(N) / new Array<T>() typed as Ref<Array<T>>: the inner NewExpr builds a
// value array (codegen calloc); box it into a refcounted cell, same as an array literal.
function rewriteNewExpr(node: Node): Node {
	const refType = node.nodeType;
	// new Locked(value): the argument is the cell's PAYLOAD, not the pointee —
	// the pointee is the generated `{ lockNext, lockServing, value }` cell. Checked
	// before the Arc path, whose predicate (isAtomicRef) also matches a Locked
	// handle and would box the payload as the whole pointee.
	if (isLockedRef(refType)) {
		const ld = node.data as NewExprData;
		if (ld.newArguments.length == 1) {
			const cell = makeCall(runtimeRef("msBoxLocked", node.location), [ld.newArguments[0]], node.location);
			cell.nodeType = refType;
			return cell;
		}
	}
	// new Arc(value): box the argument value into an atomic-rc cell (msAllocArc).
	// Checked BEFORE the Ref<Array> path so Arc<Array> also takes the atomic box.
	if (isAtomicRef(refType)) {
		const d = node.data as NewExprData;
		if (d.newArguments.length == 1) {
			const box = makeCall(runtimeRef("msBoxArc", node.location), [d.newArguments[0]], node.location);
			box.nodeType = refType;
			return box;
		}
	}
	if (refType != null && refType.kind == TypeKind.Ref && refType.typeReturn != null
			&& refType.typeReturn.kind == TypeKind.Array) {
		node.nodeType = refType.typeReturn;
		const box = makeCall(runtimeRef("msBoxRefArray", node.location), [node], node.location);
		box.nodeType = refType;
		return box;
	}
	return node;
}

function uncheckedSliceLen(node: Node): Node {
	const d = node.data as CallExprData;
	const result = makeCall(runtimeRef("msSliceLenUnchecked", node.location), d.arguments, node.location);
	result.nodeType = node.nodeType;
	return result;
}

// ===== Array/String Index Access =====

function rewriteArrayAccess(node: Node, boundChecks: boolean): Node {
	const d = node.data as ArrayAccessData;
	d.array = unwrapRefArrayRecv(d.array);
	const peeled = d.array.nodeType != null ? peelTransparentInstance(d.array.nodeType) : null;
	const arrType = peeled != null && peeled.kind == TypeKind.Set ? setRepr(peeled) : peeled;
	if (arrType == null) return node;

	const loc = node.location;

	if (arrType.kind == TypeKind.Array) {
		const elemType = arrType.typeReturn;
		const macroName = getArrayMacroName(elemType, boundChecks);
		const result = makeCall(runtimeRef(macroName, loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind == TypeKind.SizedArray) {
		const size = arrType.typeValue;
		const result = makeCall(runtimeRef(boundChecks ? "msSizedArrayAccess" : "msSizedArrayAccessUnchecked", loc), [d.array, d.index, makeNumber(size, loc)], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind == TypeKind.Span) {
		const result = makeCall(runtimeRef(boundChecks ? "msSpanAccess" : "msSpanAccessUnchecked", loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	if (arrType.kind == TypeKind.String) {
		const result = makeCall(runtimeRef("msStringCharAccess", loc), [d.array, d.index], loc);
		result.nodeType = node.nodeType;
		return result;
	}

	// Tuple index: t[0] → t._0 (rewrite ArrayAccess → MemberExpr)
	if (arrType.kind == TypeKind.Tuple) {
		if (d.index.kind == NodeKind.NumberLiteral) {
			const idx = (d.index.data as NumberLiteralData).value;
			const fieldName = "_" + idx.toString();
			const result = makeMember(d.array, fieldName, loc);
			if (arrType.typeChildren != null && idx < arrType.typeChildren.length) {
				result.nodeType = arrType.typeChildren[idx];
			}
			return result;
		}
		return node;
	}

	return node;
}

// Determine macro name from array element type
function getArrayMacroName(elemType: Type | null, boundChecks: boolean): string {
	const ref = boundChecks ? "msRefArrayAccess" : "msRefArrayAccessUnchecked";
	const value = boundChecks ? "msArrayAccess" : "msArrayAccessUnchecked";
	if (elemType == null) return ref;
	elemType = peelTransparentInstance(elemType);
	if (elemType.kind == TypeKind.Uint8) return value;
	if (isNumeric(elemType)) return value;
	if (elemType.kind == TypeKind.String) return value;
	// Pointer element types (classes, refs) use msRefArray — void* indirection
	if (elemType.kind == TypeKind.Ref || elemType.kind == TypeKind.Ptr) return ref;
	// Union(Ref<T>, Null) collapses to T* in C — same representation as Ref<T>.
	if (elemType.kind == TypeKind.Union && unwrapRefNullUnion(elemType) != null) return ref;
	// Value-type struct elements use per-type array typedefs
	return value;
}

// ===== Element Eviction =====
// The runtime's eviction helpers hardcode the element release, so the ELEMENT
// type picks the helper — the same selection getArrayMacroName makes for arr[i]
// and lowerLengthAssign makes for `arr.length = n`. std binds `setLength` to
// msGenericArraySetLen, which lowers len and releases nothing, so a counted
// element needs the msRefArray family whether or not its rc is atomic; an
// atomic cell is born at MS_RC_INCREMENT, so it needs the atomic twin on top.
// The counted-element test mirrors classify.ms classifyArray — Actor handles
// and nested ref-arrays keep their own families.
export function evictHelperName(nativeName: string, elemType: Type | null): string {
	if (elemType == null) return "";
	elemType = peelTransparentInstance(elemType);
	if (isUncountedPtrElement(elemType)) return "";
	const bare = elemType.kind == TypeKind.Union ? unwrapRefNullUnion(elemType) : elemType;
	if (bare == null) return "";
	if (bare.kind != TypeKind.Ref && bare.kind != TypeKind.Ptr && !isUnknownType(bare)) return "";
	if (bare.sym != null && bare.sym.symbolKind == SymbolKind.Actor) return "";
	if (bare.kind == TypeKind.Ref && bare.typeReturn != null && bare.typeReturn.kind == TypeKind.Array) return "";
	const atomic = isAtomicRef(bare);
	if (nativeName == "msGenericArraySetLen") return atomic ? "msAtomicRefArraySetLen" : "msRefArraySetLen";
	if (nativeName == "msRefArraySplice") return atomic ? "msAtomicRefArraySplice" : "";
	if (nativeName == "msRefArraySplice3") return atomic ? "msAtomicRefArraySplice3" : "";
	return "";
}

function rewriteArrayEvictCall(node: Node): Node {
	const d = node.data as CallExprData;
	if (d.arguments.length == 0) return node;
	let sym = node.resolvedSym;
	if (sym == null) sym = d.callee.resolvedSym;
	if (sym == null || sym.nativeName == "") return node;
	// A `from "&name"` clause keeps its address-of prefix in nativeName.
	const native = sym.nativeName.startsWith("&") ? sym.nativeName.slice(1, sym.nativeName.length) : sym.nativeName;
	const recvT = d.arguments[0].nodeType != null ? peelTransparentInstance(d.arguments[0].nodeType) : null;
	if (recvT == null) return node;
	const arrT = (recvT.kind == TypeKind.Ref && recvT.typeReturn != null && recvT.typeReturn.kind == TypeKind.Array)
		? recvT.typeReturn
		: recvT;
	if (arrT.kind != TypeKind.Array) return node;
	const helper = evictHelperName(native, arrT.typeReturn);
	if (helper == "") return node;
	const call = makeCall(runtimeRef(helper, node.location), d.arguments, node.location);
	call.nodeType = node.nodeType;
	return call;
}

// ===== Property Remapping =====

function rewriteMemberExpr(node: Node): Node {
	const d = node.data as MemberExprData;
	d.object = unwrapRefArrayRecv(d.object);
	const objType = d.object.nodeType;
	if (objType == null) return node;

	// .length on CString → strlen(s) (C standard library)
	// .length on String → msStringLength(s) (UTF-16 code units, TypeScript parity)
	// .length on arrays → .len (element count)
	if (d.property == "length") {
		if (objType.kind == TypeKind.CString) {
			const loc = node.location;
			const result = makeCall(runtimeRef("strlen", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		if (objType.kind == TypeKind.String) {
			const loc = node.location;
			const result = makeCall(runtimeRef("msStringLength", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		if (objType.kind == TypeKind.SizedArray) {
			const result = makeNumber(objType.typeValue, node.location);
			if (node.nodeType != null) result.nodeType = node.nodeType;
			return result;
		}
		if (objType.kind == TypeKind.Array || objType.kind == TypeKind.Span) {
			d.property = "len";
		}
		return node;
	}

	// .byteLength on String → .len (raw UTF-8 byte count)
	if (d.property == "byteLength") {
		if (objType.kind == TypeKind.String) {
			d.property = "len";
		}
		return node;
	}

	// .unicodeLength on String → msStringUnicodeLength(s) (codepoint count)
	if (d.property == "unicodeLength") {
		if (objType.kind == TypeKind.String) {
			const loc = node.location;
			const result = makeCall(runtimeRef("msStringUnicodeLength", loc), [d.object], loc);
			result.nodeType = node.nodeType;
			return result;
		}
		return node;
	}

	// .data → .p->data for Array (pointer dereference through p field)
	// SizedArray/Span: .data stays as .data (direct field)
	if (d.property == "data") {
		if (objType.kind == TypeKind.Array) {
			d.property = "p->data";
		}
	}

	return node;
}

// ===== Array Literal Lowering =====
// Rewrites typed array literals to runtime calls:
//   ["a", "b"] on string[]  →  CallExpr("msStringArrayFromArr", [2, "a", "b"])
//                              (codegen rewrites to stack-local array + msStringArrayFromArr(arr, N)
//                               — avoids variadic 16-byte struct ABI bug on aarch64-windows-gnu)
// Other types (number[], object[], ref[]) stay as ArrayLiteral for codegen's Temp+Push pattern.

function rewriteArrayLiteral(node: Node): Node {
	const d = node.data as ArrayLiteralData;

	// reference array Ref<Array<T>>: lower the inner value array, then box it onto the
	// heap via msBoxRefArray (refcounted cell) so the variable holds a shared pointer.
	const refType = node.nodeType;
	if (refType != null && refType.kind == TypeKind.Ref && refType.typeReturn != null
			&& refType.typeReturn.kind == TypeKind.Array) {
		node.nodeType = refType.typeReturn;
		const inner = rewriteArrayLiteral(node);
		const box = makeCall(runtimeRef("msBoxRefArray", node.location), [inner], node.location);
		box.nodeType = refType;
		return box;
	}

	if (d.elements.length == 0) return node;

	const arrType = node.nodeType;
	if (arrType == null || arrType.kind != TypeKind.Array) return node;
	const elemType = arrType.typeReturn;
	if (elemType == null) return node;

	const loc = node.location;

	// string[] → msStringArrayFromArr(count, e1, e2, ...)
	if (elemType.kind == TypeKind.String) {
		const args: Node[] = [makeNumber(d.elements.length, loc)];
		for (let i = 0; i < d.elements.length; i += 1) {
			args.push(d.elements[i]);
		}
		const call = makeCall(runtimeRef("msStringArrayFromArr", loc), args, loc);
		call.nodeType = node.nodeType;
		return call;
	}

	return node;
}

// ===== Tests =====

function loweredAccess(arrType: Type, boundChecks: boolean): Node {
	const loc = makeLoc(1, 1);
	const ctx = createTransformContext();
	ctx.boundChecks = boundChecks;
	return rewriteAccess(makeArrayAccess(makeTypedIdent("xs", arrType, loc), makeNumber(0, loc), loc), ctx);
}

function leafRef(): Type {
	return createRef(createStruct("Leaf", ["v"], [int32Type()], false));
}

test "array index is bound-checked when bound checks are on" { assert isRuntimeProcCall(loweredAccess(createArray(int32Type()), true), "msArrayAccess"); }

test "array index is unchecked when bound checks are off" { assert isRuntimeProcCall(loweredAccess(createArray(int32Type()), false), "msArrayAccessUnchecked"); }

test "ref array index is bound-checked when bound checks are on" { assert isRuntimeProcCall(loweredAccess(createArray(leafRef()), true), "msRefArrayAccess"); }

test "ref array index is unchecked when bound checks are off" { assert isRuntimeProcCall(loweredAccess(createArray(leafRef()), false), "msRefArrayAccessUnchecked"); }

test "sized array index is bound-checked when bound checks are on" { assert isRuntimeProcCall(loweredAccess(createSizedArray(int32Type(), 4), true), "msSizedArrayAccess"); }

test "sized array index is unchecked when bound checks are off" { assert isRuntimeProcCall(loweredAccess(createSizedArray(int32Type(), 4), false), "msSizedArrayAccessUnchecked"); }

test "span index is bound-checked when bound checks are on" { assert isRuntimeProcCall(loweredAccess(createSpan(int32Type()), true), "msSpanAccess"); }

test "span index is unchecked when bound checks are off" { assert isRuntimeProcCall(loweredAccess(createSpan(int32Type()), false), "msSpanAccessUnchecked"); }

function loweredSliceLen(boundChecks: boolean): Node {
	const loc = makeLoc(1, 1);
	const ctx = createTransformContext();
	ctx.boundChecks = boundChecks;
	const call = makeCall(runtimeRef("msSliceLen", loc), [makeNumber(1, loc), makeNumber(3, loc), makeNumber(4, loc)], loc);
	return rewriteAccess(call, ctx);
}

test "a slice length is bound-checked when bound checks are on" { assert isRuntimeProcCall(loweredSliceLen(true), "msSliceLen"); }

test "a slice length is unchecked when bound checks are off" { assert isRuntimeProcCall(loweredSliceLen(false), "msSliceLenUnchecked"); }

function loweredNarrowing(rangeChecks: boolean): Node {
	const loc = makeLoc(1, 1);
	const ctx = createTransformContext();
	ctx.rangeChecks = rangeChecks;
	const narrowing = makeHiddenSubConv(makeTypedIdent("u", int32Type(), loc), int32Type(), loc);
	narrowing.variantSlot = 1;
	return rewriteAccess(narrowing, ctx);
}

test "a union narrowing keeps its variant check when range checks are on" { assert !loweredNarrowing(true).flags.has(NodeFlag.NoFieldCheck); }

test "a union narrowing drops its variant check when range checks are off" { assert loweredNarrowing(false).flags.has(NodeFlag.NoFieldCheck); }
