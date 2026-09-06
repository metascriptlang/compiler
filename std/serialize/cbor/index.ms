// MetaScript CBOR — Public API hub
//
// Re-exports the public surface from internal modules and provides Buffer-
// based entry points for end users. Internal encoder/decoder operate on
// `uint8[]`; this layer routes Buffer payloads through that internal
// representation.

import { Buffer } from "std/core/buffer";

// Re-exports
export { CborKind, CborValue } from "./types";
export {
	cborInt, cborBytes, cborText, cborArray, cborMap, cborTextMap,
	cborTag, cborBool, cborNull, cborUndefined, cborFloat, cborSimple,
	cborArrayOfStrings, cborArrayOfBooleans, cborArrayOfNumbers, cborArrayOfFloat32,
	cborArrayOfInt8, cborArrayOfInt16, cborArrayOfInt32, cborArrayOfInt64,
	cborArrayOfUint8, cborArrayOfUint16, cborArrayOfUint32,
} from "./builder";
export { CborWriter, newCborWriter, encode, encodeValue, encodeText, encodeInt } from "./encoder";
export { CborReader, decodeAll, decodeValue, newCborReader } from "./decoder";
export {
	asString, asNumber, asBoolean, asInt32, asInt64,
	at, length, getDynamicField, tagNumber, untag,
	cborToStringArray, cborToBooleanArray, cborToNumberArray, cborToFloat32Array,
	cborToInt8Array, cborToInt16Array, cborToInt32Array, cborToInt64Array,
	cborToUint8Array, cborToUint16Array, cborToUint32Array,
} from "./accessors";
export { cborValueOf, cborEncode } from "./encode";
export { cborValueToStruct } from "./decode";

// Local imports for the entry-point definitions below
import { CborValue, CborKind } from "./types";
import { newCborWriter, encodeValue } from "./encoder";
import { decodeAll } from "./decoder";
import { cborInt, cborArray } from "./builder";
import { asInt64 } from "./accessors";
import { cborValueOf } from "./encode";
import { cborValueToStruct } from "./decode";
import { UntypedTree } from "../contracts";

// ===== V2 — generic helpers for non-atomic-builtin element arrays =====
//
// Mirrors std/core/json/index.cms V2 helpers. CBOR isn't a prelude module,
// so user code must explicitly import these alongside cborValueOf /
// cborValueToStruct — same pattern as other CBOR builders/accessors.
//
// `_cborArrayOfInts<T>` — enum + type-alias element arrays (T castable to int64).
// `_cborArrayOfStructs<T>` — struct/interface element arrays; body recurses
// via cborValueOf(arr[i]), which re-expands at monomorphization time.
//
// `_cborToIntArray<T>` / `_cborToStructArray<T>` — decode-side mirrors,
// used by cborValueToStruct macro. Bare-null witness path relies on
// compiler Pass 3 contextual return-type binding (Nim parity, bug024).
//
// While-loop deliberate: for..of in macro-target helpers can trigger DCE
// pruning when callers are macro-emitted. See JSON V2 prior art.

export function _cborArrayOfInts<T>(arr: T[]): CborValue {
	const items: CborValue[] = [];
	let i = 0;
	while (i < arr.length) {
		items.push(cborInt(arr[i] as int64));
		i = i + 1;
	}
	return cborArray(items);
}

export function _cborArrayOfStructs<T>(arr: T[]): CborValue {
	const items: CborValue[] = [];
	let i = 0;
	while (i < arr.length) {
		items.push(cborValueOf(arr[i]));
		i = i + 1;
	}
	return cborArray(items);
}

export function _cborToIntArray<T>(cv: CborValue, witness: T | null): T[] {
	const out: T[] = [];
	if (cv == null || cv.kind != CborKind.Array) return out;
	let i = 0;
	while (i < cv.items.length) {
		out.push(asInt64(cv.items[i]) as T);
		i = i + 1;
	}
	return out;
}

export function _cborToStructArray<T>(cv: CborValue, witness: T | null): T[] {
	const out: T[] = [];
	if (cv == null || cv.kind != CborKind.Array) return out;
	let i = 0;
	while (i < cv.items.length) {
		out.push(cborValueToStruct(cv.items[i], witness));
		i = i + 1;
	}
	return out;
}

// encode moved to encoder.ms (bindSym target — importing it back here from
// encode.ms would cycle); re-exported above.

// --- Public decode entry ---
//
// Parses a Buffer as a single CBOR data item, returns Result<CborValue, error>.
// Uses byte-by-byte access via byteAt (Buffer = string alias) to avoid pulling
// extension-method paths through the test-harness loader.

export function decode(buf: Buffer): Result<CborValue, string> {
	const len = buf.byteLength;
	const bytes: uint8[] = [];
	let i = 0;
	while (i < len) {
		bytes.push((buf.byteAt(i) & 0xff) as uint8);
		i = i + 1;
	}
	return decodeAll(bytes);
}

// --- SERIALIZE Layer A capability instance ---
//
// Cross-format tools targeting `UntypedTree<V>` accept this for CBOR input
// (mirror of `jsonUntyped` in std/serialize/json/index.ms). The contract
// promises a `parseValue(buffer) → Result<V, string>` shape — for CBOR the
// input is a Buffer, so this wraps `decode()`.

export const cborUntyped: UntypedTree<CborValue> = {
	parseValue: decode,
};
