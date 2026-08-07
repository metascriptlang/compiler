// JSON Prelude — auto-loaded ECMAScript-style facade.
// All codec infrastructure lives in std/serialize/json/. This file is the
// user-facing surface (re-exports + JSON class) so existing JSON.parse<T> /
// JSON.stringify<T> patterns work without explicit imports.

export { JsonKind, JsonValue, JsonValueData } from "std/serialize/json/types";
export {
	jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonInt,
	jsonArrayOfStrings, jsonArrayOfBooleans, jsonArrayOfNumbers, jsonArrayOfFloat32,
	jsonArrayOfInt8, jsonArrayOfInt16, jsonArrayOfInt32, jsonArrayOfInt64,
	jsonArrayOfUint8, jsonArrayOfUint16, jsonArrayOfUint32,
} from "std/serialize/json/builder";
export { stringify, stringifyPretty } from "std/serialize/json/stringify";
export { parseJson } from "std/serialize/json/parser";
export {
	asString, asNumber, asBoolean, asInt32, asInt64, at, length, getDynamicField, setDynamicField,
	jsonToStringArray, jsonToBooleanArray, jsonToNumberArray, jsonToFloat32Array,
	jsonToInt8Array, jsonToInt16Array, jsonToInt32Array, jsonToInt64Array,
	jsonToUint8Array, jsonToUint16Array, jsonToUint32Array,
	jsonToStringArrayE, jsonToBooleanArrayE, jsonToNumberArrayE, jsonToFloat32ArrayE,
	jsonToInt8ArrayE, jsonToInt16ArrayE, jsonToInt32ArrayE, jsonToInt64ArrayE,
	jsonToUint8ArrayE, jsonToUint16ArrayE, jsonToUint32ArrayE,
	kindName, reqString, reqBoolean, reqNumber, reqInt64, reqArray, reqObject, joinDecodeErrors,
	_jsonCheckDiscStr, _jsonIsNull,
} from "std/serialize/json/accessors";

// Macro system constraint: when macro X's expansion result contains a call
// to macro Y, the importing module must also have Y in its macroBodyRegistry
// — recursive expansion looks up each name in the LOCAL registry, not the
// defining module's. Here `jsonStringify` body emits `jsonValueOf(...)`
// calls, so we must import `jsonValueOf` even though we never call it
// directly. Same for the other two macros.
import { jsonStringify, jsonValueOf, jsonValueToStruct, jsonValueToStructE } from "std/serialize/json";

function _jsonStringifyTyped<T>(value: T): string {
	return jsonStringify(value);
}

// Strict contract: the MS type is the contract. Syntax errors, a non-object
// top level, missing fields, and kind mismatches ALL surface as Result.err —
// never as fabricated defaults. Optional fields are spelled `T | null` in
// the interface, not by tolerating absence.
function _jsonParseTyped<T>(input: string): Result<T, string> {
	const pr = parseJson(input);
	if (!pr.ok) return Result.err(pr.error);
	const root: JsonValue = pr.value;
	if (root === null || root.kind !== JsonKind.Object) {
		const got = root === null ? "null" : kindName(root.kind);
		return Result.err("expected object at top level, got " + got);
	}
	const errs: string[] = [];
	const v: T = jsonValueToStructE(root, null as T | null, errs, "");
	if (errs.length > 0) return Result.err(joinDecodeErrors(errs));
	return Result.ok(v);
}

// ===== V2 — generic helpers for non-atomic-builtin element arrays =====
//
// `_jsonArrayOfInts<T>` covers enum + type-alias element arrays (T must be
// castable to int64). `_jsonArrayOfStructs<T>` covers struct/interface
// element arrays — body calls `jsonValueOf(arr[i])` recursively, which
// re-expands at monomorphization time when T is concrete.
//
// While-loop deliberate: for..of in macro-target prelude helpers triggers a
// DCE bug (helpers get pruned from link). See memory
// project_serialize_v15_array_support.
//
// `_jsonToIntArray<T>` / `_jsonToStructArray<T>` are the decode-side mirrors
// (used by jsonValueToStruct macro).

export function _jsonArrayOfInts<T>(arr: T[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) {
		items.push(jsonInt(arr[i] as int64));
		i = i + 1;
	}
	return jsonArray(items);
}

export function _jsonArrayOfStructs<T>(arr: T[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) {
		items.push(jsonValueOf(arr[i]));
		i = i + 1;
	}
	return jsonArray(items);
}

export function _jsonToIntArray<T>(jv: JsonValue, witness: T | null): T[] {
	const out: T[] = [];
	if (jv === null || jv.kind !== JsonKind.Array) return out;
	let i = 0;
	while (i < jv.items.length) {
		out.push(asInt64(jv.items[i]) as T);
		i = i + 1;
	}
	return out;
}

// Strict mirror for enum / primitive-alias element arrays: the element must
// carry the Int variant, exactly as a declared int64 field must.
export function _jsonToIntArrayE<T>(jv: JsonValue, witness: T | null, errs: string[], arrPath: string): T[] {
	const out: T[] = [];
	if (jv === null || jv.kind !== JsonKind.Array) return out;
	let i = 0;
	while (i < jv.items.length) {
		out.push(reqInt64(jv.items[i], arrPath + "[" + i.toString() + "]", "", errs) as T);
		i = i + 1;
	}
	return out;
}

// Witness via T[] — needed for value-type T (enum, primitive alias) where
// `T | null` would canonicalize to Maybe<T> and fail to match the helper's
// `T | null` arg type. Caller passes `[] as <Elem>[]` and T binds from
// the element type.
export function _jsonToIntArrayWitness<T>(jv: JsonValue, witness: T[]): T[] {
	const out: T[] = [];
	if (jv === null || jv.kind !== JsonKind.Array) return out;
	let i = 0;
	while (i < jv.items.length) {
		out.push(asInt64(jv.items[i]) as T);
		i = i + 1;
	}
	return out;
}

export function _jsonToStructArray<T>(jv: JsonValue, witness: T | null): T[] {
	const out: T[] = [];
	if (jv === null || jv.kind !== JsonKind.Array) return out;
	let i = 0;
	while (i < jv.items.length) {
		out.push(jsonValueToStruct(jv.items[i], witness));
		i = i + 1;
	}
	return out;
}

// Strict mirror. `arrPath` is the dotted path of the ARRAY field itself, so
// element messages read `field 'items[0].qty': ...` and a non-object element
// reads `field 'items[0]': expected object, got int`.
export function _jsonToStructArrayE<T>(jv: JsonValue, witness: T | null, errs: string[], arrPath: string): T[] {
	const out: T[] = [];
	if (jv === null || jv.kind !== JsonKind.Array) return out;
	let i = 0;
	while (i < jv.items.length) {
		const elemPath: string = arrPath + "[" + i.toString() + "]";
		const el: JsonValue = reqObject(jv.items[i], elemPath, "", errs);
		out.push(jsonValueToStructE(el, witness, errs, elemPath + "."));
		i = i + 1;
	}
	return out;
}



export class JSON {
	static stringify<T>(value: T): string {
		return _jsonStringifyTyped<T>(value);
	}

	// Typed parse — `JSON.parse<Person>(s)` returns Result<Person, string>.
	// Macro-driven decode via `_jsonParseTyped`. T must be specified.
	static parse<T>(input: string): Result<T, string> {
		return _jsonParseTyped<T>(input);
	}

	// Untyped parse — `JSON.parseValue(s)` returns Result<JsonValue, string>.
	// Implementation of the SERIALIZE UntypedTree<JsonValue> capability
	// (see std/serialize/contracts.ms). Use when JSON shape is unknown
	// (e.g., third-party API responses); access fields via getDynamicField
	// protocol: `r.value.user.name.asString()`.
	static parseValue(input: string): Result<JsonValue, string> {
		return parseJson(input);
	}
}
