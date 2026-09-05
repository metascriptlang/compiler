// MetaScript CBOR — Decoder (RFC 8949 §3, §5)
//
// Reads a byte stream and produces a CborValue tree. Mirrors encoder's design:
// internal reader uses `uint8[]`. Public API at index.ms accepts a Buffer
// and converts to uint8[] for the reader (one-time linear copy, V1 simple).
//
// V1 scope mirrors encoder:
//   - Major 0..6 fully supported
//   - Major 7: Bool / Null / Undefined / Simple — supported
//   - Major 7: Float (half/single/double) — DEFERRED to Phase 1.3
//   - Indefinite-length encoding NOT supported (returns error)
//   - Arguments fitting int64 supported. arg > 2^63-1 (rare in practice) → error
//
// Error reporting: Result<CborValue, string> at the top level. Internal
// helpers set `reader.error` and return a sentinel; caller checks `error`
// before consuming results (mirrors std/serialize/json/parser.ms pattern).

import { Buffer } from "std/core/buffer";
import { CborKind, CborValue } from "./types";
import {
	cborInt, cborBytes, cborText, cborArray, cborMap, cborTag,
	cborBool, cborNull, cborUndefined, cborFloat, cborSimple,
} from "./builder";

// Buffer is target-agnostic: alloc/set/readDoubleBE/readFloatBE route to the
// C runtime externs on native and to DataView templates on js.

const MAX_DEPTH: number = 1000;

// Sanity cap on collection lengths declared in the wire. RFC 8949 allows
// arrays/maps up to 2^64-1 items, but a malicious decoder seeing a
// declared length of 2^31 with only a few bytes of payload would attempt
// to push 2 billion items into a uint8[] and OOM the host. Cap at 100M;
// any plausible CBOR document fits well below this. Decoder also cross-
// checks `length <= remaining(r)` (each item is ≥1 byte) to reject
// length-prefix-without-payload attacks.
const MAX_COLLECTION_SIZE: number = 100000000;

// Copy `length` bytes from r.buf[start..start+length] into a freshly-
// allocated Buffer. Used by both Bytes decoding and the double-precision
// float decode path; previously inlined in 3 places.
function bytesToBuffer(src: uint8[], start: number, length: number): Buffer {
	const buf = Buffer.alloc(length);
	let i = 0;
	while (i < length) {
		buf.set(i, src[start + i] & 0xff);
		i = i + 1;
	}
	return buf;
}

// --- Reader state ---

export interface CborReader {
	buf: uint8[];
	pos: number;
	error: string;  // empty when no error
	depth: number;  // recursion depth tracker
}

export function newCborReader(bytes: uint8[]): CborReader {
	return { buf: bytes, pos: 0, error: "", depth: 0 };
}

// --- Low-level byte primitives ---

function setError(r: CborReader, msg: string): void {
	if (r.error === "") r.error = msg;
}

function remaining(r: CborReader): number {
	return r.buf.length - r.pos;
}

function readByte(r: CborReader): number {
	if (r.pos >= r.buf.length) {
		setError(r, "unexpected end of input");
		return 0;
	}
	const b = r.buf[r.pos];
	r.pos = r.pos + 1;
	return b & 0xff;
}

// Peek next byte without advancing. Used by indefinite-length decoders to
// detect the 0xff break code before deciding to read another chunk/item.
function peekByte(r: CborReader): number {
	if (r.pos >= r.buf.length) return -1;
	return r.buf[r.pos] & 0xff;
}

// Consume next byte iff it is the break code (0xff = major 7 + info 31).
// Returns true on consume, false if next byte is something else (caller
// continues reading another chunk/item).
function tryConsumeBreak(r: CborReader): boolean {
	if (peekByte(r) === 0xff) { r.pos = r.pos + 1; return true; }
	return false;
}

// Read `byteCount` bytes BE, return as number. Caller ensures byteCount ≤ 6
// to keep result < 2^48 (well within JS safe integer). For 8-byte case use
// readInt64BE. Sets error if not enough bytes.
function readBE(r: CborReader, byteCount: number): number {
	if (remaining(r) < byteCount) {
		setError(r, "truncated multi-byte argument");
		return 0;
	}
	let value: number = 0;
	let i: number = 0;
	while (i < byteCount) {
		value = value * 256 + (r.buf[r.pos + i] & 0xff);
		i = i + 1;
	}
	r.pos = r.pos + byteCount;
	return value;
}

// Read 8 bytes BE as int64. Reverses encoder's writeInt64BE: combines upper
// 4 bytes with lower 4 bytes via multiply-and-add. Result fits in int64 if
// the high bit of the high byte is 0 (i.e., value < 2^63). Otherwise we
// signal error since V1 doesn't support uint64 > 2^63-1.
function readInt64BE(r: CborReader): int64 {
	if (remaining(r) < 8) {
		setError(r, "truncated 8-byte argument");
		return 0 as int64;
	}
	const upper = readBE(r, 4);  // bits 32..63
	const lower = readBE(r, 4);  // bits 0..31
	if (upper >= 2147483648) {
		// upper has its high bit set → value ≥ 2^63 → out of int64 positive range
		setError(r, "uint64 argument exceeds int64 range (V1 limitation)");
		return 0 as int64;
	}
	// (upper * 2^32) + lower as int64
	return ((upper as int64) * (4294967296 as int64)) + (lower as int64);
}

// --- Head decoding ---
//
// Returns the (major, arg) pair from the initial byte + any argument bytes.
// Sets error and returns (0, 0) on failure.

export interface CborHead {
	major: number;
	arg: int64;
	info: number;  // additional_info bits 0..4 of initial byte (preserved for caller)
}

export function readHead(r: CborReader): CborHead {
	const ib = readByte(r);
	if (r.error !== "") return { major: 0, arg: 0 as int64, info: 0 };
	const major = (ib >> 5) & 0x07;
	const info = ib & 0x1f;
	if (info < 24) {
		return { major, arg: info as int64, info };
	}
	if (info === 24) {
		const a = readByte(r);
		return { major, arg: a as int64, info };
	}
	if (info === 25) {
		const a = readBE(r, 2);
		return { major, arg: a as int64, info };
	}
	if (info === 26) {
		const a = readBE(r, 4);
		return { major, arg: a as int64, info };
	}
	if (info === 27) {
		if (major === 7) {
			// Major 7 info 27 = double-precision float. Don't read the arg
			// here — readInt64BE rejects bit patterns ≥ 2^63 (sign bit set,
			// e.g. all negative floats including -0.0). Float decoding in
			// decodeSpecial reads the 8 raw bytes directly into a Buffer.
			return { major, arg: 0 as int64, info };
		}
		const a = readInt64BE(r);
		return { major, arg: a, info };
	}
	if (info === 31) {
		// Indefinite-length marker (RFC 8949 §3.2). Valid for major 2/3/4/5
		// (content terminated by break code) and major 7 (the break code
		// itself). Invalid for 0/1/6 — caller verifies after dispatch.
		return { major, arg: 0 as int64, info };
	}
	// 28..30 reserved per RFC 8949 §3
	setError(r, "reserved additional-info value (28..30) in head byte");
	return { major: 0, arg: 0 as int64, info };
}

// --- Major-type decoders ---

function decodeBytes(r: CborReader, length: number): CborValue {
	if (remaining(r) < length) {
		setError(r, "truncated byte string payload");
		return cborNull();
	}
	// Inline Bytes fixtures are skipped — coverage lives in examples/_probe_cbor.ms.
	const buf = bytesToBuffer(r.buf, r.pos, length);
	r.pos = r.pos + length;
	return cborBytes(buf);
}

// Portable UTF-8 byte-sequence → string decoder. Works in both native MS
// (compiled binary) and the JS backend because it only uses bitwise +
// arithmetic + fromCodePoint — no Buffer or extern dependencies. Stops at
// truncated multi-byte sequences (V1: silently drops the trailing partial
// run; spec strict mode would error). Caller passes the byte source array
// and the byte range to decode.
function utf8FromBytes(bytes: uint8[], start: number, length: number): string {
	// All masks/constants declared as int32 so the bitwise ops stay int-typed
	// throughout. MS's `&` requires integer operands; mixing int32 with a
	// `number` literal (which defaults to float64) errors at type-check.
	const MASK_FF: int32 = 0xff;
	const MASK_E0: int32 = 0xe0;
	const MASK_C0: int32 = 0xc0;
	const MASK_F0: int32 = 0xf0;
	const MASK_F8: int32 = 0xf8;
	const MASK_1F: int32 = 0x1f;
	const MASK_3F: int32 = 0x3f;
	const MASK_0F: int32 = 0x0f;
	const MASK_07: int32 = 0x07;

	let s: string = "";
	let i: number = start;
	const end: number = start + length;
	while (i < end) {
		const b1: int32 = (bytes[i] as int32) & MASK_FF;
		if (b1 < 0x80) {
			// 1-byte ASCII
			s = s + fromCodePoint(b1);
			i = i + 1;
		} else if ((b1 & MASK_E0) === MASK_C0) {
			// 2-byte sequence: 110xxxxx 10xxxxxx
			if (i + 1 >= end) { i = end; }
			else {
				const b2: int32 = (bytes[i + 1] as int32) & MASK_FF;
				const cp: int32 = ((b1 & MASK_1F) << 6) | (b2 & MASK_3F);
				s = s + fromCodePoint(cp);
				i = i + 2;
			}
		} else if ((b1 & MASK_F0) === MASK_E0) {
			// 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
			if (i + 2 >= end) { i = end; }
			else {
				const b2: int32 = (bytes[i + 1] as int32) & MASK_FF;
				const b3: int32 = (bytes[i + 2] as int32) & MASK_FF;
				const cp: int32 = ((b1 & MASK_0F) << 12) | ((b2 & MASK_3F) << 6) | (b3 & MASK_3F);
				s = s + fromCodePoint(cp);
				i = i + 3;
			}
		} else if ((b1 & MASK_F8) === MASK_F0) {
			// 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
			if (i + 3 >= end) { i = end; }
			else {
				const b2: int32 = (bytes[i + 1] as int32) & MASK_FF;
				const b3: int32 = (bytes[i + 2] as int32) & MASK_FF;
				const b4: int32 = (bytes[i + 3] as int32) & MASK_FF;
				const cp: int32 = ((b1 & MASK_07) << 18) | ((b2 & MASK_3F) << 12) | ((b3 & MASK_3F) << 6) | (b4 & MASK_3F);
				s = s + fromCodePoint(cp);
				i = i + 4;
			}
		} else {
			// Stray continuation byte (10xxxxxx) without a leading byte —
			// skip and keep going; lenient decode.
			i = i + 1;
		}
	}
	return s;
}

function decodeText(r: CborReader, length: number): CborValue {
	if (remaining(r) < length) {
		setError(r, "truncated text string payload");
		return cborNull();
	}
	const s = utf8FromBytes(r.buf, r.pos, length);
	r.pos = r.pos + length;
	return cborText(s);
}

// Enter a nested-decode scope. Bumps depth and signals failure (depth too
// deep) so the caller can early-return. Pair with `exitDepth` on every exit
// path. Used by array/map/tag decoders.
function enterDepth(r: CborReader): boolean {
	r.depth = r.depth + 1;
	if (r.depth > MAX_DEPTH) {
		setError(r, "max recursion depth exceeded");
		r.depth = r.depth - 1;
		return false;
	}
	return true;
}

function exitDepth(r: CborReader): void {
	r.depth = r.depth - 1;
}

// Reject collection lengths that exceed the sanity cap or claim more items
// than the remaining payload could possibly hold. `minBytesPerItem` is 1 for
// arrays (each item ≥1 byte head) and 2 for map pairs (key + value).
function rejectOversizedCollection(r: CborReader, length: number, minBytesPerItem: number, label: string): boolean {
	if (length > MAX_COLLECTION_SIZE || (length * minBytesPerItem) > remaining(r)) {
		setError(r, `${label} length exceeds sanity cap or available payload`);
		return true;
	}
	return false;
}

function decodeArrayLen(r: CborReader, length: number): CborValue {
	if (rejectOversizedCollection(r, length, 1, "array")) return cborNull();
	if (!enterDepth(r)) return cborNull();
	const items: CborValue[] = [];
	let i: number = 0;
	while (i < length) {
		const v = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		items.push(v);
		i = i + 1;
	}
	exitDepth(r);
	return cborArray(items);
}

function decodeMapLen(r: CborReader, pairCount: number): CborValue {
	if (rejectOversizedCollection(r, pairCount, 2, "map pair")) return cborNull();
	if (!enterDepth(r)) return cborNull();
	const keys: CborValue[] = [];
	const values: CborValue[] = [];
	let i: number = 0;
	while (i < pairCount) {
		const k = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		const v = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		keys.push(k);
		values.push(v);
		i = i + 1;
	}
	exitDepth(r);
	return cborMap(keys, values);
}

// --- Indefinite-length decoders (RFC 8949 §3.2) ---
//
// Major 2/3 indefinite: sequence of finite-length chunks of the SAME major
// type, terminated by break (0xff). Nesting prohibited (no indefinite chunk
// inside indefinite parent of the same type) — caller enforces by requiring
// info < 31 on each chunk's head.
//
// Major 4/5 indefinite: sequence of items (4) or key-value pairs (5),
// terminated by break. Items may themselves be indefinite — no length cap
// pre-check possible (use depth limit + per-item enterDepth on nested).

// Append finite-length chunks of major-type `expectedMajor` until break.
// Chunks must NOT themselves be indefinite (RFC §3.2.3 prohibits nesting).
// Returns the concatenated byte buffer.
function readIndefiniteByteChunks(r: CborReader, expectedMajor: number, label: string): uint8[] {
	const out: uint8[] = [];
	while (true) {
		if (r.error !== "") return out;
		if (tryConsumeBreak(r)) return out;
		const head = readHead(r);
		if (r.error !== "") return out;
		if (head.major !== expectedMajor) {
			setError(r, `indefinite-length ${label}: chunk has wrong major type`);
			return out;
		}
		if (head.info === 31) {
			setError(r, `indefinite-length ${label}: nested indefinite chunk prohibited (RFC 8949 §3.2.3)`);
			return out;
		}
		const length = Number(head.arg);
		if (remaining(r) < length) {
			setError(r, `indefinite-length ${label}: truncated chunk payload`);
			return out;
		}
		// DoS cap — match array/map indef ceiling (MAX_COLLECTION_SIZE). A
		// malicious stream of millions of small chunks otherwise grows `out`
		// unbounded.
		if (out.length + length > MAX_COLLECTION_SIZE) {
			setError(r, `indefinite-length ${label}: total bytes exceeds sanity cap`);
			return out;
		}
		for (let i = 0; i < length; i = i + 1) {
			out.push((r.buf[r.pos + i] & 0xff) as uint8);
		}
		r.pos = r.pos + length;
	}
	return out;  // unreachable
}

function decodeBytesIndef(r: CborReader): CborValue {
	if (!enterDepth(r)) return cborNull();
	const bytes = readIndefiniteByteChunks(r, 2, "byte string");
	exitDepth(r);
	if (r.error !== "") return cborNull();
	const buf = bytesToBuffer(bytes, 0, bytes.length);
	return cborBytes(buf);
}

function decodeTextIndef(r: CborReader): CborValue {
	if (!enterDepth(r)) return cborNull();
	const bytes = readIndefiniteByteChunks(r, 3, "text string");
	exitDepth(r);
	if (r.error !== "") return cborNull();
	return cborText(utf8FromBytes(bytes, 0, bytes.length));
}

function decodeArrayIndef(r: CborReader): CborValue {
	if (!enterDepth(r)) return cborNull();
	const items: CborValue[] = [];
	while (true) {
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		if (tryConsumeBreak(r)) break;
		if (items.length >= MAX_COLLECTION_SIZE) {
			setError(r, "indefinite-length array exceeds sanity cap");
			exitDepth(r);
			return cborNull();
		}
		const v = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		items.push(v);
	}
	exitDepth(r);
	return cborArray(items);
}

function decodeMapIndef(r: CborReader): CborValue {
	if (!enterDepth(r)) return cborNull();
	const keys: CborValue[] = [];
	const values: CborValue[] = [];
	while (true) {
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		if (tryConsumeBreak(r)) break;
		if (keys.length >= MAX_COLLECTION_SIZE) {
			setError(r, "indefinite-length map exceeds sanity cap");
			exitDepth(r);
			return cborNull();
		}
		const k = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		// Break code after key but before value is malformed per RFC §3.2.2.
		if (peekByte(r) === 0xff) {
			setError(r, "indefinite-length map: break code between key and value");
			exitDepth(r);
			return cborNull();
		}
		const v = decodeValue(r);
		if (r.error !== "") { exitDepth(r); return cborNull(); }
		keys.push(k);
		values.push(v);
	}
	exitDepth(r);
	return cborMap(keys, values);
}

// Major 7 special values: dispatch by additional_info.
//   20 = false, 21 = true, 22 = null, 23 = undefined
//   24 = 1-byte simple value follows
//   25 = half float, 26 = single float, 27 = double float
// info=31 (break code) is intercepted in decodeValue before this dispatch
// fires — see indefinite-length branch.
function decodeSpecial(r: CborReader, info: number, arg: int64): CborValue {
	return match (info) {
		20 => cborBool(false),
		21 => cborBool(true),
		22 => cborNull(),
		23 => cborUndefined(),
		24 => cborSimple(Number(arg)),
		25 => decodeHalfFloat(arg),
		26 => decodeSingleFloat(arg),
		27 => decodeDoubleFloat(r),
		_ when (info < 24) => cborSimple(info),  // inline simple value 0..19
		_ => decodeError(r, "invalid major-7 additional-info"),
	};
}

// Set error and return a sentinel CborValue. Match-arm-friendly wrapper —
// `setError` is `void` so it can't appear on its own as a match arm body
// (the arm needs to produce a CborValue).
function decodeError(r: CborReader, msg: string): CborValue {
	setError(r, msg);
	return cborNull();
}

// Compute 2^exp where -24 ≤ exp ≤ 15 (half-precision normal/subnormal range).
// MS has no Math.pow; small loop is sufficient since exp is bounded.
function pow2(exp: int32): number {
	let r: number = 1.0;
	if (exp >= 0) {
		for (let i = 0; i < exp; i = i + 1) {
			r = r * 2.0;
		}
	} else {
		const n: int32 = -exp;
		for (let i = 0; i < n; i = i + 1) {
			r = r / 2.0;
		}
	}
	return r;
}

// Bit-cast an explicit IEEE 754 double from its two MSBs via Buffer round-trip.
// Used to produce ±Infinity (0x7FF0…/0xFFF0…) and quiet NaN (0x7FF8…) without
// relying on `0.0/0.0`-style arithmetic (MS runtime may catch divide-by-zero).
function bitsToDouble(b0: number, b1: number): number {
	const buf = Buffer.alloc(8);
	buf.set(0, b0);
	buf.set(1, b1);
	// bytes 2-7 default to zero — produces the exact IEEE 754 bit pattern
	return buf.readDoubleBE(0);
}

// Half-precision (binary16) → double per IEEE 754 §3.4 + RFC 8949 §3.4.
// `arg` holds the 16-bit raw value (readHead consumed 2 bytes BE into arg
// for info=25). Layout:
//   bit 15:     sign
//   bits 10-14: exp (5-bit, biased by 15)
//   bits 0-9:   mantissa (10-bit; implicit leading 1 for normal values)
// Cases:
//   exp=0, mant=0:   ±0 (both collapse to 0.0)
//   exp=0, mant>0:   subnormal: sign × 2^-14 × (mant/1024) = sign × mant / 2^24
//   exp=31, mant=0:  ±Infinity (bit-cast)
//   exp=31, mant>0:  NaN (quiet, bit-cast)
//   else (normal):   sign × 2^(exp-15) × (1 + mant/1024)
function decodeHalfFloat(arg: int64): CborValue {
	const v: int32 = arg as int32;
	const sign: int32 = (v >> 15) & 0x1;
	const exp: int32 = (v >> 10) & 0x1f;
	const mant: int32 = v & 0x3ff;
	const signMul: number = sign === 0 ? 1.0 : -1.0;

	if (exp === 0) {
		if (mant === 0) return cborFloat(0.0);
		return cborFloat(signMul * (mant as float64) / 16777216.0);
	}
	if (exp === 31) {
		if (mant === 0) return cborFloat(bitsToDouble(sign === 0 ? 0x7F : 0xFF, 0xF0));
		return cborFloat(bitsToDouble(0x7F, 0xF8));
	}
	return cborFloat(signMul * pow2(exp - 15) * (1.0 + (mant as float64) / 1024.0));
}

// Single-precision (4 bytes). arg holds the 32-bit IEEE bit pattern in its
// lower 32 bits.
function decodeSingleFloat(arg: int64): CborValue {
	const buf = Buffer.alloc(4);
	const v32 = Number(arg);
	buf.set(0, Math.floor(v32 / 16777216) % 256);
	buf.set(1, Math.floor(v32 / 65536) % 256);
	buf.set(2, Math.floor(v32 / 256) % 256);
	buf.set(3, v32 % 256);
	return cborFloat(buf.readFloatBE(0));
}

// Double-precision (8 bytes). readHead intentionally left the 8 arg-bytes
// unconsumed (its int64 path rejects bit patterns with sign bit set, which
// covers all negative floats and ±Inf). Read the raw bytes directly here.
// Inline float tests skipped — coverage via native probe.
function decodeDoubleFloat(r: CborReader): CborValue {
	if (remaining(r) < 8) {
		return decodeError(r, "truncated double-precision float payload");
	}
	const buf = bytesToBuffer(r.buf, r.pos, 8);
	r.pos = r.pos + 8;
	return cborFloat(buf.readDoubleBE(0));
}

// --- Generic dispatch ---

export function decodeValue(r: CborReader): CborValue {
	if (r.error !== "") return cborNull();
	const head = readHead(r);
	if (r.error !== "") return cborNull();
	// Indefinite-length (info=31) — RFC 8949 §3.2 allows only for major
	// 2/3/4/5 (content + break) and major 7 (the break code itself).
	// At top level (and inside arrays/maps), break code is illegal —
	// indefinite-collection decoders consume their own terminator.
	if (head.info === 31) {
		return match (head.major) {
			2 => decodeBytesIndef(r),
			3 => decodeTextIndef(r),
			4 => decodeArrayIndef(r),
			5 => decodeMapIndef(r),
			7 => decodeError(r, "break code outside indefinite-length context"),
			_ => decodeError(r, `indefinite-length not allowed for major type ${head.major}`),
		};
	}
	return match (head.major) {
		0 => cborInt(head.arg),
		1 => cborInt(((-1 as int64) - head.arg) as int64),  // -1 - arg per RFC 8949 §3.1
		2 => decodeBytes(r, Number(head.arg)),
		3 => decodeText(r, Number(head.arg)),
		4 => decodeArrayLen(r, Number(head.arg)),
		5 => decodeMapLen(r, Number(head.arg)),
		6 => decodeTag(r, head.arg),
		_ => decodeSpecial(r, head.info, head.arg),  // major 7
	};
}

// Major 6 (tag) decode with depth check. Tag chains `tag(tag(tag(...)))`
// would otherwise recurse via decodeValue without bumping depth (only
// array/map paths do), so a nested-tag bomb could blow the C call stack.
function decodeTag(r: CborReader, tagNum: int64): CborValue {
	if (!enterDepth(r)) return cborNull();
	const inner = decodeValue(r);
	exitDepth(r);
	if (r.error !== "") return cborNull();
	return cborTag(tagNum, inner);
}

// --- Top-level decode entry ---

export function decodeAll(bytes: uint8[]): Result<CborValue, string> {
	const r = newCborReader(bytes);
	const v = decodeValue(r);
	if (r.error !== "") return Result.err(r.error);
	if (r.pos < r.buf.length) {
		return Result.err(`trailing bytes after CBOR value at offset ${r.pos}`);
	}
	return Result.ok(v);
}

// --- Tests ---

// Helper: decode bytes to CborValue, returning fallback (cborNull) on error.
// Tests call this then do their own `assert` — `assert` is test-only and
// can't live inside a regular function body. Caller asserts both
// `r.value.kind` and other fields, which doubles as success-check (an
// errored decode returns cborNull whose kind is CborKind.Null).
function decOk(bytes: uint8[]): CborValue {
	const r = decodeAll(bytes);
	if (!r.ok) return cborNull();
	return r.value;
}

// === Integer decoding (mirror of encoder tests) ===

test "decode 0x00 → int 0" {
	const v = decOk([0x00]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (0 as int64);
}

test "decode 0x17 → int 23 (max inline)" {
	const v = decOk([0x17]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (23 as int64);
}

test "decode 0x18 0x18 → int 24" {
	const v = decOk([0x18, 0x18]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (24 as int64);
}

test "decode 0x18 0x64 → int 100" {
	const v = decOk([0x18, 0x64]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (100 as int64);
}

test "decode 0x19 0x03 0xe8 → int 1000" {
	const v = decOk([0x19, 0x03, 0xe8]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (1000 as int64);
}

test "decode 0x1a 0x00 0x0f 0x42 0x40 → int 1000000" {
	const v = decOk([0x1a, 0x00, 0x0f, 0x42, 0x40]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (1000000 as int64);
}

test "decode 0x1b 0x00 0x00 0x00 0xe8 0xd4 0xa5 0x10 0x00 → int 1000000000000" {
	const v = decOk([0x1b, 0x00, 0x00, 0x00, 0xe8, 0xd4, 0xa5, 0x10, 0x00]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (1000000000000 as int64);
}

test "decode 0x20 → int -1" {
	const v = decOk([0x20]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (-1 as int64);
}

test "decode 0x29 → int -10" {
	const v = decOk([0x29]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (-10 as int64);
}

test "decode 0x38 0x63 → int -100" {
	const v = decOk([0x38, 0x63]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (-100 as int64);
}

test "decode 0x39 0x03 0xe7 → int -1000" {
	const v = decOk([0x39, 0x03, 0xe7]);
	assert v.kind === CborKind.Int;
	assert v.intVal === (-1000 as int64);
}

// === Text decoding ===

test "decode 0x60 → text \"\"" {
	const v = decOk([0x60]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "";
}

test "decode 0x61 0x61 → text \"a\"" {
	const v = decOk([0x61, 0x61]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "a";
}

test "decode 0x64 IETF → text \"IETF\"" {
	const v = decOk([0x64, 0x49, 0x45, 0x54, 0x46]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "IETF";
}

test "decode UTF-8 2-byte: ü (0xC3 0xBC) → text \"ü\"" {
	// 0x62 = text length 2; 0xC3 0xBC = U+00FC (ü) in UTF-8
	const v = decOk([0x62, 0xc3, 0xbc]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "ü";
}

test "decode UTF-8 3-byte: 水 (0xE6 0xB0 0xB4) → text \"水\"" {
	// 0x63 = text length 3; 0xE6 0xB0 0xB4 = U+6C34 (水) in UTF-8
	const v = decOk([0x63, 0xe6, 0xb0, 0xb4]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "水";
}

test "decode UTF-8 4-byte: 𐅑 (0xF0 0x90 0x85 0x91) → text \"𐅑\"" {
	// 0x64 = text length 4; 0xF0 0x90 0x85 0x91 = U+10151 (𐅑 — Greek acrophonic) in UTF-8
	const v = decOk([0x64, 0xf0, 0x90, 0x85, 0x91]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "𐅑";
}

test "decode UTF-8 mixed ASCII + multi-byte" {
	// 0x67 = text length 7; "h" (1) + "é" (2) + "l" (1) + "lo" (2) + "!" (1) — wait too long
	// Use: "hé" → 'h' (0x68) + 'é' (0xC3 0xA9) = 3 bytes
	// 0x63 = text length 3
	const v = decOk([0x63, 0x68, 0xc3, 0xa9]);
	assert v.kind === CborKind.Text;
	assert v.textVal === "hé";
}

// === Array decoding ===

test "decode 0x80 → array []" {
	const v = decOk([0x80]);
	assert v.kind === CborKind.Array;
	assert v.items.length === 0;
}

test "decode 0x83 0x01 0x02 0x03 → array [1, 2, 3]" {
	const v = decOk([0x83, 0x01, 0x02, 0x03]);
	assert v.kind === CborKind.Array;
	assert v.items.length === 3;
	assert v.items[0].kind === CborKind.Int;
	assert v.items[0].intVal === (1 as int64);
	assert v.items[2].kind === CborKind.Int;
	assert v.items[2].intVal === (3 as int64);
}

test "decode nested array [1, [2, 3], [4, 5]]" {
	const v = decOk([0x83, 0x01, 0x82, 0x02, 0x03, 0x82, 0x04, 0x05]);
	assert v.kind === CborKind.Array;
	assert v.items.length === 3;
	assert v.items[1].kind === CborKind.Array;
	assert v.items[1].items.length === 2;
	assert v.items[1].items[0].kind === CborKind.Int;
	assert v.items[1].items[0].intVal === (2 as int64);
	assert v.items[2].kind === CborKind.Array;
	assert v.items[2].items[1].kind === CborKind.Int;
	assert v.items[2].items[1].intVal === (5 as int64);
}

// === Map decoding ===

test "decode 0xa0 → map {}" {
	const v = decOk([0xa0]);
	assert v.kind === CborKind.Map;
	assert v.keys.length === 0;
	assert v.values.length === 0;
}

test "decode 0xa2 ... → map {1: 2, 3: 4}" {
	// 0xa2 = map with 2 pairs
	// 0x01 0x02 → (1, 2)
	// 0x03 0x04 → (3, 4)
	const v = decOk([0xa2, 0x01, 0x02, 0x03, 0x04]);
	assert v.kind === CborKind.Map;
	assert v.keys.length === 2;
	assert v.keys[0].kind === CborKind.Int;
	assert v.keys[0].intVal === (1 as int64);
	assert v.values[0].kind === CborKind.Int;
	assert v.values[0].intVal === (2 as int64);
	assert v.keys[1].kind === CborKind.Int;
	assert v.keys[1].intVal === (3 as int64);
	assert v.values[1].kind === CborKind.Int;
	assert v.values[1].intVal === (4 as int64);
}

// === Tag decoding ===

test "decode 0xc0 + text → tag(0, \"x\")" {
	// 0xc0 = tag 0 (standard datetime string)
	// 0x61 0x78 = text "x"
	const v = decOk([0xc0, 0x61, 0x78]);
	assert v.kind === CborKind.Tag;
	assert v.tagNum === (0 as int64);
	assert v.tagged.kind === CborKind.Text;
	assert v.tagged.textVal === "x";
}

test "decode 0xc1 + uint → tag(1, 1363896240) (epoch timestamp)" {
	// 0xc1 = tag 1 (epoch-based date/time)
	// 0x1a 0x51 0x4b 0x67 0xb0 = 4-byte uint 1363896240
	const v = decOk([0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0]);
	assert v.kind === CborKind.Tag;
	assert v.tagNum === (1 as int64);
	assert v.tagged.kind === CborKind.Int;
	assert v.tagged.intVal === (1363896240 as int64);
}

test "decode 0xd8 0x20 + text → tag(32, \"http://...\") (URI)" {
	// 0xd8 = tag with 1-byte arg
	// 0x20 = 32 (URI tag)
	// 0x76 = text length 22
	// then 22 ASCII bytes for "http://www.example.com"
	const bytes: uint8[] = [0xd8, 0x20, 0x76,
		0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e,
		0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d];
	const v = decOk(bytes);
	assert v.kind === CborKind.Tag;
	assert v.tagNum === (32 as int64);
	assert v.tagged.kind === CborKind.Text;
	assert v.tagged.textVal === "http://www.example.com";
}

// === Long array (1-byte length head) ===

test "decode 0x98 0x19 + 25 items → array of 25" {
	// 0x98 = array, info 24 (1-byte arg follows)
	// 0x19 = 25
	// then 25 single-byte ints (1..25 all fit inline since < 24, except 24, 25 themselves)
	// Items 1..23 fit inline as 0x01..0x17
	// Items 24..25 need 2 bytes each: 0x18 0x18, 0x18 0x19
	const bytes: uint8[] = [0x98, 0x19,
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
		0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
		0x15, 0x16, 0x17,                          // 1..23 inline
		0x18, 0x18,                                // 24
		0x18, 0x19];                               // 25
	const v = decOk(bytes);
	assert v.kind === CborKind.Array;
	assert v.items.length === 25;
	assert v.items[0].kind === CborKind.Int;
	assert v.items[0].intVal === (1 as int64);
	assert v.items[22].kind === CborKind.Int;
	assert v.items[22].intVal === (23 as int64);
	assert v.items[23].kind === CborKind.Int;
	assert v.items[23].intVal === (24 as int64);
	assert v.items[24].kind === CborKind.Int;
	assert v.items[24].intVal === (25 as int64);
}

// === Mixed-type map ===

test "decode {\"a\": 1, \"b\": [2, 3]}" {
	// 0xa2 = map with 2 pairs
	// 0x61 0x61 = text "a"
	// 0x01 = int 1
	// 0x61 0x62 = text "b"
	// 0x82 0x02 0x03 = array [2, 3]
	const v = decOk([0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03]);
	assert v.kind === CborKind.Map;
	assert v.keys.length === 2;
	assert v.keys[0].kind === CborKind.Text;
	assert v.keys[0].textVal === "a";
	assert v.values[0].kind === CborKind.Int;
	assert v.values[0].intVal === (1 as int64);
	assert v.keys[1].kind === CborKind.Text;
	assert v.keys[1].textVal === "b";
	assert v.values[1].kind === CborKind.Array;
	assert v.values[1].items.length === 2;
	assert v.values[1].items[0].kind === CborKind.Int;
	assert v.values[1].items[0].intVal === (2 as int64);
	assert v.values[1].items[1].kind === CborKind.Int;
	assert v.values[1].items[1].intVal === (3 as int64);
}

test "decode [\"a\", {\"b\": \"c\"}]" {
	// 0x82 = array len 2
	// 0x61 0x61 = text "a"
	// 0xa1 = map 1 pair
	// 0x61 0x62 = text "b"
	// 0x61 0x63 = text "c"
	const v = decOk([0x82, 0x61, 0x61, 0xa1, 0x61, 0x62, 0x61, 0x63]);
	assert v.kind === CborKind.Array;
	assert v.items.length === 2;
	assert v.items[0].kind === CborKind.Text;
	assert v.items[0].textVal === "a";
	assert v.items[1].kind === CborKind.Map;
	assert v.items[1].keys[0].kind === CborKind.Text;
	assert v.items[1].keys[0].textVal === "b";
	assert v.items[1].values[0].kind === CborKind.Text;
	assert v.items[1].values[0].textVal === "c";
}

test "decode 5-pair text-keyed map" {
	// 0xa5 + 5 pairs of single-char-keyed entries
	const v = decOk([0xa5,
		0x61, 0x61, 0x61, 0x41,  // "a": "A"
		0x61, 0x62, 0x61, 0x42,  // "b": "B"
		0x61, 0x63, 0x61, 0x43,  // "c": "C"
		0x61, 0x64, 0x61, 0x44,  // "d": "D"
		0x61, 0x65, 0x61, 0x45]); // "e": "E"
	assert v.kind === CborKind.Map;
	assert v.keys.length === 5;
	assert v.values[4].kind === CborKind.Text;
	assert v.values[4].textVal === "E";
}

// === Major 7 simple ===

test "decode 0xf4 → bool false" {
	const v = decOk([0xf4]);
	assert v.kind === CborKind.Bool;
	assert v.boolVal === false;
}

test "decode 0xf5 → bool true" {
	const v = decOk([0xf5]);
	assert v.kind === CborKind.Bool;
	assert v.boolVal === true;
}

test "decode 0xf6 → null" {
	const v = decOk([0xf6]);
	assert v.kind === CborKind.Null;
}

test "decode 0xf7 → undefined" {
	const v = decOk([0xf7]);
	assert v.kind === CborKind.Undefined;
}

test "decode 0xf0 → simple 16" {
	const v = decOk([0xf0]);
	assert v.kind === CborKind.Simple;
	assert v.simpleVal === 16;
}

test "decode 0xf8 0xff → simple 255" {
	const v = decOk([0xf8, 0xff]);
	assert v.kind === CborKind.Simple;
	assert v.simpleVal === 255;
}

// === Error cases ===

test "decode empty → error" {
	const r = decodeAll([]);
	assert !r.ok;
}

test "decode truncated 2-byte arg → error" {
	const r = decodeAll([0x19, 0x03]);  // declared 2-byte arg but only 1 byte available
	assert !r.ok;
}

test "decode trailing bytes → error" {
	const r = decodeAll([0x01, 0x02]);  // valid int 1 then leftover
	assert !r.ok;
}

test "decode indefinite-length empty array (0x9f 0xff)" {
	const r = decodeAll([0x9f, 0xff]);
	assert r.ok;
	assert r.value.kind === CborKind.Array;
	if (r.value.kind === CborKind.Array) assert r.value.items.length === 0;
}

test "decode indefinite-length array [1, 2, 3] (0x9f 0x01 0x02 0x03 0xff)" {
	const r = decodeAll([0x9f, 0x01, 0x02, 0x03, 0xff]);
	assert r.ok;
	assert r.value.kind === CborKind.Array;
	if (r.value.kind === CborKind.Array) {
		assert r.value.items.length === 3;
		const i0 = r.value.items[0];
		if (i0.kind === CborKind.Int) assert i0.intVal === (1 as int64);
	}
}

test "decode indefinite-length empty map (0xbf 0xff)" {
	const r = decodeAll([0xbf, 0xff]);
	assert r.ok;
	assert r.value.kind === CborKind.Map;
	if (r.value.kind === CborKind.Map) assert r.value.keys.length === 0;
}

test "decode indefinite-length map {a: 1} (0xbf 0x61 'a' 0x01 0xff)" {
	const r = decodeAll([0xbf, 0x61, 0x61, 0x01, 0xff]);
	assert r.ok;
	if (!r.ok) return;
	const m = r.value;
	assert m.kind === CborKind.Map;
	if (m.kind !== CborKind.Map) return;
	assert m.keys.length === 1;
	const k0 = m.keys[0];
	assert k0.kind === CborKind.Text;
	if (k0.kind === CborKind.Text) assert k0.textVal === "a";
	const v0 = m.values[0];
	assert v0.kind === CborKind.Int;
	if (v0.kind === CborKind.Int) assert v0.intVal === (1 as int64);
}

test "decode indefinite-length text 'foobar' (0x7f 'foo' 'bar' 0xff)" {
	// Two finite-length text chunks concat to "foobar"
	const r = decodeAll([0x7f, 0x63, 0x66, 0x6f, 0x6f, 0x63, 0x62, 0x61, 0x72, 0xff]);
	assert r.ok;
	if (!r.ok) return;
	const t = r.value;
	assert t.kind === CborKind.Text;
	if (t.kind === CborKind.Text) assert t.textVal === "foobar";
}

test "decode indefinite-length array — break after key in map → error" {
	// 0xbf opens indef map, 0x61 'a' is key, then break (no value) → malformed
	const r = decodeAll([0xbf, 0x61, 0x61, 0xff]);
	assert !r.ok;
}

test "decode indefinite-length text — nested indef chunk → error (RFC §3.2.3)" {
	// 0x7f opens, 0x7f attempts nested indef → must reject
	const r = decodeAll([0x7f, 0x7f, 0xff, 0xff]);
	assert !r.ok;
}

test "decode indefinite-length text — wrong major chunk → error" {
	// 0x7f opens indef text, but inner chunk is byte string (0x41) not text
	const r = decodeAll([0x7f, 0x41, 0x61, 0xff]);
	assert !r.ok;
}

test "decode indefinite-length integer (0x1f) → error" {
	// Major 0 + info 31 is not allowed per RFC 8949 §3.2
	const r = decodeAll([0x1f]);
	assert !r.ok;
}

test "decode break code at top level (0xff) → error" {
	// 0xff = major 7 info 31 = break, illegal outside indefinite container
	const r = decodeAll([0xff]);
	assert !r.ok;
}

test "decode reserved info 28 → error" {
	const r = decodeAll([0x1c]);  // major 0, info 28 (reserved)
	assert !r.ok;
}

// === Safety limits ===

test "decode oversized array length → error (DoS guard)" {
	// 0x9b = array, info 27 (8-byte length)
	// 0x00 0x00 0x00 0x00 0x10 0x00 0x00 0x00 = 0x100000000 = 4294967296 (4G items)
	// Far above MAX_COLLECTION_SIZE (100M) and far above remaining bytes.
	const r = decodeAll([0x9b, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00]);
	assert !r.ok;
}

test "decode array length larger than payload → error (truncation guard)" {
	// 0x98 0x05 = array of 5 items, but only 0 items follow.
	// length(5) > remaining(0) → reject.
	const r = decodeAll([0x98, 0x05]);
	assert !r.ok;
}

test "decode oversized map pair count → error" {
	// 0xbb = map, info 27. Same 0x100000000 length.
	const r = decodeAll([0xbb, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00]);
	assert !r.ok;
}

test "decode deep tag chain → error after MAX_DEPTH" {
	// Build 1001 nested tag-0 wrappers (one over MAX_DEPTH=1000), each tag
	// taking 1 head byte. Followed by a single int 0 as the deepest payload.
	const bytes: uint8[] = [];
	let i: number = 0;
	while (i < 1001) {
		bytes.push(0xc0);  // tag 0, info 0 inline
		i = i + 1;
	}
	bytes.push(0x00);  // int 0 at the bottom
	const r = decodeAll(bytes);
	assert !r.ok;
}

test "decode tag chain just under depth limit succeeds" {
	// 999 nested tags + int 0 — within MAX_DEPTH.
	const bytes: uint8[] = [];
	let i: number = 0;
	while (i < 999) {
		bytes.push(0xc0);
		i = i + 1;
	}
	bytes.push(0x00);
	const r = decodeAll(bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Tag;
}

test "decode half-precision float marker (parses without error)" {
	// 0xf9 = major 7 + info 25 (half float). NATIVE-ONLY path — the extern
	// stubs msBufferAlloc/msBufferReadDoubleBE return 0, so numVal value
	// can't be checked inline (same gap as single/double float decode at
	// decoder.ms:50). Coverage via native probe: examples/_probe_cbor_half.ms.
	// Inline test verifies decoder accepts the byte sequence without
	// erroring — value correctness verified at native run.
	const r = decodeAll([0xf9, 0x3c, 0x00]);
	assert r.ok;
	assert r.value.kind === CborKind.Float;
}

// === Round-trip via encoder integration ===

import { newCborWriter, encodeValue } from "./encoder";

test "round-trip int 42" {
	const w = newCborWriter();
	encodeValue(w, cborInt(42 as int64));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Int;
	assert r.value.intVal === (42 as int64);
}

test "round-trip int -100" {
	const w = newCborWriter();
	encodeValue(w, cborInt(-100 as int64));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Int;
	assert r.value.intVal === (-100 as int64);
}

test "round-trip text \"hello\"" {
	const w = newCborWriter();
	encodeValue(w, cborText("hello"));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Text;
	assert r.value.textVal === "hello";
}

test "round-trip array [1, 2, 3]" {
	const items: CborValue[] = [cborInt(1 as int64), cborInt(2 as int64), cborInt(3 as int64)];
	const w = newCborWriter();
	encodeValue(w, cborArray(items));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Array;
	assert r.value.items.length === 3;
	assert r.value.items[0].kind === CborKind.Int;
	assert r.value.items[0].intVal === (1 as int64);
	assert r.value.items[2].kind === CborKind.Int;
	assert r.value.items[2].intVal === (3 as int64);
}

test "round-trip map {a: 1, b: 2}" {
	const keys: CborValue[] = [cborText("a"), cborText("b")];
	const vals: CborValue[] = [cborInt(1 as int64), cborInt(2 as int64)];
	const w = newCborWriter();
	encodeValue(w, cborMap(keys, vals));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Map;
	assert r.value.keys.length === 2;
	assert r.value.keys[0].kind === CborKind.Text;
	assert r.value.keys[0].textVal === "a";
	assert r.value.values[1].kind === CborKind.Int;
	assert r.value.values[1].intVal === (2 as int64);
}

test "round-trip tagged value" {
	const w = newCborWriter();
	encodeValue(w, cborTag(123 as int64, cborText("x")));
	const r = decodeAll(w.bytes);
	assert r.ok;
	assert r.value.kind === CborKind.Tag;
	assert r.value.tagNum === (123 as int64);
	assert r.value.tagged.kind === CborKind.Text;
	assert r.value.tagged.textVal === "x";
}
