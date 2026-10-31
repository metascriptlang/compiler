import { Type, TypeKind, Symbol, SymbolKind, SymbolFlag, Node, NodeKind, FunctionDeclData, SourceLocation, makeLoc } from "../../ast/node";
import { ExportedSymInfo, LIFECYCLE_HOOK_NAMES, isExtensionRoutine, isGenericFn, lifecycleHookOp } from "../../checker/context";
import { lookupInstanceHook } from "../../checker/instantiate";
import { hasFlag } from "../../checker/symbol";
import { PEEL_ALIAS, getAttachedOp, hasGenericParams, isAtomicRef, isLockedRef, isMaybeType, isReadonlyView, isStdCollection, isStructType, literalBase, peelThrough, runtimeClassSym, typeDisplayNameUnprofiled, unwrapRefNullUnion } from "../../checker/types";
import { dirname, relative } from "std/fs/path";

export enum BoundaryKind {
	Bool, I8, I16, I32, U8, U16, U32, I64, U64, F32, F64, Void, Callback, String, Struct, Vec, Span,
}

export interface BoundaryLeaf {
	path: string[];
	kind: BoundaryKind;
}

export enum BoundaryMode {
	Copied,
	Shared,
	Borrowed,
}

export interface BoundaryCallback {
	params: BoundaryKind[];
	elements: BoundaryKind[];
	modes: BoundaryMode[];
	result: BoundaryKind;
	signature: string;
}

export interface BoundaryParam {
	name: string;
	kind: BoundaryKind;
	mode: BoundaryMode;
	callback: BoundaryCallback | null;
	leaves: BoundaryLeaf[];
	element: BoundaryKind;
}

export interface BoundaryFunction {
	modulePath: string;
	moduleKey: string;
	name: string;
	overloadIndex: number;
	exportSymbol: string;
	params: BoundaryParam[];
	result: BoundaryKind;
	resultLeaves: BoundaryLeaf[];
	resultElement: BoundaryKind;
}

export interface BoundaryRefusal {
	file: string;
	code: string;
	message: string;
	line: int32;
	column: int32;
	endLine: int32;
	endColumn: int32;
}

export interface Manifest {
	functions: BoundaryFunction[];
	errors: BoundaryRefusal[];
}

interface Collector {
	errors: BoundaryRefusal[];
	fnName: string;
	modulePath: string;
	at: SourceLocation;
}

export function unwiredKind(kind: BoundaryKind, what: string): never {
	throw new Error(`internal: boundary kind ${BoundaryKind[kind]} has no ${what}`);
}

export function copiesArgsIn(f: BoundaryFunction): boolean {
	for (const p of f.params) {
		if (p.kind == BoundaryKind.String || p.kind == BoundaryKind.Vec || p.kind == BoundaryKind.Span) return true;
		if (p.kind == BoundaryKind.Struct) {
			for (const leaf of p.leaves) {
				if (leaf.kind == BoundaryKind.String) return true;
			}
		}
	}
	return false;
}

export function signatureLetter(kind: BoundaryKind): string {
	return match (kind) {
		BoundaryKind.Bool
			| BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32 => "i",
		BoundaryKind.I64 | BoundaryKind.U64 => "j",
		BoundaryKind.F32 => "f",
		BoundaryKind.F64 => "d",
		BoundaryKind.Void => "v",
		BoundaryKind.String => "s",
		BoundaryKind.Span => "p",
		BoundaryKind.Callback | BoundaryKind.Struct | BoundaryKind.Vec => { unwiredKind(kind, "callback signature letter"); },
	};
}

export function msTypeOf(kind: BoundaryKind): string {
	return match (kind) {
		BoundaryKind.Bool => "boolean",
		BoundaryKind.I8 => "int8",
		BoundaryKind.I16 => "int16",
		BoundaryKind.I32 => "int32",
		BoundaryKind.I64 => "int64",
		BoundaryKind.U8 => "uint8",
		BoundaryKind.U16 => "uint16",
		BoundaryKind.U32 => "uint32",
		BoundaryKind.U64 => "uint64",
		BoundaryKind.F32 => "float32",
		BoundaryKind.F64 => "float64",
		BoundaryKind.Void => "void",
		BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "scalar type"); },
	};
}

function hex2(b: int32): string {
	const digits = "0123456789abcdef";
	return digits.slice(b >> 4, (b >> 4) + 1) + digits.slice(b & 15, (b & 15) + 1);
}

export function moduleKeyOf(modulePath: string, entryPath: string): string {
	const rel = relative(dirname(entryPath), modulePath);
	const dot = rel.lastIndexOf(".");
	const stem = dot > rel.lastIndexOf("/") ? rel.slice(0, dot) : rel;
	let key = "";
	for (let i = 0; i < stem.byteLength; i += 1) {
		const b = stem.byteAt(i);
		const alnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122);
		if (alnum) key += stem.slice(i, i + 1);
		else if (b == 95) key += "__";
		else if (b == 47) key += "_s";
		else key += "_x" + hex2(b);
	}
	return key;
}

function scalarKind(t: Type): BoundaryKind | null {
	switch (t.kind) {
		case TypeKind.Boolean: return BoundaryKind.Bool;
		case TypeKind.Int8: return BoundaryKind.I8;
		case TypeKind.Int16: return BoundaryKind.I16;
		case TypeKind.Int32: return BoundaryKind.I32;
		case TypeKind.Int64: return BoundaryKind.I64;
		case TypeKind.Uint8: return BoundaryKind.U8;
		case TypeKind.Uint16: return BoundaryKind.U16;
		case TypeKind.Uint32: return BoundaryKind.U32;
		case TypeKind.Uint64: return BoundaryKind.U64;
		case TypeKind.Float32: return BoundaryKind.F32;
		case TypeKind.Float64:
		case TypeKind.Number:
			return BoundaryKind.F64;
		default: return null;
	}
}

function describe(t: Type): string {
	if (isMaybeType(t)) return "a nullable type";
	return typeDisplayNameUnprofiled(t);
}

function peeled(t: Type): Type {
	return peelThrough(t, PEEL_ALIAS) ?? t;
}

function isVoidType(t: Type | null): boolean {
	if (t == null) return true;
	const p = peeled(t);
	return p.kind == TypeKind.Void || p.kind == TypeKind.None;
}

function refuseAt(c: Collector, code: string, message: string): void {
	c.errors.push({ file: c.modulePath, code, message, line: c.at.line, column: c.at.column, endLine: c.at.endLine, endColumn: c.at.endColumn });
}

function refuse(c: Collector, code: string, what: string, t: Type, why: string): void {
	refuseAt(c, code, `'${c.fnName}' in '${c.modulePath}' cannot cross the JS/wasm boundary: ${what} has type '${describe(t)}', ${why}`);
}

function callbackOf(c: Collector, what: string, t: Type): BoundaryCallback | null {
	let ok = true;
	const params: BoundaryKind[] = [];
	const elements: BoundaryKind[] = [];
	const modes: BoundaryMode[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const pt = peeled(t.typeChildren[i]);
		let k = isMaybeType(pt) ? null : pt.kind == TypeKind.String ? BoundaryKind.String : scalarKind(pt);
		let element = BoundaryKind.Void;
		if (pt.kind == TypeKind.Span && pt.typeReturn != null) {
			const et = peeled(pt.typeReturn!);
			const ek = isMaybeType(et) ? null : scalarKind(et);
			if (ek != null) {
				k = BoundaryKind.Span;
				element = ek;
			}
		}
		if (k == null) {
			refuse(c, "callback-param", `parameter ${i + 1} of ${what}`, pt, "and a callback crossing the boundary takes only bool, integer, float, string and Span-of-number parameters");
			ok = false;
		} else {
			params.push(k);
			elements.push(element);
			modes.push(k != BoundaryKind.Span ? BoundaryMode.Copied : isReadonlyView(pt) ? BoundaryMode.Borrowed : BoundaryMode.Shared);
		}
	}
	let result = BoundaryKind.Void;
	if (!isVoidType(t.typeReturn)) {
		const rt = peeled(t.typeReturn!);
		const k = isMaybeType(rt) ? null : scalarKind(rt);
		if (k == null) {
			refuse(c, "callback-result", `the result of ${what}`, rt, "and a callback crossing the boundary returns only void, bool, integer and float");
			ok = false;
		} else {
			result = k;
		}
	}
	if (!ok) return null;
	let letters = "";
	for (const p of params) letters += signatureLetter(p);
	return { params, elements, modes, result, signature: signatureLetter(result) + "_" + letters };
}

export function leafLiteral(leaves: BoundaryLeaf[], values: string[], depth: int32): string {
	const parts: string[] = [];
	let i = 0;
	while (i < leaves.length) {
		const key = leaves[i].path[depth];
		let j = i;
		while (j < leaves.length && leaves[j].path[depth] == key) j += 1;
		const value = leaves[i].path.length == depth + 1 ? values[i] : leafLiteral(leaves.slice(i, j), values.slice(i, j), depth + 1);
		parts.push(`${key}: ${value}`);
		i = j;
	}
	return parts.length == 0 ? "{}" : `{ ${parts.join(", ")} }`;
}

interface ValueShape {
	kind: BoundaryKind;
	leaves: BoundaryLeaf[];
	element: BoundaryKind;
}

function declaresHook(t: Type): boolean {
	for (const name of LIFECYCLE_HOOK_NAMES) {
		const op = lifecycleHookOp(name);
		if (getAttachedOp(t, op) != null || lookupInstanceHook(t, op) != null) return true;
	}
	return false;
}

function structLeaves(c: Collector, what: string, t: Type, path: string[], out: BoundaryLeaf[]): boolean {
	if (declaresHook(t)) {
		refuse(c, "struct-hook", what, t, "which declares a lifecycle hook, and a copy made field by field would skip it");
		return false;
	}
	let ok = true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const fieldPath = path.concat([t.typeNames[i]]);
		const ft = peeled(t.typeChildren[i]);
		const fieldWhat = `field '${fieldPath.join(".")}' of ${what}`;
		const scalar = isMaybeType(ft) ? null : scalarKind(ft);
		if (scalar != null) out.push({ path: fieldPath, kind: scalar });
		else if (ft.kind == TypeKind.String) out.push({ path: fieldPath, kind: BoundaryKind.String });
		else if (isStructType(ft) && !isMaybeType(ft)) ok = structLeaves(c, fieldWhat, ft, fieldPath, out) && ok;
		else {
			refuse(c, "struct-field", fieldWhat, ft, noFormWhy(ft, NoFormAt.Field) ?? "and a struct crosses the boundary as a copy of its bool, integer, float, string and struct fields");
			ok = false;
		}
	}
	return ok;
}

enum NoFormAt { Param, Result, Field }

function byPosition(at: NoFormAt, param: string, result: string, field: string): string {
	if (at == NoFormAt.Param) return param;
	return at == NoFormAt.Result ? result : field;
}

function isClassRef(t: Type): boolean {
	if (isAtomicRef(t) || isLockedRef(t)) return false;
	const target = t.kind == TypeKind.Ref && t.typeReturn != null ? peeled(t.typeReturn!) : t;
	return runtimeClassSym(target) != null;
}

function classWhy(at: NoFormAt, nullable: boolean): string {
	const identity = `and a ${nullable ? "nullable " : ""}class instance has an identity on one heap and does not cross as a copy: `;
	const later = "; sharing the instance itself waits for Handle<T>, which is planned";
	return identity + byPosition(at, "pass the values it holds as parameters or as a struct, which crosses as a copy", "return the values it holds as a struct, which crosses as a copy", "copy the values it holds into fields of the struct") + later;
}

function noFormWhy(t: Type, at: NoFormAt): string | null {
	if (isMaybeType(t)) return null;
	if (t.kind == TypeKind.Function) {
		const only = "and a function crosses the boundary only as a parameter, borrowed for the call, so it cannot be ";
		if (at == NoFormAt.Result) return only + "a result: return the value it computes";
		if (at == NoFormAt.Field) return only + "a struct field: pass it as a separate parameter";
		return null;
	}
	if (t.kind == TypeKind.Enum || t.kind == TypeKind.EnumLiteral) {
		const crossing = byPosition(at, "passing 'x as int32'", "returning 'x as int32'", "declaring the field as int32 and writing 'x as int32'");
		return `and an enum has no boundary form yet: cross its integer instead, ${crossing}, and converting back with 'n as ${describe(literalBase(t))}', which checks the range`;
	}
	if (t.kind == TypeKind.Union) {
		const held = unwrapRefNullUnion(t);
		if (held != null) return isClassRef(held) ? classWhy(at, true) : null;
		const variants = "and a union has no single boundary form: ";
		return variants + byPosition(at, "pass a tag integer and the payload as separate parameters, or give each variant its own @wasm function", "return a struct with a tag integer and one field per variant, or give each variant its own @wasm function", "flatten it into a tag integer field and one field per variant");
	}
	if (isStdCollection(t)) {
		const table = "and a Map or Set is a hash table that lives on one heap and ";
		const noStringKeys = "(string keys have no Vec form yet)";
		return table + byPosition(at, `does not cross: pass its keys and values as separate Vec parameters of numbers and rebuild it on the other side ${noStringKeys}`, `does not cross: return a Vec of numbers and rebuild it on the other side, a Map's keys from one @wasm function and its values from another ${noStringKeys}`, `cannot be a struct field: pass its keys and values as separate Vec parameters of numbers instead ${noStringKeys}`);
	}
	if (t.kind == TypeKind.Ref && t.typeReturn != null && peeled(t.typeReturn!).kind == TypeKind.Array) {
		const array = "and an array reference lives on one heap and does not cross";
		return byPosition(at, `${array}: use a Vec of bool, integer or float elements, which crosses as a copy`, `${array}: return a Vec of bool, integer or float elements, which crosses as a copy`, `${array}, and a struct holds no Vec: pass the elements as a separate Vec parameter`);
	}
	return isClassRef(t) ? classWhy(at, false) : null;
}

function valueShape(c: Collector, what: string, t: Type): ValueShape | null {
	if (isStructType(t)) {
		const leaves: BoundaryLeaf[] = [];
		return structLeaves(c, what, t, [], leaves) ? { kind: BoundaryKind.Struct, leaves, element: BoundaryKind.Void } : null;
	}
	if (t.kind == TypeKind.Array && t.typeReturn != null) {
		const et = peeled(t.typeReturn!);
		const element = isMaybeType(et) ? null : scalarKind(et);
		if (element == null) {
			refuse(c, "vec-element", what, t, "and a Vec crosses the boundary as a copy of bool, integer or float elements");
			return null;
		}
		return { kind: BoundaryKind.Vec, leaves: [], element };
	}
	return null;
}

function paramOf(c: Collector, name: string, type: Type): BoundaryParam | null {
	const t = peeled(type);
	const what = `parameter '${name}'`;
	if (isMaybeType(t)) {
		refuse(c, "optional", what, t, "which is not supported: pass a plain value");
		return null;
	}
	const scalar = scalarKind(t);
	if (scalar != null) return { name, kind: scalar, mode: BoundaryMode.Copied, callback: null, leaves: [], element: BoundaryKind.Void };
	if (t.kind == TypeKind.String) return { name, kind: BoundaryKind.String, mode: BoundaryMode.Copied, callback: null, leaves: [], element: BoundaryKind.Void };
	if (t.kind == TypeKind.Function) {
		const cb = callbackOf(c, what, t);
		return cb == null ? null : { name, kind: BoundaryKind.Callback, mode: BoundaryMode.Borrowed, callback: cb, leaves: [], element: BoundaryKind.Void };
	}
	if (t.kind == TypeKind.Span && t.typeReturn != null) {
		const et = peeled(t.typeReturn!);
		const element = isMaybeType(et) ? null : scalarKind(et);
		if (element == null) {
			refuse(c, "span-element", what, t, "and a Span crosses the boundary for the call over bool, integer or float elements");
			return null;
		}
		return { name, kind: BoundaryKind.Span, mode: isReadonlyView(t) ? BoundaryMode.Borrowed : BoundaryMode.Shared, callback: null, leaves: [], element };
	}
	const errorsBefore = c.errors.length;
	const shape = valueShape(c, what, t);
	if (shape != null) return { name, kind: shape.kind, mode: BoundaryMode.Copied, callback: null, leaves: shape.leaves, element: shape.element };
	if (c.errors.length == errorsBefore) refuse(c, "no-form", what, t, noFormWhy(t, NoFormAt.Param) ?? "which has no JS/wasm boundary form: use bool, integers, floats, string, a struct of those, a Vec or Span of numbers or a callback");
	return null;
}

function resultOf(c: Collector, type: Type | null): ValueShape | null {
	if (isVoidType(type)) return { kind: BoundaryKind.Void, leaves: [], element: BoundaryKind.Void };
	const t = peeled(type!);
	if (isMaybeType(t)) {
		refuse(c, "optional", "the result", t, "which is not supported: return a plain value");
		return null;
	}
	const scalar = scalarKind(t);
	if (scalar != null) return { kind: scalar, leaves: [], element: BoundaryKind.Void };
	if (t.kind == TypeKind.String) return { kind: BoundaryKind.String, leaves: [], element: BoundaryKind.Void };
	if (t.kind == TypeKind.Span) {
		refuse(c, "span-result", "the result", t, "and a Span borrows its memory only for the call, so it cannot outlive it: return a Vec");
		return null;
	}
	const errorsBefore = c.errors.length;
	const shape = valueShape(c, "the result", t);
	if (shape != null) return shape;
	if (c.errors.length == errorsBefore) refuse(c, "no-form", "the result", t, noFormWhy(t, NoFormAt.Result) ?? "which has no JS/wasm boundary form: return void, bool, an integer, a float, a string, a struct of those or a Vec of numbers");
	return null;
}

function fnFlagsOf(sym: Symbol): string {
	return sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl ? (sym.declNode.data as FunctionDeclData).fnFlags : "";
}

function fnDeclOf(sym: Symbol): Node | null {
	return sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl ? sym.declNode : null;
}

function boundaryFunction(c: Collector, key: string, name: string, sym: Symbol, overloadIndex: number, inSet: boolean): BoundaryFunction | null {
	c.fnName = name;
	const decl = fnDeclOf(sym);
	const nameAt = decl != null ? (decl.data as FunctionDeclData).nameLocation : sym.location;
	c.at = nameAt;
	const flags = fnFlagsOf(sym);
	if (isGenericFn(flags) || hasGenericParams(sym.symbolType)) {
		refuseAt(c, "generic", `'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it is generic, and a boundary function has one concrete signature; export a non-generic wrapper`);
		return null;
	}
	if (isExtensionRoutine(flags)) {
		refuseAt(c, "extension-routine", `'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it is an extension routine; export a plain function that takes the receiver as a parameter`);
		return null;
	}
	const ft = peeled(sym.symbolType);
	const typeExprs = decl != null ? decl.typeExprs : null;
	if (typeExprs != null && typeExprs.length != ft.typeChildren.length) throw new Error(`internal: '${name}' in '${c.modulePath}' has ${ft.typeChildren.length} parameter types but ${typeExprs.length} parameter annotations`);
	const params: BoundaryParam[] = [];
	let ok = true;
	for (let i = 0; i < ft.typeChildren.length; i += 1) {
		const typeExpr = typeExprs != null ? typeExprs[i] : null;
		c.at = typeExpr != null ? typeExpr.location : nameAt;
		const p = paramOf(c, ft.typeNames[i], ft.typeChildren[i]);
		if (p == null) ok = false;
		else params.push(p);
	}
	const resultExpr = decl != null ? decl.typeExpr : null;
	c.at = resultExpr != null ? resultExpr.location : nameAt;
	const result = resultOf(c, ft.typeReturn);
	if (!ok || result == null) return null;
	const exportSymbol = inSet ? `msb_${key}_${name}_u${overloadIndex}` : `msb_${key}_${name}`;
	return { modulePath: c.modulePath, moduleKey: key, name, overloadIndex, exportSymbol, params, result: result.kind, resultLeaves: result.leaves, resultElement: result.element };
}

function kindList(kinds: BoundaryKind[]): string {
	let s = "";
	for (const k of kinds) s += k.toString() + ",";
	return s;
}

function paramShape(p: BoundaryParam): string {
	let s = `${p.kind.toString()}/${p.element.toString()}`;
	for (const leaf of p.leaves) s += `/${leaf.path.join(".")}:${leaf.kind.toString()}`;
	if (p.callback != null) s += `/(${kindList(p.callback!.params)})(${kindList(p.callback!.elements)})${p.callback!.result.toString()}`;
	return s;
}

function callShape(f: BoundaryFunction): string {
	const parts: string[] = [];
	for (const p of f.params) parts.push(paramShape(p));
	return parts.join(";");
}

function nameAtOf(sym: Symbol): SourceLocation {
	const decl = fnDeclOf(sym);
	return decl != null ? (decl.data as FunctionDeclData).nameLocation : sym.location;
}

function setFunctions(c: Collector, key: string, name: string, sym: Symbol, locs: SourceLocation[]): BoundaryFunction[] {
	c.fnName = name;
	const set: Symbol[] = [sym];
	for (const o of sym.overloads) set.push(o);
	let wasm = 0;
	for (const m of set) {
		if (hasFlag(m, SymbolFlag.OverloadSig)) {
			c.at = nameAtOf(m);
			refuseAt(c, "overload-signature", `'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it has overload signatures, which name no function of their own; export the implementation under its own name`);
			return [];
		}
		if (hasFlag(m, SymbolFlag.Wasm)) wasm += 1;
	}
	if (set.length > 1 && wasm != 0 && wasm != set.length) {
		c.at = nameAtOf(set[0]);
		refuseAt(c, "overload-partial", `'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: @wasm is on ${wasm} of its ${set.length} overloads; place every overload in wasm or none, because the wasm side imports the whole set and picks by argument types`);
		return [];
	}
	const out: BoundaryFunction[] = [];
	const outAt: SourceLocation[] = [];
	for (let overloadIndex = 0; overloadIndex < set.length; overloadIndex += 1) {
		const f = boundaryFunction(c, key, name, set[overloadIndex], overloadIndex, set.length > 1);
		if (f == null) continue;
		out.push(f);
		outAt.push(nameAtOf(set[overloadIndex]));
	}
	for (let i = 0; i < out.length; i += 1) {
		for (let j = 0; j < i; j += 1) {
			if (callShape(out[i]) != callShape(out[j])) continue;
			c.at = outAt[i];
			refuseAt(c, "overload-same-shape", `'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: overloads ${out[j].overloadIndex} and ${out[i].overloadIndex} take the same boundary types, so the wasm side cannot tell which one to call; make their parameters differ in count, scalar kind, element kind or struct fields`);
		}
	}
	for (const at of outAt) locs.push(at);
	return out;
}

export function manifestFor(modulePath: string, entryPath: string, exports: ExportedSymInfo[], placed: string[]): Manifest {
	const key = moduleKeyOf(modulePath, entryPath);
	const c: Collector = { errors: [], fnName: "", modulePath, at: makeLoc(0, 0) };
	const functions: BoundaryFunction[] = [];
	const locs: SourceLocation[] = [];
	const seen: string[] = [];
	for (const name of placed) {
		if (seen.includes(name)) continue;
		seen.push(name);
		let found = false;
		for (const e of exports) {
			if (e.name != name || e.sym.symbolKind != SymbolKind.Function) continue;
			found = true;
			for (const f of setFunctions(c, key, e.name, e.sym, locs)) functions.push(f);
		}
		if (!found) throw new Error(`internal: wasm-placed function '${name}' has no export in '${modulePath}'`);
	}
	for (let i = 0; i < functions.length; i += 1) {
		for (let j = 0; j < i; j += 1) {
			if (functions[i].exportSymbol == functions[j].exportSymbol) {
				c.at = locs[i];
				refuseAt(c, "export-collision", `'${functions[i].name}' and '${functions[j].name}' in '${modulePath}' would both export the wasm symbol '${functions[i].exportSymbol}': rename one of them`);
			}
		}
	}
	return { functions, errors: c.errors };
}
