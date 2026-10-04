// MetaScript CBOR — Public API hub
//
// Re-exports the public surface from internal modules and provides Buffer-
// based entry points for end users. Internal encoder/decoder operate on
// `uint8[]`; this layer routes Buffer payloads through that internal
// representation.

import { Buffer } from "std/core/buffer";

// Re-exports
export { CborKind, CborValue, cborToString, cborToNumber, cborToBoolean, cborToInt32, cborToInt64 } from "./types";
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
export { cborValueOf, cborEncode, _cborArrayOfInts, _cborArrayOfEnums, _cborArrayOfStructs } from "./encode";
export { cborValueToStruct, _cborToEnumArray, _cborToIntArray, _cborToStructArray } from "./decode";

import { CborValue } from "./types";
import { decodeAll } from "./decoder";
import { UntypedTree } from "../contracts";

// --- Public decode entry ---
//
// Parses a Buffer as a single CBOR data item, returns Result<CborValue, error>.
// Uses byte-by-byte access via byteAt (Buffer = string alias) to avoid pulling
// extension-method paths through the test-harness loader.

export function decode(buf: Buffer): Result<CborValue, string> {
	const len = buf.byteLength();
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

export const cborUntyped: UntypedTree<CborValue, Buffer> = {
	parseValue: decode,
};
