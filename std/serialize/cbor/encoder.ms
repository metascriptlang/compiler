// MetaScript CBOR — Encoder (RFC 8949 §3, §4)
//
// Walks a CborValue tree and produces the canonical wire byte sequence.
// Internal builder uses `number[]` (each element 0..255). Public API at
// index.ms wraps this builder and converts the byte array to a Buffer for
// the user.
//
// V1 scope:
//   - Major types 0, 1, 2, 3, 4, 5, 6 fully supported
//   - Major 7: Bool, Null, Undefined, Simple — supported
//   - Major 7: Float (half/single/double) — DEFERRED to Phase 1.3
//   - Indefinite-length encoding NOT supported (RFC 8949 §3.2)
//   - Integer arguments up to 2^53 (JS safe integer) reliably; up to 2^63-1
//     via int64 division split. Values > 2^63-1 unsigned are NOT supported.
//
// Endianness: CBOR is big-endian. All multi-byte arguments emit MSB first.

import { CborKind, CborValue } from "./types";
import { Buffer } from "std/core/buffer";

// Float bytes route through Buffer's writeDoubleBE/readUInt8 — the runtime
// helper on native, a DataView template on js.

// Public encode entry — lives here (not index.ms) so the encode macro can
// bindSym("encode") without an encode↔index import cycle.
export function encode(v: CborValue): Buffer {
	const w = newCborWriter();
	encodeValue(w, v);
	return Buffer.fromArray(w.bytes);
}

// --- Internal byte builder ---
//
// `bytes` is the accumulated output. Push-only — never read back during
// encoding (CBOR is single-pass forward). At the end of encoding, the
// caller (index.ms) converts the array to a Buffer in one shot.

export interface CborWriter {
	bytes: number[];
}

export function newCborWriter(): CborWriter {
	const bytes: number[] = [];
	return { bytes };
}

// --- Low-level byte primitives ---

function writeByte(w: CborWriter, b: number): void {
	w.bytes.push(b & 0xff);
}

// Write `byteCount` bytes of `value` in big-endian order. `value` must be a
// non-negative integer fitting in 53 bits (JS safe integer range). Uses
// arithmetic instead of bitwise so the high byte is correct even when value
// exceeds 2^31 (signed 32-bit sign-extension would corrupt that range).
function writeBE(w: CborWriter, value: number, byteCount: number): void {
	let pos = byteCount - 1;
	while (pos >= 0) {
		let div = 1;
		let k = 0;
		while (k < pos) { div = div * 256; k = k + 1; }
		const byte = ((value / div) | 0) % 256;
		w.bytes.push(byte);
		pos = pos - 1;
	}
}

// Write 8 bytes of an int64 in big-endian order. Splits the int64 into upper
// 32 + lower 32 via div/mod: bitwise ops on int64 do not wrap correctly on the
// JS backend.
function writeInt64BE(w: CborWriter, value: int64): void {
	const upper = Number(value / (4294967296 as int64));
	const lower = Number(value % (4294967296 as int64));
	writeBE(w, upper, 4);
	writeBE(w, lower, 4);
}

// --- Head encoding ---
//
// CBOR initial byte = (major_type << 5) | additional_info
// additional_info encodes the argument (length / value / tag number):
//   0..23 → arg fits inline in the additional_info bits
//   24    → 1-byte arg follows  (uint8)
//   25    → 2-byte arg follows  (uint16 BE)
//   26    → 4-byte arg follows  (uint32 BE)
//   27    → 8-byte arg follows  (uint64 BE)

export function writeHead(w: CborWriter, major: number, arg: int64): void {
	const m = (major & 0x07) << 5;
	const a = Number(arg);
	match (true) {
		_ when (arg < (24 as int64)) => {
			writeByte(w, m + a);
		},
		_ when (arg < (256 as int64)) => {
			writeByte(w, m | 24);
			writeByte(w, a);
		},
		_ when (arg < (65536 as int64)) => {
			writeByte(w, m | 25);
			writeBE(w, a, 2);
		},
		_ when (arg < (4294967296 as int64)) => {
			writeByte(w, m | 26);
			writeBE(w, a, 4);
		},
		_ => {
			writeByte(w, m | 27);
			writeInt64BE(w, arg);
		},
	};
}

// --- Major-type encoders ---

// Major 0 / 1 (collapsed Int variant). Negative values use the major-1 wire
// form with arg = -1 - value (RFC 8949 §3.1 — the offset encoding).
export function encodeInt(w: CborWriter, value: int64): void {
	if (value >= (0 as int64)) {
		writeHead(w, 0, value);
	} else {
		// arg = -1 - value. For value = -1 → arg = 0. For -100 → 99.
		const arg = ((-1 as int64) - value) as int64;
		writeHead(w, 1, arg);
	}
}

// Push every byte of `s` onto the writer. The string form is used by the
// major-3 (text) emitter; the Buffer form by major-2 (raw bytes) — the wire
// payload is identical bytes either way, only the head differs.
function pushStringBytes(w: CborWriter, s: string): void {
	const n = s.byteLength;
	let i = 0;
	while (i < n) {
		w.bytes.push(s.byteAt(i) & 0xff);
		i = i + 1;
	}
}

function pushBufferBytes(w: CborWriter, b: Buffer): void {
	const n = b.byteLength;
	let i = 0;
	while (i < n) {
		w.bytes.push(b.byteAt(i) & 0xff);
		i = i + 1;
	}
}

// Major 3: text string (UTF-8). The string's `byteLength` property already
// gives UTF-8 byte count (MS strings are UTF-8 internally).
export function encodeText(w: CborWriter, s: string): void {
	writeHead(w, 3, s.byteLength as int64);
	pushStringBytes(w, s);
}

// Major 4: array. Length-prefixed; items follow in order.
export function encodeArray(w: CborWriter, items: CborValue[]): void {
	writeHead(w, 4, items.length as int64);
	for (const item of items) {
		encodeValue(w, item);
	}
}

// Major 5: map. Pair count prefixed; alternating key, value.
// V1 expects keys.length === values.length; mismatched arrays are caller's
// responsibility (no validation here for performance).
export function encodeMap(w: CborWriter, keys: CborValue[], values: CborValue[]): void {
	writeHead(w, 5, keys.length as int64);
	let i = 0;
	while (i < keys.length) {
		encodeValue(w, keys[i]);
		encodeValue(w, values[i]);
		i = i + 1;
	}
}

// Major 6: tag. Tag number in the head, then the inner value.
export function encodeTag(w: CborWriter, tagNum: int64, inner: CborValue): void {
	writeHead(w, 6, tagNum);
	encodeValue(w, inner);
}

// --- Major 7 (special) ---

const MAJOR7_HEAD: number = 7 << 5;
const SIMPLE_FALSE: number = 20;
const SIMPLE_TRUE: number = 21;
const SIMPLE_NULL: number = 22;
const SIMPLE_UNDEFINED: number = 23;

// Push a single major-7 byte with `info` packed into the additional-info bits.
// Used for inline simple values (info < 24) including bool/null/undefined.
function pushMajor7Inline(w: CborWriter, info: number): void {
	w.bytes.push(MAJOR7_HEAD | (info & 0x1f));
}

export function encodeBool(w: CborWriter, b: boolean): void {
	pushMajor7Inline(w, b ? SIMPLE_TRUE : SIMPLE_FALSE);
}

export function encodeNull(w: CborWriter): void {
	pushMajor7Inline(w, SIMPLE_NULL);
}

export function encodeUndefined(w: CborWriter): void {
	pushMajor7Inline(w, SIMPLE_UNDEFINED);
}

// Simple values 0..19 and 32..255 (RFC 8949 §3.3). Values 20..23 are bool/
// null/undefined (special-cased above) and 24..31 are reserved for the float
// / break encodings — caller must not pass those.
export function encodeSimple(w: CborWriter, n: number): void {
	if (n < 24) {
		pushMajor7Inline(w, n);
		return;
	}
	w.bytes.push(MAJOR7_HEAD | 24);
	w.bytes.push(n & 0xff);
}

// Major 7, additional info 27 — IEEE 754 double-precision float.
// V1 always emits double; the encoder doesn't try to downcast to half/single
// even when the value would fit (RFC 8949 §3.4 allows this — the canonical
// encoding rules are an optional layer). Routes through Buffer's runtime
// writeDoubleBE helper to produce the 8 BE bytes; float encoding has no
// inline tests — coverage lives in native probes.
export function encodeFloat(w: CborWriter, f: float64): void {
	w.bytes.push(MAJOR7_HEAD | 27);
	const buf = Buffer.allocUnsafe(8);
	buf.writeDoubleBE(f, 0);
	let i: number = 0;
	while (i < 8) {
		w.bytes.push(buf.readUInt8(i));
		i = i + 1;
	}
}

// --- Generic dispatch ---

export function encodeValue(w: CborWriter, v: CborValue): void {
	match (v.kind) {
		CborKind.Int       => { encodeInt(w, v.intVal); },
		CborKind.Bytes     => {
			writeHead(w, 2, v.bytesVal.byteLength as int64);
			pushBufferBytes(w, v.bytesVal);
		},
		CborKind.Text      => { encodeText(w, v.textVal); },
		CborKind.Array     => { encodeArray(w, v.items); },
		CborKind.Map       => { encodeMap(w, v.keys, v.values); },
		CborKind.Tag       => { encodeTag(w, v.tagNum, v.tagged); },
		CborKind.Bool      => { encodeBool(w, v.boolVal); },
		CborKind.Null      => { encodeNull(w); },
		CborKind.Undefined => { encodeUndefined(w); },
		CborKind.Float     => { encodeFloat(w, v.floatVal); },
		CborKind.Simple    => { encodeSimple(w, v.simpleVal); },
	};
}

// --- Tests ---

// RFC 8949 Appendix A — Examples of Encoded CBOR Data Items
// We encode each, capture the byte sequence, and assert against the spec.

// Helper: build writer, encode, return bytes.
function encInt(value: int64): number[] {
	const w = newCborWriter();
	encodeInt(w, value);
	return w.bytes;
}

function encText(s: string): number[] {
	const w = newCborWriter();
	encodeText(w, s);
	return w.bytes;
}

function encArray(items: CborValue[]): number[] {
	const w = newCborWriter();
	encodeArray(w, items);
	return w.bytes;
}

// === RFC 8949 Appendix A — Integer encodings (major 0 + 1) ===

test "encode int 0 → 0x00" {
	const b = encInt(0 as int64);
	assert b.length === 1;
	assert b[0] === 0x00;
}

test "encode int 1 → 0x01" {
	const b = encInt(1 as int64);
	assert b.length === 1;
	assert b[0] === 0x01;
}

test "encode int 10 → 0x0a" {
	const b = encInt(10 as int64);
	assert b.length === 1;
	assert b[0] === 0x0a;
}

test "encode int 23 → 0x17 (max inline)" {
	const b = encInt(23 as int64);
	assert b.length === 1;
	assert b[0] === 0x17;
}

test "encode int 24 → 0x18 0x18 (1-byte arg threshold)" {
	const b = encInt(24 as int64);
	assert b.length === 2;
	assert b[0] === 0x18;
	assert b[1] === 0x18;
}

test "encode int 25 → 0x18 0x19" {
	const b = encInt(25 as int64);
	assert b.length === 2;
	assert b[0] === 0x18;
	assert b[1] === 0x19;
}

test "encode int 100 → 0x18 0x64" {
	const b = encInt(100 as int64);
	assert b.length === 2;
	assert b[0] === 0x18;
	assert b[1] === 0x64;
}

test "encode int 1000 → 0x19 0x03 0xe8" {
	const b = encInt(1000 as int64);
	assert b.length === 3;
	assert b[0] === 0x19;
	assert b[1] === 0x03;
	assert b[2] === 0xe8;
}

test "encode int 1000000 → 0x1a 0x00 0x0f 0x42 0x40 (4-byte arg)" {
	const b = encInt(1000000 as int64);
	assert b.length === 5;
	assert b[0] === 0x1a;
	assert b[1] === 0x00;
	assert b[2] === 0x0f;
	assert b[3] === 0x42;
	assert b[4] === 0x40;
}

test "encode int 1000000000000 → 0x1b ... (8-byte arg)" {
	const b = encInt(1000000000000 as int64);
	assert b.length === 9;
	assert b[0] === 0x1b;
	// 1_000_000_000_000 = 0x000000e8d4a51000
	assert b[1] === 0x00;
	assert b[2] === 0x00;
	assert b[3] === 0x00;
	assert b[4] === 0xe8;
	assert b[5] === 0xd4;
	assert b[6] === 0xa5;
	assert b[7] === 0x10;
	assert b[8] === 0x00;
}

test "encode int -1 → 0x20" {
	const b = encInt(-1 as int64);
	assert b.length === 1;
	assert b[0] === 0x20;
}

test "encode int -10 → 0x29" {
	const b = encInt(-10 as int64);
	assert b.length === 1;
	assert b[0] === 0x29;
}

test "encode int -100 → 0x38 0x63" {
	const b = encInt(-100 as int64);
	assert b.length === 2;
	assert b[0] === 0x38;
	assert b[1] === 0x63;
}

test "encode int -1000 → 0x39 0x03 0xe7" {
	const b = encInt(-1000 as int64);
	assert b.length === 3;
	assert b[0] === 0x39;
	assert b[1] === 0x03;
	assert b[2] === 0xe7;
}

// === RFC 8949 Appendix A — Text strings (major 3) ===

test "encode text \"\" → 0x60" {
	const b = encText("");
	assert b.length === 1;
	assert b[0] === 0x60;
}

test "encode text \"a\" → 0x61 0x61" {
	const b = encText("a");
	assert b.length === 2;
	assert b[0] === 0x61;
	assert b[1] === 0x61;
}

test "encode text \"IETF\" → 0x64 0x49 0x45 0x54 0x46" {
	const b = encText("IETF");
	assert b.length === 5;
	assert b[0] === 0x64;
	assert b[1] === 0x49;  // 'I'
	assert b[2] === 0x45;  // 'E'
	assert b[3] === 0x54;  // 'T'
	assert b[4] === 0x46;  // 'F'
}

test "encode text 24 chars → 0x78 0x18 + 24 bytes (1-byte length threshold)" {
	const s = "aaaaaaaaaaaaaaaaaaaaaaaa"; // 24 'a's
	const b = encText(s);
	assert b.length === 26;
	assert b[0] === 0x78;
	assert b[1] === 0x18;
	assert b[2] === 0x61;  // 'a'
	assert b[25] === 0x61;
}

// === RFC 8949 Appendix A — Arrays (major 4) ===

// Helper to construct CborValue inline for tests.
import { cborInt, cborText } from "./builder";

test "encode array [] → 0x80" {
	const items: CborValue[] = [];
	const b = encArray(items);
	assert b.length === 1;
	assert b[0] === 0x80;
}

test "encode array [1, 2, 3] → 0x83 0x01 0x02 0x03" {
	const items: CborValue[] = [cborInt(1 as int64), cborInt(2 as int64), cborInt(3 as int64)];
	const b = encArray(items);
	assert b.length === 4;
	assert b[0] === 0x83;
	assert b[1] === 0x01;
	assert b[2] === 0x02;
	assert b[3] === 0x03;
}

test "encode array [1, [2, 3], [4, 5]] → 0x83 0x01 0x82 0x02 0x03 0x82 0x04 0x05" {
	const inner1: CborValue[] = [cborInt(2 as int64), cborInt(3 as int64)];
	const inner2: CborValue[] = [cborInt(4 as int64), cborInt(5 as int64)];
	const outer: CborValue[] = [cborInt(1 as int64), { kind: CborKind.Array, items: inner1 }, { kind: CborKind.Array, items: inner2 }];
	const b = encArray(outer);
	assert b.length === 8;
	assert b[0] === 0x83;
	assert b[1] === 0x01;
	assert b[2] === 0x82;
	assert b[3] === 0x02;
	assert b[4] === 0x03;
	assert b[5] === 0x82;
	assert b[6] === 0x04;
	assert b[7] === 0x05;
}

// === Major 7 simple values ===

test "encode false → 0xf4" {
	const w = newCborWriter();
	encodeBool(w, false);
	assert w.bytes.length === 1;
	assert w.bytes[0] === 0xf4;
}

test "encode true → 0xf5" {
	const w = newCborWriter();
	encodeBool(w, true);
	assert w.bytes.length === 1;
	assert w.bytes[0] === 0xf5;
}

test "encode null → 0xf6" {
	const w = newCborWriter();
	encodeNull(w);
	assert w.bytes.length === 1;
	assert w.bytes[0] === 0xf6;
}

test "encode undefined → 0xf7" {
	const w = newCborWriter();
	encodeUndefined(w);
	assert w.bytes.length === 1;
	assert w.bytes[0] === 0xf7;
}

test "encode simple 16 → 0xf0" {
	const w = newCborWriter();
	encodeSimple(w, 16);
	assert w.bytes.length === 1;
	assert w.bytes[0] === 0xf0;
}

test "encode simple 255 → 0xf8 0xff (2-byte simple)" {
	const w = newCborWriter();
	encodeSimple(w, 255);
	assert w.bytes.length === 2;
	assert w.bytes[0] === 0xf8;
	assert w.bytes[1] === 0xff;
}

// === Generic dispatch ===

test "encodeValue dispatches Int" {
	const w = newCborWriter();
	encodeValue(w, cborInt(42 as int64));
	assert w.bytes.length === 2;
	assert w.bytes[0] === 0x18;
	assert w.bytes[1] === 0x2a;
}

test "encodeValue dispatches Text" {
	const w = newCborWriter();
	encodeValue(w, cborText("a"));
	assert w.bytes.length === 2;
	assert w.bytes[0] === 0x61;
	assert w.bytes[1] === 0x61;
}

test "encodeValue dispatches nested Array" {
	const w = newCborWriter();
	const items: CborValue[] = [cborInt(1 as int64), cborText("a")];
	encodeValue(w, { kind: CborKind.Array, items });
	// 0x82 (array len 2), 0x01 (int 1), 0x61 0x61 (text "a")
	assert w.bytes.length === 4;
	assert w.bytes[0] === 0x82;
	assert w.bytes[1] === 0x01;
	assert w.bytes[2] === 0x61;
	assert w.bytes[3] === 0x61;
}
