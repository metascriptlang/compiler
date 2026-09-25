// JavaScript Codegen — Map/Set keys that compare by value.
//
// The JS collections bind the native Map/Set, which compare an object key by
// reference. The native backend finds a struct or tuple key by hash + the
// generated Eq, so here such a collection is a layer over a native Map keyed by
// a canonical string that is equal exactly when the keys are `==`: struct and
// tuple parts fold field by field, anything else goes through one primitive
// encoder (identity for objects and functions, NaN never equal to itself).

import { Type, TypeKind, TypeFlag, NodeFlag } from "../../ast/node";
import { NewExprData, CallExprData, Node } from "../../ast/node";
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
	+ "    return { prim, ValueMap, ValueSet };\n"
	+ "  })());\n"
	+ "}\n";

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
		emit(gen, isMap ? "new Map(" : "new Set(");
		emitJoinedNodes(gen, d.newArguments, ", ");
		emit(gen, ")");
		return true;
	}
	registryFor(gen);
	if (!runtimeEmitted) {
		runtimeEmitted = true;
		gen.staticSlots.push(RUNTIME);
	}
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
	if (shape == null) return false;
	registryFor(gen);
	if (!runtimeEmitted) {
		runtimeEmitted = true;
		gen.staticSlots.push(RUNTIME);
	}
	const copy = valueCopyFnName(gen, keyType);
	emit(gen, "new (msValueKeys().ValueMap)(" + keyFnName(gen, shape) + ", " + (copy != "" ? copy : "null") + ", ");
	emitNode(gen, d.arguments[0]);
	emit(gen, ".map((k, i) => [k, ");
	emitNode(gen, d.arguments[1]);
	emit(gen, "[i]]))");
	return true;
}
