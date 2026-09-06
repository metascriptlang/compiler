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
