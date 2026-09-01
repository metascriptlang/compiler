// JavaScript Codegen — value-type copy-on-assignment.
//
// The native pipeline gets copy semantics from analyzer-generated hooks; the JS
// pipeline skips that layer (it is DRC-bound), so the copy decision is remade
// here per emission site from the static type, the same way Nim's jsgen decides
// in genAsgn/genObjConstr. Vec and T[] are both plain JS arrays at runtime, so
// a generic structural clone cannot exist — the walker must be per-type.

import { Node, NodeKind, Type, TypeKind, TypeFlag } from "../../ast/node";
import {
	BinaryExprData, ConditionalExprData, TypeAssertionData,
} from "../../ast/node";
import { emit, emitNode, JSGenerator, jsTypedArrayName } from "./emit";

let ownerGen: JSGenerator | null = null;
let copyKeys: string[] = [];
let copyNames: string[] = [];

function registryFor(gen: JSGenerator): void {
	if (ownerGen !== gen) {
		ownerGen = gen;
		copyKeys = [];
		copyNames = [];
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
	if (t === null) return false;
	if (t.kind === TypeKind.Struct) return (t.typeFlags & TypeFlag.IsStruct) !== 0;
	if (t.kind === TypeKind.Tuple) return true;
	if (t.kind === TypeKind.Array) return true;
	if (t.kind === TypeKind.SizedArray) return true;
	return false;
}

// The runtime representation a JS value of static type `t` actually has:
// Maybe<T> carriers are erased to `T | null` (see needsValueCopy).
function jsValueRepr(t: Type | null): Type | null {
	if (t !== null && t.kind === TypeKind.Struct && (t.typeFlags & TypeFlag.IsMaybe) !== 0) {
		return t.typeReturn;
	}
	return t;
}

function typeKey(t: Type): string {
	if (t.kind === TypeKind.Struct) {
		let key = "S:" + t.typeName + "(";
		let i = 0;
		while (i < t.typeChildren.length) {
			const fname = i < t.typeNames.length ? t.typeNames[i] : "";
			key = key + fname + ":" + typeKey(t.typeChildren[i]) + ",";
			i += 1;
		}
		return key + ")";
	}
	if (t.kind === TypeKind.Tuple) {
		let key = "T:(";
		for (const c of t.typeChildren) key = key + typeKey(c) + ",";
		return key + ")";
	}
	if (t.kind === TypeKind.Array && t.typeReturn !== null) return "A:" + typeKey(t.typeReturn);
	if (t.kind === TypeKind.SizedArray && t.typeReturn !== null) return "F:" + typeKey(t.typeReturn);
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
		if (copyKeys[i] === key) return copyNames[i];
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
	if (t.kind === TypeKind.Struct) {
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
	} else if (t.kind === TypeKind.Tuple) {
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
		const typedName = t.kind === TypeKind.SizedArray && elem !== null
			? jsTypedArrayName(elem.kind) : "";
		if (needsValueCopy(elem)) {
			body = "return v.map(" + copyFnName(gen, elem as Type) + ");";
		} else if (typedName !== "" ) {
			body = "return v.slice();";
		} else {
			body = "return v.slice();";
		}
	}
	return "function " + name + "(v) { if (v === null || v === undefined) return v; " + body + " }\n";
}

function isFreshRvalue(n: Node): boolean {
	match (n.kind) {
		NodeKind.NumberLiteral => { return true; },
		NodeKind.StringLiteral => { return true; },
		NodeKind.BooleanLiteral => { return true; },
		NodeKind.ArrayLiteral => { return true; },
		NodeKind.ObjectLiteral => { return true; },
		NodeKind.CallExpr => { return true; },
		NodeKind.NewExpr => { return true; },
		NodeKind.MoveExpr => { return true; },
		NodeKind.ArrowFunction => { return true; },
		NodeKind.FunctionExpr => { return true; },
		NodeKind.BinaryExpr => {
			const d = n.data as BinaryExprData;
			return d.operator !== "=";
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
