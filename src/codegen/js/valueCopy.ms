// JavaScript Codegen — value-type copy-on-assignment.
//
// The native pipeline gets copy semantics from analyzer-generated hooks; the JS
// pipeline skips that layer (it is DRC-bound), so the copy decision is remade
// here per emission site from the static type, the same way Nim's jsgen decides
// in genAsgn/genObjConstr. Vec and T[] are both plain JS arrays at runtime, so
// a generic structural clone cannot exist — the walker must be per-type.

import { Node, NodeKind, NodeFlag, Type, TypeKind, TypeFlag } from "../../ast/node";
import {
	ArrayAccessData, BinaryExprData, ConditionalExprData, HiddenDerefData, MemberExprData, SpreadExprData, TypeAssertionData,
} from "../../ast/node";
import { isViewBinding } from "../../checker/symbol";
import { distinctBody } from "../../checker/types";
import { emit, emitNode, JSGenerator, jsTypedArrayName } from "./emit";

let ownerGen: JSGenerator | null = null;
let copyKeys: string[] = [];
let copyNames: string[] = [];
let assignKeys: string[] = [];
let assignNames: string[] = [];

function registryFor(gen: JSGenerator): void {
	if (ownerGen != gen) {
		ownerGen = gen;
		copyKeys = [];
		copyNames = [];
		assignKeys = [];
		assignNames = [];
	}
}

export function needsValueCopy(t: Type | null): boolean {
	// Maybe<T> is unwrapped first: the C backend wraps non-pointer optionals in
	// a { value, present } carrier, but the JS backend erases them to a native
	// `T | null` at every emission site (literals, tests, calls) — so the copy
	// decision must be made on the payload T, not the carrier. Otherwise a
	// narrowed `return p.fb` emits a carrier deep-copy for what is a plain
	// nullable string at runtime (corpus 015 "p1=[object Object]").
	t = jsValueRepr(t);
	if (t == null) return false;
	if (t.kind == TypeKind.Struct) return t.typeFlags.has(TypeFlag.IsStruct);
	if (t.kind == TypeKind.Tuple) return true;
	if (t.kind == TypeKind.Array) return true;
	if (t.kind == TypeKind.SizedArray) return true;
	return false;
}

// The runtime representation a JS value of static type `t` actually has:
// Maybe<T> carriers are erased to `T | null` (see needsValueCopy).
function jsValueRepr(t: Type | null): Type | null {
	const base = distinctBody(t);
	if (base != null) return jsValueRepr(base);
	if (t != null && t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) {
		return t.typeReturn;
	}
	return t;
}

function typeKey(t: Type): string {
	if (t.kind == TypeKind.Struct) {
		let key = "S:" + t.typeName + "(";
		let i = 0;
		while (i < t.typeChildren.length) {
			const fname = i < t.typeNames.length ? t.typeNames[i] : "";
			key = key + fname + ":" + typeKey(t.typeChildren[i]) + ",";
			i += 1;
		}
		return key + ")";
	}
	if (t.kind == TypeKind.Tuple) {
		let key = "T:(";
		for (const c of t.typeChildren) key = key + typeKey(c) + ",";
		return key + ")";
	}
	if (t.kind == TypeKind.Array && t.typeReturn != null) return "A:" + typeKey(t.typeReturn);
	if (t.kind == TypeKind.SizedArray && t.typeReturn != null) return "F:" + typeKey(t.typeReturn);
	return "p" + (t.kind as int32).toString();
}

function copyExpr(gen: JSGenerator, t: Type | null, src: string): string {
	t = jsValueRepr(t);
	if (!needsValueCopy(t)) return src;
	return copyFnName(gen, t as Type) + "(" + src + ")";
}

function identFromKey(key: string): string {
	let out = "";
	let i = 0;
	while (i < key.byteLength) {
		const b = key.byteAt(i);
		const isAlnum = (b >= "a".code && b <= "z".code)
			|| (b >= "A".code && b <= "Z".code)
			|| (b >= "0".code && b <= "9".code);
		if (isAlnum) {
			out = out + key.byteSlice(i, i + 1);
		} else {
			out = out + "_" + b.toString(16);
		}
		i += 1;
	}
	return out;
}

function copyFnName(gen: JSGenerator, t: Type): string {
	registryFor(gen);
	const key = typeKey(t);
	let i = 0;
	while (i < copyKeys.length) {
		if (copyKeys[i] == key) return copyNames[i];
		i += 1;
	}
	const name = "msValCopy_" + identFromKey(key);
	copyKeys.push(key);
	copyNames.push(name);
	gen.staticSlots.push(buildCopyFn(gen, t, name));
	return name;
}

function buildCopyFn(gen: JSGenerator, t: Type, name: string): string {
	let body = "";
	if (t.kind == TypeKind.Struct) {
		body = "return { ";
		let i = 0;
		while (i < t.typeNames.length) {
			if (i > 0) body = body + ", ";
			const fname = t.typeNames[i];
			const ft = i < t.typeChildren.length ? t.typeChildren[i] : null;
			body = body + fname + ": " + copyExpr(gen, ft, "v." + fname);
			i += 1;
		}
		body = body + " };";
	} else if (t.kind == TypeKind.Tuple) {
		body = "return [";
		let i = 0;
		while (i < t.typeChildren.length) {
			if (i > 0) body = body + ", ";
			body = body + copyExpr(gen, t.typeChildren[i], "v[" + i.toString() + "]");
			i += 1;
		}
		body = body + "];";
	} else {
		const elem = t.typeReturn;
		const typedName = t.kind == TypeKind.SizedArray && elem != null
			? jsTypedArrayName(elem.kind) : "";
		if (needsValueCopy(elem)) {
			body = "return v.map(" + copyFnName(gen, elem as Type) + ");";
		} else if (typedName != "" ) {
			body = "return v.slice();";
		} else {
			body = "return v.slice();";
		}
	}
	return "function " + name + "(v) { if (v === null || v === undefined) return v; " + body + " }\n";
}

function isElementRead(n: Node): boolean {
	const sym = n.resolvedSym;
	return sym != null && (sym.name == "msArrayAt" || sym.name == "msSpanAt");
}

function isFreshRvalue(n: Node): boolean {
	match (n.kind) {
		NodeKind.NumberLiteral => { return true; },
		NodeKind.StringLiteral => { return true; },
		NodeKind.BooleanLiteral => { return true; },
		NodeKind.ArrayLiteral => { return true; },
		NodeKind.ObjectLiteral => { return true; },
		NodeKind.CallExpr => { return !isElementRead(n); },
		NodeKind.NewExpr => { return true; },
		NodeKind.MoveExpr => { return true; },
		NodeKind.ArrowFunction => { return true; },
		NodeKind.FunctionExpr => { return true; },
		NodeKind.BinaryExpr => {
			const d = n.data as BinaryExprData;
			return d.operator != "=";
		},
		NodeKind.ConditionalExpr => {
			const d = n.data as ConditionalExprData;
			return isFreshRvalue(d.ternaryConsequent) && isFreshRvalue(d.ternaryAlternate);
		},
		NodeKind.TypeAssertion => {
			const d = n.data as TypeAssertionData;
			return isFreshRvalue(d.asExpr);
		},
		_ => { return false; },
	};
}

export function emitCopyOnRead(gen: JSGenerator, node: Node): void {
	const t = jsValueRepr(node.nodeType);
	if (!needsValueCopy(t) || isFreshRvalue(node)) {
		emitNode(gen, node);
		return;
	}
	emit(gen, copyFnName(gen, t as Type) + "(");
	emitNode(gen, node);
	emit(gen, ")");
}

export function valueCopyFnName(gen: JSGenerator, t: Type | null): string {
	const repr = jsValueRepr(t);
	if (!needsValueCopy(repr)) return "";
	return copyFnName(gen, repr as Type);
}

// Assignment into a location that already holds a value copies in place:
// every other pointer to that location keeps seeing it, as on C.
function assignFnName(gen: JSGenerator, t: Type): string {
	registryFor(gen);
	const key = typeKey(t);
	let i = 0;
	while (i < assignKeys.length) {
		if (assignKeys[i] == key) return assignNames[i];
		i += 1;
	}
	const name = "msValAssign_" + identFromKey(key);
	assignKeys.push(key);
	assignNames.push(name);
	gen.staticSlots.push(buildAssignFn(gen, t, name));
	return name;
}

function assignExpr(gen: JSGenerator, t: Type | null, dst: string, src: string): string {
	t = jsValueRepr(t);
	if (!needsValueCopy(t)) return src;
	return assignFnName(gen, t as Type) + "(" + dst + ", " + src + ")";
}

function buildAssignFn(gen: JSGenerator, t: Type, name: string): string {
	const copy = copyFnName(gen, t);
	let body = "";
	if (t.kind == TypeKind.Struct) {
		let i = 0;
		while (i < t.typeNames.length) {
			const f = t.typeNames[i];
			const ft = i < t.typeChildren.length ? t.typeChildren[i] : null;
			body = body + "d." + f + " = " + assignExpr(gen, ft, "d." + f, "v." + f) + "; ";
			i += 1;
		}
	} else if (t.kind == TypeKind.Tuple) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const at = "[" + i.toString() + "]";
			body = body + "d" + at + " = " + assignExpr(gen, t.typeChildren[i], "d" + at, "v" + at) + "; ";
			i += 1;
		}
	} else {
		body = "if (ArrayBuffer.isView(d)) { if (d.length !== v.length) return " + copy + "(v); d.set(v); return d; } "
			+ "d.length = v.length; "
			+ "for (let i = 0; i < v.length; i++) d[i] = " + assignExpr(gen, t.typeReturn, "d[i]", "v[i]") + "; ";
	}
	return "function " + name + "(d, v) { if (v === null || v === undefined) return v; "
		+ "if (d === null || d === undefined) return " + copy + "(v); " + body + "return d; }\n";
}

function isSimpleLvalue(n: Node): boolean {
	match (n.kind) {
		NodeKind.Identifier => { return true; },
		NodeKind.NumberLiteral => { return true; },
		NodeKind.StringLiteral => { return true; },
		NodeKind.MemberExpr => {
			const d = n.data as MemberExprData;
			return !d.isOptional && isSimpleLvalue(d.object);
		},
		NodeKind.ArrayAccess => {
			const d = n.data as ArrayAccessData;
			return isSimpleLvalue(d.array) && isSimpleLvalue(d.index);
		},
		NodeKind.HiddenDeref => { return isSimpleLvalue((n.data as HiddenDerefData).expr); },
		_ => { return false; },
	};
}

// A value parameter or a for-of binding is a view of the caller's value: an
// assignment to it rebinds to its own copy (C gives it an owned shadow,
// CK-18/CK-30), it never writes through into the value it views.
function storeFnName(gen: JSGenerator, t: Type): string {
	registryFor(gen);
	const key = "store:" + typeKey(t);
	let i = 0;
	while (i < assignKeys.length) {
		if (assignKeys[i] == key) return assignNames[i];
		i += 1;
	}
	const name = "msValStore_" + identFromKey(typeKey(t));
	assignKeys.push(key);
	assignNames.push(name);
	gen.staticSlots.push("function " + name + "(o, k, v) { return o[k] = " + assignFnName(gen, t) + "(o[k], v); }\n");
	return name;
}

// Assignment of a value struct into a location that already holds one writes
// into that location's object: every Ptr to the location keeps seeing it,
// as on C. `x[] = v` writes through the pointer. A view binding rebinds (the
// caller emits `x = copy(v)`); so does a location that cannot be named twice
// without evaluating its parts twice, through `msValStore_` (object, key).
export function emitValueAssign(gen: JSGenerator, left: Node, right: Node): boolean {
	const t = jsValueRepr(left.nodeType);
	if (!needsValueCopy(t)) return false;
	if (left.kind == NodeKind.HiddenDeref && left.flags.has(NodeFlag.ExplicitDeref)) {
		emit(gen, assignFnName(gen, t as Type) + "(");
		emitNode(gen, left);
		emit(gen, ", ");
		emitNode(gen, right);
		emit(gen, ")");
		return true;
	}
	if (left.kind == NodeKind.Identifier && isViewBinding(left.resolvedSym)) return false;
	const assign = assignFnName(gen, t as Type);
	if (isSimpleLvalue(left)) {
		emitNode(gen, left);
		emit(gen, " = " + assign + "(");
		emitNode(gen, left);
		emit(gen, ", ");
		emitNode(gen, right);
		emit(gen, ")");
		return true;
	}
	if (left.kind == NodeKind.ArrayAccess) {
		const d = left.data as ArrayAccessData;
		emit(gen, storeFnName(gen, t as Type) + "(");
		emitNode(gen, d.array);
		emit(gen, ", ");
		emitNode(gen, d.index);
		emit(gen, ", ");
		emitNode(gen, right);
		emit(gen, ")");
		return true;
	}
	if (left.kind == NodeKind.MemberExpr && !(left.data as MemberExprData).isOptional) {
		const d = left.data as MemberExprData;
		emit(gen, storeFnName(gen, t as Type) + "(");
		emitNode(gen, d.object);
		emit(gen, ", \"" + d.property + "\", ");
		emitNode(gen, right);
		emit(gen, ")");
		return true;
	}
	return false;
}

// The element type an array value of static type `t` holds, through a
// `T[]` (Ref<Array>) envelope; null when `t` is not an array.
function arrayOf(t: Type | null): Type | null {
	t = jsValueRepr(t);
	if (t != null && t.kind == TypeKind.Ref && t.typeReturn != null) t = t.typeReturn;
	if (t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray)) return t;
	return null;
}

// Native code knows no value semantics. A value that crosses into it through a
// `sink` parameter is stored there, so it is copied in; a value that comes back out
// shares the native store's object, so it is copied out — for an array result
// of value structs, element by element.
export function emitNativeArg(gen: JSGenerator, arg: Node, formal: Type | null): void {
	if (formal != null && formal.kind == TypeKind.Sink) {
		emitCopyOnRead(gen, arg);
		return;
	}
	emitNode(gen, arg);
}

export function nativeResultCopy(gen: JSGenerator, t: Type | null): string {
	const r = jsValueRepr(t);
	if (needsValueCopy(r)) return copyFnName(gen, r as Type);
	const arr = arrayOf(t);
	if (arr != null && needsValueCopy(arr.typeReturn)) return copyFnName(gen, arr);
	return "";
}

// `[...xs]`: a spread copies each value-struct element, as an array literal
// copies each listed element.
export function emitArrayElement(gen: JSGenerator, el: Node): void {
	if (el.kind != NodeKind.SpreadExpr) {
		emitCopyOnRead(gen, el);
		return;
	}
	const arg = (el.data as SpreadExprData).spreadArg;
	const arr = arrayOf(arg.nodeType);
	emit(gen, "...");
	if (arr != null && needsValueCopy(arr.typeReturn) && !isFreshRvalue(arg)) {
		emit(gen, copyFnName(gen, arr) + "(");
		emitNode(gen, arg);
		emit(gen, ")");
		return;
	}
	emitNode(gen, arg);
}
