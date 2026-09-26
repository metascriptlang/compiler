// JavaScript Codegen — Map/Set keys that compare like `==`.
//
// The JS collections bind the native Map/Set, which compare keys by
// SameValueZero: an object by reference, NaN equal to itself. The native
// backend finds a key by hash + `==`, so a struct or tuple key goes through a
// layer over a native Map keyed by a canonical string that is equal exactly when
// the keys are `==` (struct and tuple parts fold field by field, identity for
// objects and functions, NaN never equal to itself), and a key that can hold NaN
// goes through a native Map/Set subclass that never finds NaN.

import { Type, TypeKind, TypeFlag, NodeFlag } from "../../ast/node";
import { NewExprData, CallExprData, Node } from "../../ast/node";
import { distinctBody } from "../../checker/types";
import { emit, emitNode, emitJoinedNodes, JSGenerator } from "./emit";
import { valueCopyFnName } from "./valueCopy";

let ownerGen: JSGenerator | null = null;
let keyKeys: string[] = [];
let keyNames: string[] = [];
let runtimeEmitted = false;

function registryFor(gen: JSGenerator): void {
	if (ownerGen != gen) {
		ownerGen = gen;
		keyKeys = [];
		keyNames = [];
		runtimeEmitted = false;
	}
}

// The struct or tuple a key compares through, or null when the key is a
// primitive or a reference (the native Map already compares those like `==`).
function valueKeyShape(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) return valueKeyShape(t.typeReturn);
	if (t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsStruct)) return t;
	if (t.kind == TypeKind.Tuple) return t;
	if (t.kind == TypeKind.GenericInstance && t.typeReturn != null) return valueKeyShape(t.typeReturn);
	return null;
}

function admitsNaN(t: Type | null): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Number || t.kind == TypeKind.Float32 || t.kind == TypeKind.Float64) return true;
	if (t.kind == TypeKind.Alias) return admitsNaN(t.typeReturn);
	if (t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) return admitsNaN(t.typeReturn);
	if (t.kind == TypeKind.Union) {
		for (const m of t.typeChildren) {
			if (admitsNaN(m)) return true;
		}
		return false;
	}
	const body = distinctBody(t);
	return body != null && admitsNaN(body);
}

function shapeKey(t: Type): string {
	const shape = valueKeyShape(t);
	if (shape == null) return "p";
	let key = shape.kind == TypeKind.Tuple ? "T(" : "S:" + shape.typeName + "(";
	let i = 0;
	while (i < shape.typeChildren.length) {
		const fname = shape.kind == TypeKind.Struct && i < shape.typeNames.length ? shape.typeNames[i] : "";
		key = key + fname + ":" + shapeKey(shape.typeChildren[i]) + ",";
		i += 1;
	}
	return key + ")";
}

function identFromKey(key: string): string {
	let out = "";
	let i = 0;
	while (i < key.byteLength) {
		const b = key.byteAt(i);
		const isAlnum = (b >= "a".code && b <= "z".code)
			|| (b >= "A".code && b <= "Z".code)
			|| (b >= "0".code && b <= "9".code);
		out = isAlnum ? out + key.byteSlice(i, i + 1) : out + "_" + b.toString(16);
		i += 1;
	}
	return out;
}

function partExpr(gen: JSGenerator, t: Type | null, src: string): string {
	const shape = valueKeyShape(t);
	if (shape != null) return keyFnName(gen, shape) + "(" + src + ")";
	return "rt.prim(" + src + ")";
}

function keyFnName(gen: JSGenerator, shape: Type): string {
	const key = shapeKey(shape);
	let i = 0;
	while (i < keyKeys.length) {
		if (keyKeys[i] == key) return keyNames[i];
		i += 1;
	}
	const name = "msValueKey_" + identFromKey(key);
	keyKeys.push(key);
	keyNames.push(name);
	let parts = "";
	let j = 0;
	while (j < shape.typeChildren.length) {
		const src = shape.kind == TypeKind.Tuple ? "v[" + j.toString() + "]" : "v." + shape.typeNames[j];
		parts = parts + (j > 0 ? " + \",\" + " : "") + partExpr(gen, shape.typeChildren[j], src);
		j += 1;
	}
	const open = shape.kind == TypeKind.Tuple ? "\"[\"" : "\"{\"";
	const close = shape.kind == TypeKind.Tuple ? "\"]\"" : "\"}\"";
	const body = parts == "" ? open + " + " + close : open + " + " + parts + " + " + close;
	gen.staticSlots.push("function " + name + "(v) { if (v === null || v === undefined) return \"u\"; const rt = msValueKeys(); return " + body + "; }\n");
	return name;
}

// One runtime per JS realm, shared by every module and every emission mode.
const RUNTIME = "function msValueKeys() {\n"
	+ "  return globalThis.__msValueKeys || (globalThis.__msValueKeys = (() => {\n"
	+ "    const ids = new WeakMap();\n"
	+ "    let nextId = 0;\n"
	+ "    let nextNaN = 0;\n"
	+ "    function prim(v) {\n"
	+ "      switch (typeof v) {\n"
	+ "        case \"string\": return \"s\" + v.length + \":\" + v;\n"
	+ "        case \"number\": return v !== v ? \"N\" + (nextNaN++) : \"n\" + (v === 0 ? 0 : v);\n"
	+ "        case \"bigint\": return \"b\" + v;\n"
	+ "        case \"boolean\": return v ? \"T\" : \"F\";\n"
	+ "        case \"undefined\": return \"u\";\n"
	+ "        case \"object\":\n"
	+ "        case \"function\": {\n"
	+ "          if (v === null) return \"u\";\n"
	+ "          let id = ids.get(v);\n"
	+ "          if (id === undefined) { id = ++nextId; ids.set(v, id); }\n"
	+ "          return \"o\" + id;\n"
	+ "        }\n"
	+ "        default: return \"x\" + String(v);\n"
	+ "      }\n"
	+ "    }\n"
	+ "    class ValueMap {\n"
	+ "      constructor(key, copy, init) { this.k = key; this.c = copy; this.m = new Map(); if (init) for (const [a, b] of init) this.set(a, b); }\n"
	+ "      get size() { return this.m.size; }\n"
	+ "      set(a, b) { const c = this.k(a); const e = this.m.get(c); if (e !== undefined) e[1] = b; else this.m.set(c, [this.c ? this.c(a) : a, b]); return this; }\n"
	+ "      get(a) { const e = this.m.get(this.k(a)); return e === undefined ? undefined : e[1]; }\n"
	+ "      has(a) { return this.m.has(this.k(a)); }\n"
	+ "      delete(a) { return this.m.delete(this.k(a)); }\n"
	+ "      clear() { this.m.clear(); }\n"
	+ "      *keys() { for (const e of this.m.values()) yield e[0]; }\n"
	+ "      *values() { for (const e of this.m.values()) yield e[1]; }\n"
	+ "      *entries() { for (const e of this.m.values()) yield [e[0], e[1]]; }\n"
	+ "      [Symbol.iterator]() { return this.entries(); }\n"
	+ "      forEach(f, self) { for (const e of this.m.values()) f.call(self, e[1], e[0], this); }\n"
	+ "    }\n"
	+ "    class ValueSet {\n"
	+ "      constructor(key, copy, init) { this.k = key; this.c = copy; this.m = new Map(); if (init) for (const a of init) this.add(a); }\n"
	+ "      get size() { return this.m.size; }\n"
	+ "      add(a) { const c = this.k(a); if (!this.m.has(c)) this.m.set(c, this.c ? this.c(a) : a); return this; }\n"
	+ "      has(a) { return this.m.has(this.k(a)); }\n"
	+ "      delete(a) { return this.m.delete(this.k(a)); }\n"
	+ "      clear() { this.m.clear(); }\n"
	+ "      *values() { yield* this.m.values(); }\n"
	+ "      keys() { return this.values(); }\n"
	+ "      *entries() { for (const a of this.m.values()) yield [a, a]; }\n"
	+ "      [Symbol.iterator]() { return this.values(); }\n"
	+ "      forEach(f, self) { for (const a of this.m.values()) f.call(self, a, a, this); }\n"
	+ "    }\n"
	+ "    const unNaN = (k) => typeof k === \"symbol\" ? NaN : k;\n"
	+ "    function* keysOf(it) { for (const k of it) yield unNaN(k); }\n"
	+ "    function* entriesOf(it) { for (const [k, v] of it) yield [unNaN(k), v]; }\n"
	+ "    function* pairsOf(it) { for (const k of it) { const u = unNaN(k); yield [u, u]; } }\n"
	+ "    class FloatMap extends Map {\n"
	+ "      get(a) { return a === a ? super.get(a) : undefined; }\n"
	+ "      has(a) { return a === a && super.has(a); }\n"
	+ "      delete(a) { return a === a && super.delete(a); }\n"
	+ "      set(a, b) { if (a === a) return super.set(a, b); this.nan = true; return super.set(Symbol(), b); }\n"
	+ "      clear() { this.nan = false; super.clear(); }\n"
	+ "      keys() { return this.nan ? keysOf(super.keys()) : super.keys(); }\n"
	+ "      entries() { return this.nan ? entriesOf(super.entries()) : super.entries(); }\n"
	+ "      [Symbol.iterator]() { return this.entries(); }\n"
	+ "      forEach(f, self) { super.forEach(this.nan ? (v, k) => f.call(self, v, unNaN(k), this) : f, self); }\n"
	+ "    }\n"
	+ "    class FloatSet extends Set {\n"
	+ "      has(a) { return a === a && super.has(a); }\n"
	+ "      delete(a) { return a === a && super.delete(a); }\n"
	+ "      add(a) { if (a === a) return super.add(a); this.nan = true; return super.add(Symbol()); }\n"
	+ "      clear() { this.nan = false; super.clear(); }\n"
	+ "      values() { return this.nan ? keysOf(super.values()) : super.values(); }\n"
	+ "      keys() { return this.values(); }\n"
	+ "      entries() { return this.nan ? pairsOf(super.values()) : super.entries(); }\n"
	+ "      [Symbol.iterator]() { return this.values(); }\n"
	+ "      forEach(f, self) { super.forEach(this.nan ? (v) => { const u = unNaN(v); f.call(self, u, u, this); } : f, self); }\n"
	+ "    }\n"
	+ "    return { prim, ValueMap, ValueSet, FloatMap, FloatSet };\n"
	+ "  })());\n"
	+ "}\n";

function useRuntime(gen: JSGenerator): void {
	registryFor(gen);
	if (!runtimeEmitted) {
		runtimeEmitted = true;
		gen.staticSlots.push(RUNTIME);
	}
}

function floatCollection(gen: JSGenerator, native: string): string {
	useRuntime(gen);
	return "(msValueKeys().Float" + native + ")";
}

// `new` of a std Map/Set/HashMap/HashSet. HashMap and HashSet have no JS global
// of their own, so the native constructor is named here rather than aliased.
export function emitCollectionNew(gen: JSGenerator, node: Node): boolean {
	const d = node.data as NewExprData;
	const sym = d.newCallee.resolvedSym;
	if (sym == null || sym.declNode == null || !sym.declNode.flags.has(NodeFlag.ExternC)) return false;
	const isMap = sym.name == "Map" || sym.name == "HashMap";
	const isSet = sym.name == "Set" || sym.name == "HashSet";
	if (!isMap && !isSet) return false;
	const keyType = keyTypeOfCollection(node.nodeType);
	const shape = valueKeyShape(keyType);
	if (shape == null) {
		const native = isMap ? "Map" : "Set";
		emit(gen, "new " + (admitsNaN(keyType) ? floatCollection(gen, native) : native) + "(");
		emitJoinedNodes(gen, d.newArguments, ", ");
		emit(gen, ")");
		return true;
	}
	useRuntime(gen);
	const copy = valueCopyFnName(gen, keyType);
	emit(gen, "new (msValueKeys()." + (isMap ? "ValueMap" : "ValueSet") + ")(" + keyFnName(gen, shape) + ", " + (copy != "" ? copy : "null"));
	if (d.newArguments.length > 0) {
		emit(gen, ", ");
		emitJoinedNodes(gen, d.newArguments, ", ");
	}
	emit(gen, ")");
	return true;
}

function keyTypeOfCollection(t: Type | null): Type | null {
	if (t != null && (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) && t.typeReturn != null) t = t.typeReturn;
	return t != null && t.kind == TypeKind.GenericInstance && t.typeChildren.length > 0 ? t.typeChildren[0] : null;
}

// A Map literal reaches JS as std `mapFromPairs(keys, values)`, a native template.
export function emitCollectionFromPairs(gen: JSGenerator, node: Node): boolean {
	const d = node.data as CallExprData;
	const sym = d.callee.resolvedSym;
	if (sym == null || (sym.name != "mapFromPairs" && sym.name != "hashMapFromPairs")) return false;
	if (sym.nativeName == null || sym.nativeName == "" || d.arguments.length != 2) return false;
	const keyType = keyTypeOfCollection(node.nodeType);
	const shape = valueKeyShape(keyType);
	if (shape != null) {
		useRuntime(gen);
		const copy = valueCopyFnName(gen, keyType);
		emit(gen, "new (msValueKeys().ValueMap)(" + keyFnName(gen, shape) + ", " + (copy != "" ? copy : "null") + ", ");
	} else if (admitsNaN(keyType)) {
		emit(gen, "new " + floatCollection(gen, "Map") + "(");
	} else {
		return false;
	}
	emitNode(gen, d.arguments[0]);
	emit(gen, ".map((k, i) => [k, ");
	emitNode(gen, d.arguments[1]);
	emit(gen, "[i]]))");
	return true;
}
