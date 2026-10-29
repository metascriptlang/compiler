import { Type, TypeKind, Symbol, SymbolKind, SymbolFlag, NodeKind, FunctionDeclData } from "../../ast/node";
import { ExportedSymInfo, isExtensionRoutine, isGenericFn } from "../../checker/context";
import { hasFlag } from "../../checker/symbol";
import { PEEL_ALIAS, hasGenericParams, isMaybeType, peelThrough, typeDisplayNameUnprofiled } from "../../checker/types";
import { dirname, relative } from "std/fs/path";

export enum BoundaryKind {
	Bool, I8, I16, I32, U8, U16, U32, I64, U64, F32, F64, Void, Callback, String,
}

export enum BoundaryMode {
	Copied,
	Shared,
	Borrowed,
}

export interface BoundaryCallback {
	params: BoundaryKind[];
	result: BoundaryKind;
	signature: string;
}

export interface BoundaryParam {
	name: string;
	kind: BoundaryKind;
	mode: BoundaryMode;
	callback: BoundaryCallback | null;
}

export interface BoundaryFunction {
	modulePath: string;
	moduleKey: string;
	name: string;
	exportSymbol: string;
	params: BoundaryParam[];
	result: BoundaryKind;
}

export interface Manifest {
	functions: BoundaryFunction[];
	errors: string[];
}

interface Collector {
	errors: string[];
	fnName: string;
	modulePath: string;
}

export function signatureLetter(kind: BoundaryKind): string {
	switch (kind) {
		case BoundaryKind.Bool:
		case BoundaryKind.I8:
		case BoundaryKind.I16:
		case BoundaryKind.I32:
		case BoundaryKind.U8:
		case BoundaryKind.U16:
		case BoundaryKind.U32:
			return "i";
		case BoundaryKind.I64:
		case BoundaryKind.U64:
			return "j";
		case BoundaryKind.F32:
			return "f";
		case BoundaryKind.F64:
			return "d";
		case BoundaryKind.Void:
			return "v";
		default:
			throw new Error("internal: boundary kind " + kind.toString() + " has no callback signature letter");
	}
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

function refuse(c: Collector, what: string, t: Type, why: string): void {
	c.errors.push(`'${c.fnName}' in '${c.modulePath}' cannot cross the JS/wasm boundary: ${what} has type '${describe(t)}', ${why}`);
}

function callbackOf(c: Collector, what: string, t: Type): BoundaryCallback | null {
	let ok = true;
	const params: BoundaryKind[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const pt = peeled(t.typeChildren[i]);
		const k = isMaybeType(pt) ? null : scalarKind(pt);
		if (k == null) {
			refuse(c, `parameter ${i + 1} of ${what}`, pt, "and a callback crossing the boundary takes only bool, integer and float parameters");
			ok = false;
		} else {
			params.push(k);
		}
	}
	let result = BoundaryKind.Void;
	if (!isVoidType(t.typeReturn)) {
		const rt = peeled(t.typeReturn!);
		const k = isMaybeType(rt) ? null : scalarKind(rt);
		if (k == null) {
			refuse(c, `the result of ${what}`, rt, "and a callback crossing the boundary returns only void, bool, integer and float");
			ok = false;
		} else {
			result = k;
		}
	}
	if (!ok) return null;
	let letters = "";
	for (const p of params) letters += signatureLetter(p);
	return { params, result, signature: signatureLetter(result) + "_" + letters };
}

function paramOf(c: Collector, name: string, type: Type): BoundaryParam | null {
	const t = peeled(type);
	const what = `parameter '${name}'`;
	if (isMaybeType(t)) {
		refuse(c, what, t, "which is not supported: pass a plain value");
		return null;
	}
	const scalar = scalarKind(t);
	if (scalar != null) return { name, kind: scalar, mode: BoundaryMode.Copied, callback: null };
	if (t.kind == TypeKind.String) return { name, kind: BoundaryKind.String, mode: BoundaryMode.Copied, callback: null };
	if (t.kind == TypeKind.Function) {
		const cb = callbackOf(c, what, t);
		return cb == null ? null : { name, kind: BoundaryKind.Callback, mode: BoundaryMode.Borrowed, callback: cb };
	}
	refuse(c, what, t, "which has no JS/wasm boundary form: use bool, integers, floats, string or a callback");
	return null;
}

function resultOf(c: Collector, type: Type | null): BoundaryKind | null {
	if (isVoidType(type)) return BoundaryKind.Void;
	const t = peeled(type!);
	if (isMaybeType(t)) {
		refuse(c, "the result", t, "which is not supported: return a plain value");
		return null;
	}
	const scalar = scalarKind(t);
	if (scalar != null) return scalar;
	if (t.kind == TypeKind.String) return BoundaryKind.String;
	refuse(c, "the result", t, "which has no JS/wasm boundary form: return void, bool, an integer, a float or a string");
	return null;
}

function fnFlagsOf(sym: Symbol): string {
	return sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl ? (sym.declNode.data as FunctionDeclData).fnFlags : "";
}

function boundaryFunction(c: Collector, key: string, name: string, sym: Symbol): BoundaryFunction | null {
	c.fnName = name;
	const flags = fnFlagsOf(sym);
	if (sym.overloads.length > 0) {
		c.errors.push(`'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it is an overload set, and one export symbol names one function; give each overload its own name`);
		return null;
	}
	if (isGenericFn(flags) || hasGenericParams(sym.symbolType)) {
		c.errors.push(`'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it is generic, and a boundary function has one concrete signature; export a non-generic wrapper`);
		return null;
	}
	if (isExtensionRoutine(flags)) {
		c.errors.push(`'${name}' in '${c.modulePath}' cannot cross the JS/wasm boundary: it is an extension routine; export a plain function that takes the receiver as a parameter`);
		return null;
	}
	const ft = peeled(sym.symbolType);
	const params: BoundaryParam[] = [];
	let ok = true;
	for (let i = 0; i < ft.typeChildren.length; i += 1) {
		const p = paramOf(c, ft.typeNames[i], ft.typeChildren[i]);
		if (p == null) ok = false;
		else params.push(p);
	}
	const result = resultOf(c, ft.typeReturn);
	if (!ok || result == null) return null;
	return { modulePath: c.modulePath, moduleKey: key, name, exportSymbol: `msb_${key}_${name}`, params, result };
}

export function manifestFor(modulePath: string, entryPath: string, exports: ExportedSymInfo[]): Manifest {
	const key = moduleKeyOf(modulePath, entryPath);
	const c: Collector = { errors: [], fnName: "", modulePath };
	const functions: BoundaryFunction[] = [];
	for (const e of exports) {
		if (e.sym.symbolKind != SymbolKind.Function || hasFlag(e.sym, SymbolFlag.OverloadSig)) continue;
		const f = boundaryFunction(c, key, e.name, e.sym);
		if (f != null) functions.push(f);
	}
	return { functions, errors: c.errors };
}
