import {
	Type,
	TypeKind,
	Symbol,
	SymbolKind,
	SymbolFlag,
	Node,
	NodeKind,
	FunctionDeclData,
	SourceLocation,
	makeLoc,
	BuiltinKind,
} from "../../ast/node";
import {
	ExportedSymInfo,
	LIFECYCLE_HOOK_NAMES,
	isExtensionRoutine,
	isGenericFn,
	lifecycleHookOp,
} from "../../checker/context";
import { lookupInstanceHook } from "../../checker/instantiate";
import { hasFlag } from "../../checker/symbol";
import {
	PEEL_ALIAS,
	getAttachedOp,
	getBuiltinKind,
	hasGenericParams,
	isAtomicRef,
	isLockedRef,
	isMaybeType,
	isReadonlyView,
	isStdCollection,
	isStructType,
	literalBase,
	peelThrough,
	runtimeClassSym,
	typeDisplayNameUnprofiled,
	unwrapMaybeType,
	unwrapRefNullUnion,
} from "../../checker/types";
import { dirname, relative } from "std/fs/path";
import { BoundaryKind, signatureLetter } from "./boundaryKinds";

export interface BoundaryLeaf {
	path: string[];
	kind: BoundaryKind;
	nullable: boolean;
}

export enum BoundaryMode {
	Copied,
	Shared,
	Borrowed,
}

export interface BoundaryCallback {
	params: BoundaryKind[];
	nullables: boolean[];
	elements: BoundaryKind[];
	modes: BoundaryMode[];
	result: BoundaryKind;
	signature: string;
}

export interface BoundaryParam {
	name: string;
	kind: BoundaryKind;
	nullable: boolean;
	mode: BoundaryMode;
	callback: BoundaryCallback | null;
	leaves: BoundaryLeaf[];
	element: BoundaryKind;
	handle: string | null;
}

export interface BoundaryFunction {
	modulePath: string;
	moduleKey: string;
	name: string;
	overloadIndex: int32;
	exportSymbol: string;
	params: BoundaryParam[];
	result: BoundaryKind;
	resultNullable: boolean;
	resultLeaves: BoundaryLeaf[];
	resultElement: BoundaryKind;
	resultHandle: string | null;
	resultLabel: string;
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
	handles: Symbol[];
}

interface Collector {
	errors: BoundaryRefusal[];
	fnName: string;
	modulePath: string;
	entryPath: string;
	at: SourceLocation;
	exports: ExportedSymInfo[];
	handles: Symbol[];
}

export function copiesArgsIn(f: BoundaryFunction): boolean {
	for (const p of f.params) {
		if (crossesAsPointerAndLength(p.kind)) return true;
		if (p.kind == BoundaryKind.Struct) {
			for (const leaf of p.leaves) {
				if (leaf.kind == BoundaryKind.String) return true;
			}
		}
	}
	return false;
}

function hex2(b: int32): string {
	const digits = "0123456789abcdef";
	const high = b >> 4;
	const low = b & 15;
	return digits.slice(high, high + 1) + digits.slice(low, low + 1);
}

export function moduleKeyOf(modulePath: string, entryPath: string): string {
	const rel = relative(dirname(entryPath), modulePath);
	const dot = rel.lastIndexOf(".");
	const stem = dot > rel.lastIndexOf("/") ? rel.slice(0, dot) : rel;
	let key = "";
	for (let i = 0; i < stem.byteLength; i += 1) {
		const b = stem.byteAt(i);
		const alnum = (b >= 48 && b <= 57)
			|| (b >= 65 && b <= 90)
			|| (b >= 97 && b <= 122);
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

function peeled(t: Type): Type {
	return peelThrough(t, PEEL_ALIAS) ?? t;
}

function payloadOf(t: Type): Type {
	return isMaybeType(t) ? peeled(unwrapMaybeType(t)) : t;
}

function describe(t: Type): string {
	if (isMaybeType(t)) {
		return typeDisplayNameUnprofiled(payloadOf(t)) + " | null";
	}
	return typeDisplayNameUnprofiled(t);
}

function isVoidType(t: Type | null): boolean {
	if (t == null) return true;
	const p = peeled(t);
	return p.kind == TypeKind.Void || p.kind == TypeKind.None;
}

function refuseAt(c: Collector, code: string, message: string): void {
	c.errors.push({
		file: c.modulePath,
		code,
		message,
		line: c.at.line,
		column: c.at.column,
		endLine: c.at.endLine,
		endColumn: c.at.endColumn,
	});
}

function cannotCross(c: Collector, code: string, detail: string): void {
	const subject = `'${c.fnName}' in '${c.modulePath}'`;
	refuseAt(c, code, `${subject} cannot cross the JS/wasm boundary: ${detail}`);
}

function refuse(
	c: Collector,
	code: string,
	what: string,
	t: Type,
	why: string,
): void {
	cannotCross(c, code, `${what} has type '${describe(t)}', ${why}`);
}

export function isHandleType(t: Type): boolean {
	return getBuiltinKind(t) == BuiltinKind.FfiHandle;
}

export function handleTarget(t: Type): Type | null {
	if (t.kind != TypeKind.GenericInstance || t.typeChildren.length != 1) {
		return null;
	}
	const arg = peeled(t.typeChildren[0]);
	return arg.kind == TypeKind.Ref && arg.typeReturn != null
		? peeled(arg.typeReturn!)
		: arg;
}

function isNominalTarget(target: Type): boolean {
	return target.sym != null
		&& (target.sym!.symbolKind == SymbolKind.Class
			|| target.sym!.symbolKind == SymbolKind.Struct);
}

export function vecBoxElement(target: Type): BoundaryKind | null {
	if (getBuiltinKind(target) != BuiltinKind.FfiVecBox) return null;
	if (target.typeChildren.length != 1) return null;
	const k = scalarKind(peeled(target.typeChildren[0]));
	return k == BoundaryKind.Bool ? null : k;
}

function isVecBox(target: Type): boolean {
	return getBuiltinKind(target) == BuiltinKind.FfiVecBox;
}

function isExportedTarget(c: Collector, target: Type): boolean {
	if (target.sym == null) return false;
	for (const e of c.exports) {
		if (e.sym == target.sym) return true;
	}
	return false;
}

function handleRefusal(
	c: Collector,
	code: string,
	what: string,
	text: string,
): null {
	cannotCross(c, code, `${what}: ${text}`);
	return null;
}

function checkHandle(
	c: Collector,
	what: string,
	t: Type,
	nullable: boolean,
): string | null {
	if (nullable) {
		handleRefusal(c, "handle-null", what, "nullable Handle<T> is not supported");
		return null;
	}
	const target = handleTarget(t);
	const box = target != null && isVecBox(target);
	const usable = target != null
		&& (box ? vecBoxElement(target) != null : isNominalTarget(target));
	if (target == null || !usable) {
		const shown = describe(t);
		const text = `${shown}: T must be an exported class or struct, `
			+ "as in Handle<Counter>";
		handleRefusal(c, "handle-target", what, text);
		return null;
	}
	const name = describe(target);
	if (!box && !isExportedTarget(c, target)) {
		const text = `Handle<${name}>: ${name} must be exported to cross`;
		handleRefusal(c, "handle-unexported", what, text);
		return null;
	}
	const sym = box ? target.typeExtra!.sym! : target.sym!;
	if (!c.handles.includes(sym)) c.handles.push(sym);
	return name;
}

function handleElementOf(t: Type): BoundaryKind {
	return vecBoxElement(handleTarget(t)!) ?? BoundaryKind.Void;
}

function callbackParamKind(pt: Type): BoundaryKind | null {
	if (isMaybeType(pt)) return null;
	return pt.kind == TypeKind.String ? BoundaryKind.String : scalarKind(pt);
}

function callbackParamMode(k: BoundaryKind, pt: Type): BoundaryMode {
	if (k != BoundaryKind.Span) return BoundaryMode.Copied;
	return isReadonlyView(pt) ? BoundaryMode.Borrowed : BoundaryMode.Shared;
}

function callbackOf(
	c: Collector,
	what: string,
	t: Type,
): BoundaryCallback | null {
	let ok = true;
	const params: BoundaryKind[] = [];
	const nullables: boolean[] = [];
	const elements: BoundaryKind[] = [];
	const modes: BoundaryMode[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const declared = peeled(t.typeChildren[i]);
		const nullable = isMaybeType(declared);
		const pt = payloadOf(declared);
		let k = callbackParamKind(pt);
		let element = BoundaryKind.Void;
		if (!nullable && pt.kind == TypeKind.Span && pt.typeReturn != null) {
			const et = peeled(pt.typeReturn!);
			const ek = isMaybeType(et) ? null : scalarKind(et);
			if (ek != null) {
				k = BoundaryKind.Span;
				element = ek;
			}
		}
		if (k == null && isHandleType(pt)) {
			handleRefusal(
				c,
				"handle-callback",
				`parameter ${i + 1} of ${what}`,
				"Handle<T> as a callback parameter or result is not supported",
			);
			ok = false;
		} else if (k == null) {
			refuse(
				c,
				"callback-param",
				`parameter ${i + 1} of ${what}`,
				declared,
				"and a callback crossing the boundary takes only bool, integer, "
					+ "float and string parameters, each also nullable, and "
					+ "Span-of-number parameters",
			);
			ok = false;
		} else {
			params.push(k);
			nullables.push(nullable);
			elements.push(element);
			modes.push(callbackParamMode(k, pt));
		}
	}
	let result = BoundaryKind.Void;
	if (!isVoidType(t.typeReturn)) {
		const rt = peeled(t.typeReturn!);
		const k = isMaybeType(rt) ? null : scalarKind(rt);
		if (k == null && isHandleType(rt)) {
			handleRefusal(
				c,
				"handle-callback",
				`the result of ${what}`,
				"Handle<T> as a callback parameter or result is not supported",
			);
			ok = false;
		} else if (k == null) {
			refuse(
				c,
				"callback-result",
				`the result of ${what}`,
				rt,
				"and a callback crossing the boundary returns only void, bool, "
					+ "integer and float, never a nullable value",
			);
			ok = false;
		} else {
			result = k;
		}
	}
	if (!ok) return null;
	let letters = "";
	for (let i = 0; i < params.length; i += 1) {
		letters += (nullables[i] ? "i" : "") + signatureLetter(params[i]);
	}
	const signature = signatureLetter(result) + "_" + letters;
	return { params, nullables, elements, modes, result, signature };
}

export function leafLiteral(
	leaves: BoundaryLeaf[],
	values: string[],
	depth: int32,
): string {
	const parts: string[] = [];
	let i = 0;
	while (i < leaves.length) {
		const key = leaves[i].path[depth];
		let j = i;
		while (j < leaves.length && leaves[j].path[depth] == key) j += 1;
		const leaf = leaves[i].path.length == depth + 1;
		const value = leaf
			? values[i]
			: leafLiteral(leaves.slice(i, j), values.slice(i, j), depth + 1);
		parts.push(`${key}: ${value}`);
		i = j;
	}
	return parts.length == 0 ? "{}" : `{ ${parts.join(", ")} }`;
}

interface ValueShape {
	kind: BoundaryKind;
	nullable: boolean;
	leaves: BoundaryLeaf[];
	element: BoundaryKind;
	handle: string | null;
}

function declaresHook(t: Type): boolean {
	for (const name of LIFECYCLE_HOOK_NAMES) {
		const op = lifecycleHookOp(name);
		if (getAttachedOp(t, op) != null || lookupInstanceHook(t, op) != null) {
			return true;
		}
	}
	return false;
}

function structLeaves(
	c: Collector,
	what: string,
	t: Type,
	path: string[],
	out: BoundaryLeaf[],
): boolean {
	if (declaresHook(t)) {
		refuse(
			c,
			"struct-hook",
			what,
			t,
			"which declares a lifecycle hook, and a copy made field by field "
				+ `would skip it; ${describe(t)} has no JS/wasm boundary form: `
				+ `it crosses as Handle<${describe(t)}>`,
		);
		return false;
	}
	let ok = true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const fieldPath = path.concat([t.typeNames[i]]);
		const declared = peeled(t.typeChildren[i]);
		const nullable = isMaybeType(declared);
		const ft = payloadOf(declared);
		const fieldWhat = `field '${fieldPath.join(".")}' of ${what}`;
		const scalar = isMaybeType(ft) ? null : scalarKind(ft);
		if (scalar != null) {
			out.push({ path: fieldPath, kind: scalar, nullable });
		} else if (ft.kind == TypeKind.String) {
			out.push({ path: fieldPath, kind: BoundaryKind.String, nullable });
		} else if (!nullable && isStructType(ft) && !isMaybeType(ft)) {
			ok = structLeaves(c, fieldWhat, ft, fieldPath, out) && ok;
		} else {
			const why = structFieldWhy(ft, nullable);
			refuse(c, "struct-field", fieldWhat, declared, why);
			ok = false;
		}
	}
	return ok;
}

function structFieldWhy(ft: Type, nullable: boolean): string {
	if (nullable && isStructType(ft)) {
		return "and a nullable struct field is not supported: give the nested "
			+ "struct's own fields a null each";
	}
	return noFormWhy(ft, NoFormAt.Field)
		?? "and a struct crosses the boundary as a copy of its bool, integer, "
			+ "float and string fields, each also nullable, and of its struct fields";
}

enum NoFormAt {
	Param,
	Result,
	Field,
}

function byPosition(
	at: NoFormAt,
	param: string,
	result: string,
	field: string,
): string {
	if (at == NoFormAt.Param) return param;
	return at == NoFormAt.Result ? result : field;
}

function isClassRef(t: Type): boolean {
	if (isAtomicRef(t) || isLockedRef(t)) return false;
	const target = t.kind == TypeKind.Ref && t.typeReturn != null
		? peeled(t.typeReturn!)
		: t;
	return runtimeClassSym(target) != null;
}

function classTargetOf(t: Type): Type {
	return t.kind == TypeKind.Ref && t.typeReturn != null
		? peeled(t.typeReturn!)
		: t;
}

function classWhy(at: NoFormAt, nullable: boolean, t: Type): string {
	const identity = `and a ${nullable ? "nullable " : ""}class instance has an `
		+ "identity on one heap and does not cross as a copy: ";
	const later = `; ${describe(classTargetOf(t))} has no JS/wasm boundary form: `
		+ `it crosses as Handle<${describe(classTargetOf(t))}>`;
	return identity + byPosition(
		at,
		"pass the values it holds as parameters or as a struct, which crosses "
			+ "as a copy",
		"return the values it holds as a struct, which crosses as a copy",
		"copy the values it holds into fields of the struct",
	) + later;
}

function functionWhy(at: NoFormAt): string | null {
	const only = "and a function crosses the boundary only as a parameter, "
		+ "borrowed for the call, so it cannot be ";
	if (at == NoFormAt.Result) {
		return only + "a result: return the value it computes";
	}
	if (at == NoFormAt.Field) {
		return only + "a struct field: pass it as a separate parameter";
	}
	return null;
}

function enumWhy(t: Type, at: NoFormAt): string {
	const crossing = byPosition(
		at,
		"passing 'x as int32'",
		"returning 'x as int32'",
		"declaring the field as int32 and writing 'x as int32'",
	);
	const base = describe(literalBase(t));
	return "and an enum has no boundary form yet: cross its integer instead, "
		+ `${crossing}, and converting back with 'n as ${base}', `
		+ "which checks the range";
}

function unionWhy(t: Type, at: NoFormAt): string | null {
	const held = unwrapRefNullUnion(t);
	if (held != null) return isClassRef(held) ? classWhy(at, true, held) : null;
	const variants = "and a union has no single boundary form: ";
	return variants + byPosition(
		at,
		"pass a tag integer and the payload as separate parameters, or give "
			+ "each variant its own @wasm function",
		"return a struct with a tag integer and one field per variant, or give "
			+ "each variant its own @wasm function",
		"flatten it into a tag integer field and one field per variant",
	);
}

function collectionWhy(at: NoFormAt): string {
	const table = "and a Map or Set is a hash table that lives on one heap and ";
	const noStringKeys = "(string keys have no Vec form yet)";
	return table + byPosition(
		at,
		"does not cross: pass its keys and values as separate Vec parameters of "
			+ `numbers and rebuild it on the other side ${noStringKeys}`,
		"does not cross: return a Vec of numbers and rebuild it on the other "
			+ "side, a Map's keys from one @wasm function and its values from "
			+ `another ${noStringKeys}`,
		"cannot be a struct field: pass its keys and values as separate Vec "
			+ `parameters of numbers instead ${noStringKeys}`,
	);
}

function arrayWhy(at: NoFormAt): string {
	const array = "and an array reference lives on one heap and does not cross";
	return byPosition(
		at,
		`${array}: use a Vec of bool, integer or float elements, which crosses `
			+ "as a copy",
		`${array}: return a Vec of bool, integer or float elements, which `
			+ "crosses as a copy",
		`${array}, and a struct holds no Vec: pass the elements as a separate `
			+ "Vec parameter",
	);
}

function noFormWhy(t: Type, at: NoFormAt): string | null {
	if (isMaybeType(t)) return null;
	if (t.kind == TypeKind.Function) return functionWhy(at);
	if (t.kind == TypeKind.Enum || t.kind == TypeKind.EnumLiteral) {
		return enumWhy(t, at);
	}
	if (t.kind == TypeKind.Union) return unionWhy(t, at);
	if (isStdCollection(t)) return collectionWhy(at);
	if (
		t.kind == TypeKind.Ref
		&& t.typeReturn != null
		&& peeled(t.typeReturn!).kind == TypeKind.Array
	) {
		return arrayWhy(at);
	}
	return isClassRef(t) ? classWhy(at, false, t) : null;
}

function valueShape(
	c: Collector,
	what: string,
	t: Type,
	nullable: boolean,
): ValueShape | null {
	if (isMaybeType(t)) {
		refuse(
			c,
			"nullable-nested",
			what,
			t,
			"and a nullable of a nullable has no boundary form: write one | null",
		);
		return null;
	}
	if (isStructType(t)) {
		const leaves: BoundaryLeaf[] = [];
		if (!structLeaves(c, what, t, [], leaves)) return null;
		const element = BoundaryKind.Void;
		const handle = null;
		return { kind: BoundaryKind.Struct, nullable, leaves, element, handle };
	}
	if (t.kind == TypeKind.Array && t.typeReturn != null) {
		const et = peeled(t.typeReturn!);
		const element = isMaybeType(et) ? null : scalarKind(et);
		if (element == null) {
			refuse(
				c,
				"vec-element",
				what,
				t,
				"and a Vec crosses the boundary as a copy of bool, integer or float "
					+ "elements",
			);
			return null;
		}
		const handle = null;
		return { kind: BoundaryKind.Vec, nullable, leaves: [], element, handle };
	}
	return null;
}

function handleLabel(c: Collector, target: string, at: SourceLocation): string {
	const file = relative(dirname(c.entryPath), c.modulePath);
	return `Handle<${target}> created at ${file}:${at.line}`;
}

function plainParam(
	name: string,
	kind: BoundaryKind,
	nullable: boolean,
	mode: BoundaryMode,
): BoundaryParam {
	const element = BoundaryKind.Void;
	return {
		name,
		kind,
		nullable,
		mode,
		callback: null,
		leaves: [],
		element,
		handle: null,
	};
}

function paramOf(
	c: Collector,
	name: string,
	type: Type,
): BoundaryParam | null {
	const declared = peeled(type);
	const nullable = isMaybeType(declared);
	const t = payloadOf(declared);
	const what = `parameter '${name}'`;
	const scalar = scalarKind(t);
	if (scalar != null) {
		return plainParam(name, scalar, nullable, BoundaryMode.Copied);
	}
	if (t.kind == TypeKind.String) {
		return plainParam(name, BoundaryKind.String, nullable, BoundaryMode.Copied);
	}
	if (t.kind == TypeKind.Function) {
		if (nullable) {
			refuse(
				c,
				"callback-null",
				what,
				declared,
				"and a callback crossing the boundary cannot be null: pass a function",
			);
			return null;
		}
		const cb = callbackOf(c, what, t);
		if (cb == null) return null;
		const param = plainParam(
			name,
			BoundaryKind.Callback,
			false,
			BoundaryMode.Borrowed,
		);
		param.callback = cb;
		return param;
	}
	if (t.kind == TypeKind.Span && t.typeReturn != null) {
		if (nullable) {
			refuse(
				c,
				"span-null",
				what,
				declared,
				"and a Span crosses the boundary only as a plain parameter, so pass "
					+ "a Span or a Vec",
			);
			return null;
		}
		const et = peeled(t.typeReturn!);
		const element = isMaybeType(et) ? null : scalarKind(et);
		if (element == null) {
			refuse(
				c,
				"span-element",
				what,
				t,
				"and a Span crosses the boundary for the call over bool, integer or "
					+ "float elements",
			);
			return null;
		}
		const mode = isReadonlyView(t)
			? BoundaryMode.Borrowed
			: BoundaryMode.Shared;
		const param = plainParam(name, BoundaryKind.Span, false, mode);
		param.element = element;
		return param;
	}
	if (isHandleType(t)) {
		const target = checkHandle(c, what, t, nullable);
		if (target == null) return null;
		const kind = BoundaryKind.Handle;
		const param = plainParam(name, kind, false, BoundaryMode.Borrowed);
		param.handle = target;
		param.element = handleElementOf(t);
		return param;
	}
	const errorsBefore = c.errors.length;
	const shape = valueShape(c, what, t, nullable);
	if (shape != null) {
		const param = plainParam(name, shape.kind, nullable, BoundaryMode.Copied);
		param.leaves = shape.leaves;
		param.element = shape.element;
		return param;
	}
	if (c.errors.length == errorsBefore) {
		const why = noFormWhy(t, NoFormAt.Param)
			?? "which has no JS/wasm boundary form: use bool, integers, floats, "
				+ "string, a struct of those, a Vec of numbers (each also nullable), "
				+ "a Span of numbers or a callback";
		refuse(c, "no-form", what, declared, why);
	}
	return null;
}

function plainShape(kind: BoundaryKind, nullable: boolean): ValueShape {
	const element = BoundaryKind.Void;
	return { kind, nullable, leaves: [], element, handle: null };
}

function resultOf(c: Collector, type: Type | null): ValueShape | null {
	if (isVoidType(type)) return plainShape(BoundaryKind.Void, false);
	const declared = peeled(type!);
	const nullable = isMaybeType(declared);
	const t = payloadOf(declared);
	const scalar = scalarKind(t);
	if (scalar != null) return plainShape(scalar, nullable);
	if (t.kind == TypeKind.String) {
		return plainShape(BoundaryKind.String, nullable);
	}
	if (t.kind == TypeKind.Span) {
		refuse(
			c,
			"span-result",
			"the result",
			declared,
			"and a Span borrows its memory only for the call, so it cannot outlive "
				+ "it: return a Vec",
		);
		return null;
	}
	if (isHandleType(t)) {
		const target = checkHandle(c, "the result", t, nullable);
		if (target == null) return null;
		const shape = plainShape(BoundaryKind.Handle, false);
		shape.handle = target;
		shape.element = handleElementOf(t);
		return shape;
	}
	const errorsBefore = c.errors.length;
	const shape = valueShape(c, "the result", t, nullable);
	if (shape != null) return shape;
	if (c.errors.length == errorsBefore) {
		const why = noFormWhy(t, NoFormAt.Result)
			?? "which has no JS/wasm boundary form: return void, bool, an integer, "
				+ "a float, a string, a struct of those or a Vec of numbers, each "
				+ "also nullable";
		refuse(c, "no-form", "the result", declared, why);
	}
	return null;
}

function crossesAsPointerAndLength(kind: BoundaryKind): boolean {
	return kind == BoundaryKind.String
		|| kind == BoundaryKind.Vec
		|| kind == BoundaryKind.Span;
}

function wireNamesOf(p: BoundaryParam): string[] {
	const names: string[] = [];
	if (p.nullable) names.push(p.name + "Some");
	if (crossesAsPointerAndLength(p.kind)) {
		names.push(p.name + "Ptr");
		names.push(p.name + "Len");
	} else if (p.kind == BoundaryKind.Struct) {
		for (let j = 0; j < p.leaves.length; j += 1) {
			const leaf = `${p.name}_${j}`;
			if (p.leaves[j].nullable) names.push(leaf + "Some");
			if (p.leaves[j].kind == BoundaryKind.String) {
				names.push(leaf + "Ptr");
				names.push(leaf + "Len");
			} else {
				names.push(leaf);
			}
		}
	} else {
		names.push(p.name);
	}
	return names;
}

function fnDeclOf(sym: Symbol): Node | null {
	const decl = sym.declNode;
	return decl != null && decl.kind == NodeKind.FunctionDecl ? decl : null;
}

function fnFlagsOf(sym: Symbol): string {
	const decl = fnDeclOf(sym);
	return decl != null ? (decl.data as FunctionDeclData).fnFlags : "";
}

function nameAtOf(sym: Symbol): SourceLocation {
	const decl = fnDeclOf(sym);
	return decl != null
		? (decl.data as FunctionDeclData).nameLocation
		: sym.location;
}

function wireNameClash(params: BoundaryParam[]): string | null {
	const wires: string[] = [];
	for (const p of params) {
		for (const w of wireNamesOf(p)) {
			if (wires.includes(w)) return w;
			wires.push(w);
		}
	}
	return null;
}

function hasKind(params: BoundaryParam[], kind: BoundaryKind): boolean {
	for (const p of params) {
		if (p.kind == kind) return true;
	}
	return false;
}

function boundaryFunction(
	c: Collector,
	key: string,
	name: string,
	sym: Symbol,
	overloadIndex: int32,
	inSet: boolean,
): BoundaryFunction | null {
	c.fnName = name;
	const decl = fnDeclOf(sym);
	const nameAt = nameAtOf(sym);
	c.at = nameAt;
	const flags = fnFlagsOf(sym);
	if (isGenericFn(flags) || hasGenericParams(sym.symbolType)) {
		cannotCross(
			c,
			"generic",
			"it is generic, and a boundary function has one concrete signature; "
				+ "export a non-generic wrapper",
		);
		return null;
	}
	if (isExtensionRoutine(flags)) {
		cannotCross(
			c,
			"extension-routine",
			"it is an extension routine; export a plain function that takes the "
				+ "receiver as a parameter",
		);
		return null;
	}
	const ft = peeled(sym.symbolType);
	const typeExprs = decl != null ? decl.typeExprs : null;
	if (typeExprs != null && typeExprs.length != ft.typeChildren.length) {
		throw new Error(
			`internal: '${name}' in '${c.modulePath}' has `
				+ `${ft.typeChildren.length} parameter types but `
				+ `${typeExprs.length} parameter annotations`,
		);
	}
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
	const clash = wireNameClash(params);
	if (clash != null) {
		c.at = nameAt;
		cannotCross(
			c,
			"wire-name-clash",
			`two parameters would become the wasm parameter '${clash}' (a string, `
				+ "Vec or Span adds Ptr and Len, a nullable adds Some); rename one of "
				+ "them",
		);
		return null;
	}
	if (hasKind(params, BoundaryKind.Span) && hasKind(params, BoundaryKind.Callback)) {
		c.at = nameAt;
		cannotCross(
			c,
			"span-and-callback",
			"it takes both a Span and a callback, and the callback runs JS while "
				+ "the Span's copy is live, so a write on either side would be lost; "
				+ "pass a Vec, which is copied for the call, or take the callback in "
				+ "a second function",
		);
		return null;
	}
	const exportSymbol = inSet
		? `msb_${key}_${name}_u${overloadIndex}`
		: `msb_${key}_${name}`;
	return {
		modulePath: c.modulePath,
		moduleKey: key,
		name,
		overloadIndex,
		exportSymbol,
		params,
		result: result.kind,
		resultNullable: result.nullable,
		resultLeaves: result.leaves,
		resultElement: result.element,
		resultHandle: result.handle,
		resultLabel: result.handle == null
			? ""
			: handleLabel(c, result.handle!, nameAt),
	};
}

function kindList(kinds: BoundaryKind[]): string {
	let s = "";
	for (const k of kinds) s += k.toString() + ",";
	return s;
}

function paramShape(p: BoundaryParam): string {
	const nullable = p.nullable ? "?" : "";
	let s = `${p.kind.toString()}${nullable}/${p.element.toString()}`;
	for (const leaf of p.leaves) {
		const leafNullable = leaf.nullable ? "?" : "";
		s += `/${leaf.path.join(".")}:${leaf.kind.toString()}${leafNullable}`;
	}
	if (p.callback != null) {
		const cb = p.callback!;
		s += `/(${kindList(cb.params)})(${kindList(cb.elements)})`
			+ cb.result.toString();
	}
	return s;
}

function callShape(f: BoundaryFunction): string {
	const parts: string[] = [];
	for (const p of f.params) parts.push(paramShape(p));
	return parts.join(";");
}

function setFunctions(
	c: Collector,
	key: string,
	name: string,
	sym: Symbol,
	locs: SourceLocation[],
): BoundaryFunction[] {
	c.fnName = name;
	const set: Symbol[] = [sym];
	for (const o of sym.overloads) set.push(o);
	let wasm = 0;
	for (const m of set) {
		if (hasFlag(m, SymbolFlag.OverloadSig)) {
			c.at = nameAtOf(m);
			cannotCross(
				c,
				"overload-signature",
				"it has overload signatures, which name no function of their own; "
					+ "export the implementation under its own name",
			);
			return [];
		}
		if (hasFlag(m, SymbolFlag.Wasm)) wasm += 1;
	}
	if (set.length > 1 && wasm != 0 && wasm != set.length) {
		c.at = nameAtOf(set[0]);
		cannotCross(
			c,
			"overload-partial",
			`@wasm is on ${wasm} of its ${set.length} overloads; place every `
				+ "overload in wasm or none, because the wasm side imports the whole "
				+ "set and picks by argument types",
		);
		return [];
	}
	const out: BoundaryFunction[] = [];
	const outAt: SourceLocation[] = [];
	for (let overloadIndex = 0; overloadIndex < set.length; overloadIndex += 1) {
		const overload = set[overloadIndex];
		const inSet = set.length > 1;
		const f = boundaryFunction(c, key, name, overload, overloadIndex, inSet);
		if (f == null) continue;
		out.push(f);
		outAt.push(nameAtOf(overload));
	}
	const shapes = out.map((f) => callShape(f));
	for (let i = 0; i < out.length; i += 1) {
		for (let j = 0; j < i; j += 1) {
			if (shapes[i] != shapes[j]) continue;
			c.at = outAt[i];
			cannotCross(
				c,
				"overload-same-shape",
				`overloads ${out[j].overloadIndex} and ${out[i].overloadIndex} take `
					+ "the same boundary types, so the wasm side cannot tell which one "
					+ "to call; make their parameters differ in count, scalar kind, "
					+ "element kind or struct fields",
			);
		}
	}
	for (const at of outAt) locs.push(at);
	return out;
}

export function manifestFor(
	modulePath: string,
	entryPath: string,
	exports: ExportedSymInfo[],
	placed: string[],
): Manifest {
	const key = moduleKeyOf(modulePath, entryPath);
	const at = makeLoc(0, 0);
	const c: Collector = {
		errors: [],
		fnName: "",
		modulePath,
		entryPath,
		at,
		exports,
		handles: [],
	};
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
			for (const f of setFunctions(c, key, e.name, e.sym, locs)) {
				functions.push(f);
			}
		}
		if (!found) {
			throw new Error(
				`internal: wasm-placed function '${name}' has no export in `
					+ `'${modulePath}'`,
			);
		}
	}
	for (let i = 0; i < functions.length; i += 1) {
		for (let j = 0; j < i; j += 1) {
			if (functions[i].exportSymbol != functions[j].exportSymbol) continue;
			c.at = locs[i];
			refuseAt(
				c,
				"export-collision",
				`'${functions[i].name}' and '${functions[j].name}' in `
					+ `'${modulePath}' would both export the wasm symbol `
					+ `'${functions[i].exportSymbol}': rename one of them`,
			);
		}
	}
	return { functions, errors: c.errors, handles: c.handles };
}
