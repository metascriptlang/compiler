// MetaScript CBOR — Type Definitions (RFC 8949)
//
// CborValue is a discriminated union over CBOR wire-level data items.
//
// CBOR major types from RFC 8949 §3.1:
//   0  unsigned integer  (0 .. 2^64-1)         → Int variant (sign indicates wire major)
//   1  negative integer  (-2^64 .. -1)         → Int variant
//   2  byte string                              → Bytes
//   3  text string (UTF-8)                      → Text
//   4  array of items                           → Array
//   5  map of key/value pairs                   → Map (keys can be any CborValue)
//   6  semantic tag + tagged item               → Tag
//   7  floats / simple values                   → Bool / Null / Undefined / Float / Simple
//
// V1 design choices:
//   - Major 0 + Major 1 collapse into Int (signed int64). Encode infers wire major
//     from sign: val >= 0 → major 0, val < 0 → major 1 with arg = -1 - val.
//     Round-trip preserves identity for all values fitting in int64
//     (range -2^63 .. 2^63 - 1). Values > 2^63 - 1 unsigned are NOT supported V1.
//   - Float stored as float64 regardless of wire size (half/single/double).
//     Encode always emits double. Round-trip upgrades precision but preserves value.
//   - Map keys allow any CborValue per spec. Text-keyed accessors live in accessors.ms.
//   - Indefinite-length encoding NOT supported V1 (deferred to V2).

import { Buffer } from "std/core/buffer";

export enum CborKind {
	Int,        // major 0 / 1 (collapsed by sign)
	Bytes,      // major 2
	Text,       // major 3
	Array,      // major 4
	Map,        // major 5
	Tag,        // major 6
	Bool,       // major 7, simple 20/21
	Null,       // major 7, simple 22
	Undefined,  // major 7, simple 23
	Float,      // major 7, additional 25/26/27
	Simple,     // major 7, other simple values (0..19, 24..31 reserved)
}

export type CborValueData = match (kind: CborKind) {
	CborKind.Int       => { intVal: int64 },
	CborKind.Bytes     => { bytesVal: Buffer },
	CborKind.Text      => { textVal: string },
	CborKind.Array     => { items: CborValue[] },
	CborKind.Map       => { keys: CborValue[], values: CborValue[] },
	CborKind.Tag       => { tagNum: int64, tagged: CborValue },
	CborKind.Bool      => { boolVal: boolean },
	CborKind.Null      => {},
	CborKind.Undefined => {},
	CborKind.Float     => { floatVal: float64 },
	CborKind.Simple    => { simpleVal: number },
};

export type CborValue = Ref<CborValueData>;

// ===== Type accessors =====

export function asString(this v: CborValue, def: string = ""): string {
	if (v != null && v.kind == CborKind.Text) return v.textVal;
	return def;
}

// CBOR's Int variant covers both major 0 (unsigned) and major 1 (negative)
// — wire type "integer". Float is a distinct variant. asNumber accepts
// both Int and Float; asInt* accepts only Int (numeric truncation of float
// is lossy and the user almost never wants it implicitly).
export function asNumber(this v: CborValue, def: number = 0): number {
	if (v == null) return def;
	return match (v.kind) {
		CborKind.Int   => v.intVal as number,
		CborKind.Float => v.floatVal,
		_ => def,
	};
}

export function asBoolean(this v: CborValue, def: boolean = false): boolean {
	if (v != null && v.kind == CborKind.Bool) return v.boolVal;
	return def;
}

export function asInt32(this v: CborValue, def: int32 = 0): int32 {
	if (v != null && v.kind == CborKind.Int) return v.intVal as int32;
	return def;
}

export function asInt64(this v: CborValue, def: int64 = 0 as int64): int64 {
	if (v != null && v.kind == CborKind.Int) return v.intVal;
	return def;
}

// ===== Converters =====

export converter cborToString(v: CborValue): string { return v.asString(); }
export converter cborToNumber(v: CborValue): number { return v.asNumber(); }
export converter cborToBoolean(v: CborValue): boolean { return v.asBoolean(); }
export converter cborToInt32(v: CborValue): int32 { return v.asInt32(); }
export converter cborToInt64(v: CborValue): int64 { return v.asInt64(); }

// ===== Tests =====

test "CborKind enum values are stable" {
	// Stable ordering is part of the API: external consumers may rely on
	// numeric values for serialization/deserialization. Locking these in.
	assert CborKind.Int       == 0;
	assert CborKind.Bytes     == 1;
	assert CborKind.Text      == 2;
	assert CborKind.Array     == 3;
	assert CborKind.Map       == 4;
	assert CborKind.Tag       == 5;
	assert CborKind.Bool      == 6;
	assert CborKind.Null      == 7;
	assert CborKind.Undefined == 8;
	assert CborKind.Float     == 9;
	assert CborKind.Simple    == 10;
}
