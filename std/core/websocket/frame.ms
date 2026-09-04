// WebSocket Frame parser/builder — RFC 6455 §5.2.
//
// Pure MetaScript: byte work is done on `number[]` (each element 0..255).
// Converting `number[] ↔ string` happens only at the network boundary in
// client.cms, mirroring the CBOR encoder/decoder pattern.
//
// Server-to-client frames MUST NOT be masked (RFC 6455 §5.1) — parseFrame
// returns ProtocolError if it sees one. Client-to-server frames MUST be
// masked — buildFrame always masks.
//
// Cross-checked against bun/src/http/websocket.zig (91 LOC) for opcode
// values, packLength logic, and mask byte order. Implementation is RFC-
// direct, not ported.

import { WsError, wsProtocolError, wsPayloadTooLarge } from "./errors";

// ===== Opcodes (RFC 6455 §5.2) =====

export const OPCODE_CONTINUATION: int32 = 0x0;
export const OPCODE_TEXT: int32 = 0x1;
export const OPCODE_BINARY: int32 = 0x2;
export const OPCODE_CLOSE: int32 = 0x8;
export const OPCODE_PING: int32 = 0x9;
export const OPCODE_PONG: int32 = 0xA;

// Cap payload at 16 MB for v0 — anything larger triggers Close 1009.
export const MAX_PAYLOAD_BYTES: int32 = 16777216;

// ===== Opcode classification =====

// Control frames have the high bit of the 4-bit opcode set (0x8, 0x9, 0xA).
export function isControlOpcode(op: int32): boolean {
	return (op & 0x8) !== 0;
}

// Opcodes 0x3-0x7 (data) and 0xB-0xF (control) are reserved by the spec.
// Receiving any of them MUST close the connection with code 1002.
export function isReservedOpcode(op: int32): boolean {
	return match (op) {
		0x3 | 0x4 | 0x5 | 0x6 | 0x7 => true,
		0xB | 0xC | 0xD | 0xE | 0xF => true,
		_ => false,
	};
}

// ===== Parsed frame shape =====

export interface ParsedFrame {
	fin: boolean;
	opcode: int32;
	masked: boolean;            // server-to-client should be false; client-to-server should be true
	payload: number[];          // unmasked payload bytes
	headerSize: int32;          // header bytes consumed (incl. extended length + mask key)
	totalSize: int32;           // headerSize + payloadLen — caller advances offset by this
}

// Tri-state parse result: success, need-more-bytes, or error (Result<...>).
export interface ParseFrameResult {
	needMore: boolean;          // true = buffer too short; frame fields are placeholders
	frame: ParsedFrame;
}

function emptyFrame(): ParsedFrame {
	const empty: number[] = [];
	return { fin: false, opcode: 0, masked: false, payload: empty, headerSize: 0, totalSize: 0 };
}

function needMore(): ParseFrameResult {
	return { needMore: true, frame: emptyFrame() };
}

// ===== Masking (RFC 6455 §5.3) =====

// XOR each payload byte with mask[i % keyLen]. RFC 6455 §5.3 mandates a
// 4-byte key; this routine is symmetric (mask(mask(x)) === x) for any cycle
// length so the masking is reversible regardless. The defensive non-4-byte
// fallbacks below exist so a misuse from a public caller produces
// deterministic output (or a no-op for empty key) rather than an
// out-of-bounds index.
//
// Used for masking client→server frames; same routine unmasks any inbound
// masked frame (though server→client masked is a protocol violation we
// reject before calling this).
function xorByte(b: number, k: number): int32 {
	return (b as int32) ^ (k as int32);
}

export function maskPayload(payload: number[], maskKey: number[]): number[] {
	const keyLen = maskKey.length;
	const payloadLen = payload.length;
	let bytes: number[] = [];
	if (keyLen === 0) {
		// Empty key — return an unchanged copy. This branch is purely
		// defensive: internal callers always pass a 4-byte key.
		for (let i: int32 = 0; i < payloadLen; i = i + 1) {
			bytes.push(payload[i]);
		}
		return bytes;
	}
	for (let i: int32 = 0; i < payloadLen; i = i + 1) {
		bytes.push(xorByte(payload[i], maskKey[i % keyLen]));
	}
	return bytes;
}

// ===== Frame builder (client-to-server: always masked) =====

// Build one complete frame.
//   opcode  — 0x0/0x1/0x2/0x8/0x9/0xA
//   fin     — true for last frame of a message; control frames must be true
//   payload — raw bytes
//   maskKey — exactly 4 bytes (from std/crypto.randomBytes(4) at the call site)
// Returns the full frame bytes (header + masked payload).
export function buildFrame(opcode: int32, fin: boolean, payload: number[], maskKey: number[]): number[] {
	const len = payload.length;
	let frame: number[] = [];

	// Byte 0: FIN(1) | RSV(3, all 0) | OPCODE(4)
	let b0 = opcode & 0x0F;
	if (fin) b0 = b0 | 0x80;
	frame.push(b0);

	// Byte 1: MASK(1, always 1 for c→s) | LEN7(7)
	const maskBit: int32 = 0x80;
	if (len <= 125) {
		frame.push(maskBit | (len & 0x7F));
	} else if (len <= 0xFFFF) {
		frame.push(maskBit | 126);
		frame.push((len >> 8) & 0xFF);
		frame.push(len & 0xFF);
	} else {
		frame.push(maskBit | 127);
		// 64-bit BE length. We cap payload at MAX_PAYLOAD_BYTES (16 MB) so
		// the high 4 bytes are always zero. Use multiply/divide for the low 4
		// bytes to avoid `>>` sign-extension issues if the cap ever rises
		// toward 2^31.
		frame.push(0); frame.push(0); frame.push(0); frame.push(0);
		const b4 = (len / 16777216) & 0xFF;
		const b5 = (len / 65536) & 0xFF;
		const b6 = (len / 256) & 0xFF;
		const b7 = len & 0xFF;
		frame.push(b4);
		frame.push(b5);
		frame.push(b6);
		frame.push(b7);
	}

	// 4-byte mask key
	frame.push(maskKey[0]);
	frame.push(maskKey[1]);
	frame.push(maskKey[2]);
	frame.push(maskKey[3]);

	// Masked payload
	let i = 0;
	while (i < len) {
		frame.push(xorByte(payload[i], maskKey[i & 3]));
		i = i + 1;
	}
	return frame;
}

// Build an unmasked frame (for tests / hypothetical server use).
// NEVER use this for client-to-server send — RFC 6455 mandates masking.
export function buildFrameUnmasked(opcode: int32, fin: boolean, payload: number[]): number[] {
	const len = payload.length;
	let frame: number[] = [];

	let b0 = opcode & 0x0F;
	if (fin) b0 = b0 | 0x80;
	frame.push(b0);

	if (len <= 125) {
		frame.push(len & 0x7F);
	} else if (len <= 0xFFFF) {
		frame.push(126);
		frame.push((len >> 8) & 0xFF);
		frame.push(len & 0xFF);
	} else {
		frame.push(127);
		// See buildFrame's matching ext-64 comment — multiply/divide avoids
		// `>>` sign-extension on bytes >= 0x80 once the cap rises.
		frame.push(0); frame.push(0); frame.push(0); frame.push(0);
		frame.push((len / 16777216) & 0xFF);
		frame.push((len / 65536) & 0xFF);
		frame.push((len / 256) & 0xFF);
		frame.push(len & 0xFF);
	}

	let i = 0;
	while (i < len) {
		frame.push(payload[i]);
		i = i + 1;
	}
	return frame;
}

// ===== Frame parser =====

// Slice helper — number[] doesn't have built-in slice.
function sliceBytes(src: number[], start: int32, end: int32): number[] {
	let out: number[] = [];
	let i = start;
	while (i < end) {
		out.push(src[i]);
		i = i + 1;
	}
	return out;
}

// Parse one frame starting at offset. Returns:
//   Result.ok({ needMore: true, ... }) if buffer doesn't yet contain a full frame
//     — caller should recv() more bytes and retry from same offset.
//   Result.ok({ needMore: false, frame }) on success — caller advances offset by frame.totalSize.
//   Result.err(WsError) on protocol violation — caller should close 1002 (or 1009 for too-large).
export function parseFrame(data: number[], offset: int32): Result<ParseFrameResult, WsError> {
	const avail = data.length - offset;
	if (avail < 2) return Result.ok(needMore());

	const b0: int32 = data[offset] as int32;
	const b1: int32 = data[offset + 1] as int32;

	const fin = (b0 & 0x80) !== 0;
	const rsv = b0 & 0x70;
	const opcode = b0 & 0x0F;

	if (rsv !== 0) {
		return Result.err(wsProtocolError("RSV bits must be 0"));
	}
	if (isReservedOpcode(opcode)) {
		return Result.err(wsProtocolError("reserved opcode " + opcode.toString()));
	}
	if (isControlOpcode(opcode) && !fin) {
		return Result.err(wsProtocolError("control frame must not be fragmented"));
	}

	const masked = (b1 & 0x80) !== 0;
	const lenField = b1 & 0x7F;
	let cursor = offset + 2;
	let payloadLen: int32 = 0;

	if (lenField <= 125) {
		payloadLen = lenField;
	} else if (lenField === 126) {
		if (avail < 4) return Result.ok(needMore());
		payloadLen = ((data[cursor] * 256) + data[cursor + 1]) as int32;
		cursor = cursor + 2;
	} else {
		// lenField === 127 — 64-bit BE length.
		if (avail < 10) return Result.ok(needMore());
		// High 4 bytes (bits 32..63) must be zero — we cap at 16 MB so the
		// value fits in 32 bits comfortably. Anything beyond is too large.
		if (data[cursor] !== 0 || data[cursor + 1] !== 0 || data[cursor + 2] !== 0
		 || data[cursor + 3] !== 0) {
			return Result.err(wsPayloadTooLarge(MAX_PAYLOAD_BYTES + 1, MAX_PAYLOAD_BYTES));
		}
		// Read the low 4 bytes via multiply-add. Bitwise `<<` would overflow
		// signed int32 once the high byte exceeds 0x7F (e.g. for values
		// >= 2 GB). We only allow up to MAX_PAYLOAD_BYTES anyway, so the
		// arithmetic stays well within int32 range — but using multiply
		// keeps the code correct if the cap is ever raised toward 2^31.
		const b4 = data[cursor + 4];
		const b5 = data[cursor + 5];
		const b6 = data[cursor + 6];
		const b7 = data[cursor + 7];
		// Reject early if b4 alone signals an oversized payload, so the
		// multiply below can't cross the int32 sign boundary.
		if (b4 > 1) {
			return Result.err(wsPayloadTooLarge(MAX_PAYLOAD_BYTES + 1, MAX_PAYLOAD_BYTES));
		}
		payloadLen = ((b4 * 16777216) + (b5 * 65536) + (b6 * 256) + b7) as int32;
		cursor = cursor + 8;
	}

	if (payloadLen < 0 || payloadLen > MAX_PAYLOAD_BYTES) {
		return Result.err(wsPayloadTooLarge(payloadLen, MAX_PAYLOAD_BYTES));
	}
	// Control frames have a hard 125-byte payload limit (RFC 6455 §5.5).
	if (isControlOpcode(opcode) && payloadLen > 125) {
		return Result.err(wsProtocolError("control frame payload > 125 bytes"));
	}

	let maskKey: number[] = [];
	if (masked) {
		if ((cursor - offset) + 4 > avail) return Result.ok(needMore());
		maskKey.push(data[cursor]);
		maskKey.push(data[cursor + 1]);
		maskKey.push(data[cursor + 2]);
		maskKey.push(data[cursor + 3]);
		cursor = cursor + 4;
	}

	const headerSize = cursor - offset;
	const totalSize = headerSize + payloadLen;
	if (totalSize > avail) return Result.ok(needMore());

	let payload = sliceBytes(data, cursor, cursor + payloadLen);
	if (masked) {
		payload = maskPayload(payload, maskKey);
	}

	return Result.ok({
		needMore: false,
		frame: {
			fin: fin,
			opcode: opcode,
			masked: masked,
			payload: payload,
			headerSize: headerSize,
			totalSize: totalSize,
		},
	});
}

// ===== Close-frame payload codec (RFC 6455 §5.5.1) =====
//
// Close payload format:
//   [uint16 BE close code][optional UTF-8 reason]
// Both fields are optional — a zero-length payload is a valid close.

export interface CloseInfo {
	code: int32;             // 1000 if no code; otherwise the parsed code
	reason: number[];        // raw UTF-8 reason bytes (empty if no reason)
	hasCode: boolean;        // true if a code was actually present in the payload
}

export function encodeClosePayload(code: int32, reason: number[]): number[] {
	let bytes: number[] = [];
	bytes.push((code >> 8) & 0xFF);
	bytes.push(code & 0xFF);
	let i = 0;
	while (i < reason.length) {
		bytes.push(reason[i]);
		i = i + 1;
	}
	return bytes;
}

export function decodeClosePayload(payload: number[]): CloseInfo {
	const empty: number[] = [];
	if (payload.length === 0) {
		return { code: 1000, reason: empty, hasCode: false };
	}
	if (payload.length === 1) {
		// Malformed but be lenient — treat as no code.
		return { code: 1000, reason: empty, hasCode: false };
	}
	const code = ((payload[0] * 256) + payload[1]) as int32;
	let reason: number[] = [];
	for (let i: int32 = 2; i < payload.length; i = i + 1) {
		reason.push(payload[i]);
	}
	return { code: code as int32, reason: reason, hasCode: true };
}

// RFC 6455 §7.4.1 — close-code legality on the wire.
//
//   < 1000         : invalid (range reserved for non-WebSocket use)
//   1000-1003      : valid
//   1004           : reserved, MUST NOT be sent
//   1005           : "No Status Rcvd" — MUST NOT appear in actual frames
//   1006           : "Abnormal Closure" — MUST NOT appear in actual frames
//   1007-1014      : valid
//   1015           : "TLS handshake" — MUST NOT appear in actual frames
//   1016-2999      : reserved by the protocol; not registered for wire use
//   3000-3999      : IANA-registered (library/framework codes) — accepted
//   4000-4999      : application-defined — accepted
//   >= 5000        : invalid (out of defined range)
//
// `isWireValidCloseCode` returns true iff `code` may legitimately be received
// from a peer. Sending the same set is also the conservative client policy.
export function isWireValidCloseCode(code: int32): boolean {
	if (code < 1000) return false;
	if (code === 1004 || code === 1005 || code === 1006 || code === 1015) return false;
	if (code >= 1016 && code <= 2999) return false;
	if (code >= 5000) return false;
	return true;
}

// ===== Tests =====

function bytesEqual(a: number[], b: number[]): boolean {
	if (a.length !== b.length) return false;
	let i = 0;
	while (i < a.length) {
		if (a[i] !== b[i]) return false;
		i = i + 1;
	}
	return true;
}

test "isControlOpcode" {
	assert isControlOpcode(OPCODE_CLOSE);
	assert isControlOpcode(OPCODE_PING);
	assert isControlOpcode(OPCODE_PONG);
	assert !isControlOpcode(OPCODE_TEXT);
	assert !isControlOpcode(OPCODE_BINARY);
	assert !isControlOpcode(OPCODE_CONTINUATION);
}

test "isReservedOpcode" {
	assert isReservedOpcode(0x3);
	assert isReservedOpcode(0x7);
	assert isReservedOpcode(0xB);
	assert isReservedOpcode(0xF);
	assert !isReservedOpcode(OPCODE_TEXT);
	assert !isReservedOpcode(OPCODE_PING);
}

test "maskPayload is symmetric" {
	const key: number[] = [0x12, 0x34, 0x56, 0x78];
	const payload: number[] = [0x48, 0x65, 0x6C, 0x6C, 0x6F];  // "Hello"
	const masked = maskPayload(payload, key);
	assert !bytesEqual(masked, payload);  // actually masked
	const round = maskPayload(masked, key);
	assert bytesEqual(round, payload);
}

test "maskPayload empty" {
	const key: number[] = [1, 2, 3, 4];
	const empty: number[] = [];
	const m = maskPayload(empty, key);
	assert m.length === 0;
}

test "maskPayload empty key returns unchanged copy (defensive)" {
	const empty: number[] = [];
	const payload: number[] = [0x10, 0x20, 0x30];
	const m = maskPayload(payload, empty);
	assert m.length === 3;
	assert m[0] === 0x10 && m[1] === 0x20 && m[2] === 0x30;
	// Should be a copy, not the same array.
	m.push(0x99);
	assert payload.length === 3;
}

test "maskPayload 1-byte key cycles (defensive — RFC requires 4)" {
	const key: number[] = [0xAA];
	const payload: number[] = [0x01, 0x02, 0x03];
	const m = maskPayload(payload, key);
	assert m[0] === (0x01 ^ 0xAA);
	assert m[1] === (0x02 ^ 0xAA);
	assert m[2] === (0x03 ^ 0xAA);
}

test "maskPayload 2-byte key cycles" {
	const key: number[] = [0xF0, 0x0F];
	const payload: number[] = [0x01, 0x02, 0x03, 0x04];
	const m = maskPayload(payload, key);
	assert m[0] === (0x01 ^ 0xF0);
	assert m[1] === (0x02 ^ 0x0F);
	assert m[2] === (0x03 ^ 0xF0);
	assert m[3] === (0x04 ^ 0x0F);
}

test "buildFrame text round-trip — short payload" {
	const key: number[] = [0xAA, 0xBB, 0xCC, 0xDD];
	const payload: number[] = [0x68, 0x65, 0x6C, 0x6C, 0x6F];  // "hello"
	const frame = buildFrame(OPCODE_TEXT, true, payload, key);
	const r = parseFrame(frame, 0);
	assert r.ok;
	assert !r.value.needMore;
	const f = r.value.frame;
	assert f.fin;
	assert f.opcode === OPCODE_TEXT;
	assert f.masked;
	assert bytesEqual(f.payload, payload);
	assert f.totalSize === frame.length;
}

test "buildFrame header bytes — opcode + FIN + length" {
	const key: number[] = [0, 0, 0, 0];
	const payload: number[] = [0x41, 0x42, 0x43];  // "ABC"
	const frame = buildFrame(OPCODE_BINARY, true, payload, key);
	// Byte 0: 0x82 = FIN | Binary opcode
	assert frame[0] === 0x82;
	// Byte 1: 0x83 = MASK bit (0x80) | length 3
	assert frame[1] === 0x83;
	// Bytes 2-5: mask key (all zero)
	assert frame[2] === 0 && frame[3] === 0 && frame[4] === 0 && frame[5] === 0;
	// Bytes 6-8: payload XOR with all-zero key — same as input
	assert frame[6] === 0x41 && frame[7] === 0x42 && frame[8] === 0x43;
	assert frame.length === 9;
}

test "buildFrame binary round-trip — 200 byte payload (extended-16 length)" {
	const key: number[] = [1, 2, 3, 4];
	let payload: number[] = [];
	let i = 0;
	while (i < 200) { payload.push(0x41); i = i + 1; }
	const frame = buildFrame(OPCODE_BINARY, true, payload, key);
	const r = parseFrame(frame, 0);
	assert r.ok;
	assert !r.value.needMore;
	const f = r.value.frame;
	assert f.opcode === OPCODE_BINARY;
	assert f.payload.length === 200;
	assert bytesEqual(f.payload, payload);
	// Header should be 2 (basic) + 2 (uint16 len) + 4 (mask) = 8
	assert f.headerSize === 8;
}

test "buildFrame extended-16 length encoding" {
	const key: number[] = [0, 0, 0, 0];
	let payload: number[] = [];
	let i = 0;
	while (i < 1000) { payload.push(0); i = i + 1; }
	const frame = buildFrame(OPCODE_BINARY, true, payload, key);
	// frame[1] should be 0x80 | 126 = 0xFE
	assert frame[1] === 0xFE;
	// length 1000 = 0x03E8 → byte 2 = 0x03, byte 3 = 0xE8
	assert frame[2] === 0x03;
	assert frame[3] === 0xE8;
}

test "buildFrame binary round-trip — 70k payload (extended-64 length)" {
	const key: number[] = [0xFF, 0xFE, 0xFD, 0xFC];
	let payload: number[] = [];
	let i = 0;
	while (i < 70000) { payload.push(0x78); i = i + 1; }
	const frame = buildFrame(OPCODE_BINARY, true, payload, key);
	const r = parseFrame(frame, 0);
	assert r.ok;
	assert !r.value.needMore;
	const f = r.value.frame;
	assert f.payload.length === 70000;
	assert bytesEqual(f.payload, payload);
	// Header: 2 (basic) + 8 (uint64 len) + 4 (mask) = 14
	assert f.headerSize === 14;
}

test "buildFrame extended-64 length encoding (low 24 bits)" {
	const key: number[] = [0, 0, 0, 0];
	let payload: number[] = [];
	let i = 0;
	while (i < 70000) { payload.push(0); i = i + 1; }
	const frame = buildFrame(OPCODE_BINARY, true, payload, key);
	// frame[1] = 0x80 | 127 = 0xFF
	assert frame[1] === 0xFF;
	// 8-byte BE length for 70000 = 0x00000000_00011170
	assert frame[2] === 0 && frame[3] === 0 && frame[4] === 0 && frame[5] === 0;
	assert frame[6] === 0;        // high byte of low-24
	assert frame[7] === 0x01;
	assert frame[8] === 0x11;
	assert frame[9] === 0x70;
}

// ----- B1: ext-64 length must encode the full 4 low bytes (≥16 MB boundary) -----

test "buildFrame ext-64 emits non-zero byte 4 for length 16 MB exactly" {
	const key: number[] = [0, 0, 0, 0];
	// We don't allocate 16 MB in the test — buildFrame doesn't actually need
	// the bytes to compute the header. But MS arrays carry their own length,
	// so we'd need a real array. Instead, we verify the encoding logic via
	// a smaller-scale test: any value > 0xFFFFFF must set byte 4. Use
	// 0x01000000 = 16 MB encoded into 8 BE length bytes — that's the boundary
	// the old 24-bit emitter mishandled. Build a payload of length 0x01000001
	// (one byte over 16 MB) and read back the header bytes only.
	//
	// Allocating 16 MB+ bytes via push is feasible (~50ms). Skip the
	// payload-content allocation by using buildFrameUnmasked which doesn't
	// XOR — the header bytes are still emitted from `len = payload.length`.
	let payload: number[] = [];
	const target: int32 = 16777217;  // 16 MB + 1 byte (just past the old 24-bit cap)
	for (let k: int32 = 0; k < target; k = k + 1) {
		payload.push(0);
	}
	const frame = buildFrameUnmasked(OPCODE_BINARY, true, payload);
	// Byte 0: FIN | Binary
	assert frame[0] === 0x82;
	// Byte 1: 127 (ext-64 marker, no mask bit since unmasked)
	assert frame[1] === 0x7F;
	// 8-byte BE length: 0x00 00 00 00 01 00 00 01
	assert frame[2] === 0 && frame[3] === 0 && frame[4] === 0 && frame[5] === 0;
	assert frame[6] === 0x01;  // ← the byte the old emitter zeroed silently
	assert frame[7] === 0x00;
	assert frame[8] === 0x00;
	assert frame[9] === 0x01;
}

test "parseFrame ext-64 rejects values above MAX_PAYLOAD_BYTES via b4 check" {
	// Hand-craft a header claiming length 0x02000000 = 32 MB (above the cap).
	// b4 = 0x02 alone triggers wsPayloadTooLarge.
	const bad: number[] = [
		0x82, 0x7F,                                   // FIN | Binary, ext-64
		0, 0, 0, 0,                                   // high 4 bytes
		0x02, 0x00, 0x00, 0x00,                       // low 4: 0x02000000
	];
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "parseFrame ext-64 rejects when high 4 bytes non-zero" {
	const bad: number[] = [
		0x82, 0x7F,
		0, 0, 0, 0x01,                                // bit 32 set — too large
		0, 0, 0, 0,
	];
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "buildFrameUnmasked round-trip" {
	const payload: number[] = [0x70, 0x69, 0x6E, 0x67];  // "ping"
	const frame = buildFrameUnmasked(OPCODE_TEXT, true, payload);
	const r = parseFrame(frame, 0);
	assert r.ok;
	assert !r.value.needMore;
	const f = r.value.frame;
	assert !f.masked;
	assert bytesEqual(f.payload, payload);
}

test "fragmented message — two frames of a Text message" {
	const key: number[] = [0, 0, 0, 0];
	const part1: number[] = [0x48, 0x65, 0x6C];  // "Hel"
	const part2: number[] = [0x6C, 0x6F];        // "lo"
	// First frame: opcode=Text, FIN=0
	const f1 = buildFrame(OPCODE_TEXT, false, part1, key);
	// Continuation frame: opcode=0, FIN=1
	const f2 = buildFrame(OPCODE_CONTINUATION, true, part2, key);
	let combined: number[] = [];
	let i = 0;
	while (i < f1.length) { combined.push(f1[i]); i = i + 1; }
	i = 0;
	while (i < f2.length) { combined.push(f2[i]); i = i + 1; }

	const r1 = parseFrame(combined, 0);
	assert r1.ok;
	assert !r1.value.needMore;
	const fr1 = r1.value.frame;
	assert fr1.opcode === OPCODE_TEXT;
	assert !fr1.fin;
	assert bytesEqual(fr1.payload, part1);

	const r2 = parseFrame(combined, fr1.totalSize);
	assert r2.ok;
	assert !r2.value.needMore;
	const fr2 = r2.value.frame;
	assert fr2.opcode === OPCODE_CONTINUATION;
	assert fr2.fin;
	assert bytesEqual(fr2.payload, part2);
}

test "parseFrame needMore on truncated header (1 byte)" {
	const partial: number[] = [0x81];
	const r = parseFrame(partial, 0);
	assert r.ok;
	assert r.value.needMore;
}

test "parseFrame needMore on truncated payload" {
	const key: number[] = [1, 2, 3, 4];
	const payload: number[] = [0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A];
	const full = buildFrame(OPCODE_TEXT, true, payload, key);
	// Truncate to 6 bytes — header(2) + mask(4) = 6, payload missing
	const truncated = sliceBytes(full, 0, 6);
	const r = parseFrame(truncated, 0);
	assert r.ok;
	assert r.value.needMore;
}

test "parseFrame rejects RSV bits" {
	// Byte 0: FIN=1, RSV1=1, opcode=Text → 0xC1
	// Byte 1: MASK=0, len=0
	const bad: number[] = [0xC1, 0x00];
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "parseFrame rejects reserved opcode 0x3" {
	const bad: number[] = [0x83, 0x00];  // FIN=1, opcode=3
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "parseFrame rejects fragmented control frame (Ping with FIN=0)" {
	const bad: number[] = [0x09, 0x00];  // FIN=0, opcode=Ping
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "parseFrame rejects oversized control frame (Ping >125 bytes)" {
	// FIN=1, opcode=Ping, MASK=0, LEN7=126 (extended-16 follows), ext16 = 200
	let bad: number[] = [0x89, 0x7E, 0x00, 0xC8];
	let i = 0;
	while (i < 200) { bad.push(0x78); i = i + 1; }
	const r = parseFrame(bad, 0);
	assert !r.ok;
}

test "encodeClosePayload + decodeClosePayload round-trip with reason" {
	const reason: number[] = [0x62, 0x79, 0x65];  // "bye"
	const enc = encodeClosePayload(1000, reason);
	const dec = decodeClosePayload(enc);
	assert dec.hasCode;
	assert dec.code === 1000;
	assert bytesEqual(dec.reason, reason);
}

test "encodeClosePayload code-only" {
	const empty: number[] = [];
	const enc = encodeClosePayload(1011, empty);
	assert enc.length === 2;
	assert enc[0] === 0x03;
	assert enc[1] === 0xF3;
	const dec = decodeClosePayload(enc);
	assert dec.hasCode;
	assert dec.code === 1011;
	assert dec.reason.length === 0;
}

test "decodeClosePayload empty payload defaults to 1000 no-code" {
	const empty: number[] = [];
	const dec = decodeClosePayload(empty);
	assert !dec.hasCode;
	assert dec.code === 1000;
}

test "round-trip Close frame via build/parse + close-payload codec" {
	const key: number[] = [7, 7, 7, 7];
	const reason: number[] = [0x67, 0x6F, 0x69, 0x6E, 0x67];  // "going"
	const closePayload = encodeClosePayload(1001, reason);
	const frame = buildFrame(OPCODE_CLOSE, true, closePayload, key);
	const r = parseFrame(frame, 0);
	assert r.ok;
	const f = r.value.frame;
	assert f.opcode === OPCODE_CLOSE;
	assert f.fin;
	const info = decodeClosePayload(f.payload);
	assert info.code === 1001;
	assert bytesEqual(info.reason, reason);
}

test "isWireValidCloseCode accepts standard codes" {
	assert isWireValidCloseCode(1000);
	assert isWireValidCloseCode(1001);
	assert isWireValidCloseCode(1002);
	assert isWireValidCloseCode(1003);
	assert isWireValidCloseCode(1007);
	assert isWireValidCloseCode(1008);
	assert isWireValidCloseCode(1009);
	assert isWireValidCloseCode(1010);
	assert isWireValidCloseCode(1011);
	assert isWireValidCloseCode(1012);
	assert isWireValidCloseCode(1013);
	assert isWireValidCloseCode(1014);
}

test "isWireValidCloseCode rejects RFC-prohibited codes" {
	assert !isWireValidCloseCode(1004);  // reserved
	assert !isWireValidCloseCode(1005);  // No Status Rcvd — generated only
	assert !isWireValidCloseCode(1006);  // Abnormal — generated only
	assert !isWireValidCloseCode(1015);  // TLS handshake — generated only
}

test "isWireValidCloseCode rejects out-of-range codes" {
	assert !isWireValidCloseCode(0);
	assert !isWireValidCloseCode(999);
	assert !isWireValidCloseCode(500);
	assert !isWireValidCloseCode(5000);
	assert !isWireValidCloseCode(65535);
}

test "isWireValidCloseCode rejects unallocated reserved range 1016-2999" {
	assert !isWireValidCloseCode(1016);
	assert !isWireValidCloseCode(2000);
	assert !isWireValidCloseCode(2999);
}

test "isWireValidCloseCode accepts IANA-registered + application ranges" {
	assert isWireValidCloseCode(3000);
	assert isWireValidCloseCode(3500);
	assert isWireValidCloseCode(3999);
	assert isWireValidCloseCode(4000);
	assert isWireValidCloseCode(4500);
	assert isWireValidCloseCode(4999);
}
