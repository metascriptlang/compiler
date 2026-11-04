/**
 * The TLS record layer (RFC 8446 5): plaintext records, protected TLS 1.3
 * records (sequence-number nonce, inner content type, padding), protected
 * TLS 1.2 AEAD records (RFC 5246 6.2.3.3: explicit-nonce GCM per RFC 5288,
 * ChaCha20-Poly1305 per RFC 7905) and a buffer that cuts a byte stream
 * into whole records.
 */

import { CipherSuite, AeadKey, newAeadKey, aeadSealAt, aeadOpenAt, aeadTagLength, aeadNonceLength } from "./aead";
import { hkdfExpandLabel } from "./keySchedule";
import { wipeBytes } from "../pure/secret";

export const recordHeaderLength: int32 = 5;
export const maxPlaintextLength: int32 = 1 << 14;
export const maxCiphertextLength: int32 = (1 << 14) + 256;

export const contentChangeCipherSpec: int32 = 20;
export const contentAlert: int32 = 21;
export const contentHandshake: int32 = 22;
export const contentApplicationData: int32 = 23;

/** One direction's traffic secret, its key and IV, and the sequence number of its next record. */
export class TrafficKeys {
	suite: CipherSuite;
	secret: uint8[];
	key: AeadKey;
	iv: uint8[];
	sequence: uint64;
	/** TLS 1.2 record protection: the outer type is the real one and the AAD carries the sequence number. */
	tls12: boolean;
}

/** The sequence number no record may use: one more would wrap to 0 and repeat a nonce under the same key. */
export const exhaustedSequence: uint64 = 0xffffffffffffffff;

function onDestroy(this keys: TrafficKeys): void {
	wipeBytes(keys.secret);
	wipeBytes(keys.iv);
}

/** The key and IV of a traffic secret (RFC 8446 7.3), sequence number 0. */
export function trafficKeysOf(suite: CipherSuite, secret: Readonly<uint8[]>): TrafficKeys {
	const kind = suite.hashKind;
	const key = hkdfExpandLabel(kind, secret, "key", [], suite.keyLength);
	const keys: TrafficKeys = {
		suite,
		secret: [...secret],
		key: newAeadKey(suite.code, key),
		iv: hkdfExpandLabel(kind, secret, "iv", [], aeadNonceLength),
		sequence: 0,
		tls12: false,
	};
	wipeBytes(key);
	return keys;
}

/** TLS 1.2 keys from the key block: a 4-byte GCM salt with an explicit 8-byte nonce per record, or a 12-byte ChaCha20-Poly1305 IV. */
export function tls12TrafficKeysOf(suite: CipherSuite, key: Readonly<uint8[]>, fixedIv: Readonly<uint8[]>): TrafficKeys {
	return { suite, secret: [], key: newAeadKey(suite.code, key), iv: [...fixedIv], sequence: 0, tls12: true };
}

/** Bytes of nonce a TLS 1.2 record carries before its cipher text: 8 for GCM, 0 for ChaCha20-Poly1305. */
function explicitNonceLength(keys: TrafficKeys): int32 {
	return aeadNonceLength - (keys.iv.length as int32);
}

function sequenceOctets(sequence: uint64): uint8[] {
	return recordNonce(new Array<uint8>(aeadNonceLength), sequence).slice(4);
}

/** RFC 5246 6.2.3.3: seq_num + type + version + length of the plain text. */
function tls12AdditionalData(sequence: uint64, contentType: int32, length: int32): uint8[] {
	const out = sequenceOctets(sequence);
	out.push(contentType as uint8);
	out.push(0x03);
	out.push(0x03);
	out.push(((length >> 8) & 255) as uint8);
	out.push((length & 255) as uint8);
	return out;
}

function tls12Nonce(keys: TrafficKeys, explicit: Readonly<uint8[]>): uint8[] {
	if (explicit.length == 0) return recordNonce(keys.iv, keys.sequence);
	const nonce: uint8[] = [...keys.iv];
	for (let i = 0; i < explicit.length; i++) nonce.push(explicit[i]);
	return nonce;
}

/** The next generation's keys (RFC 8446 7.2, "traffic upd"). */
export function updatedTrafficKeys(keys: TrafficKeys): TrafficKeys {
	const kind = keys.suite.hashKind;
	const next = hkdfExpandLabel(kind, keys.secret, "traffic upd", [], keys.secret.length as int32);
	const updated = trafficKeysOf(keys.suite, next);
	wipeBytes(next);
	return updated;
}

/** The per-record nonce: the IV xored with the big-endian sequence number in its last 8 bytes. */
export function recordNonce(iv: Readonly<uint8[]>, sequence: uint64): uint8[] {
	const nonce: uint8[] = [...iv];
	for (let i = 0; i < 8; i++) {
		const octet = ((sequence >> ((8 * (7 - i)) as uint64)) & 255) as uint8;
		nonce[4 + i] = nonce[4 + i] ^ octet;
	}
	return nonce;
}

export function recordHeader(contentType: int32, length: int32): uint8[] {
	return [
		contentType as uint8,
		0x03,
		0x03,
		((length >> 8) & 255) as uint8,
		(length & 255) as uint8,
	];
}

/** Plaintext records of `data`, cut at the 2^14 fragment limit; `legacyVersion` is 0x0301 for a first ClientHello. */
export function plaintextRecords(
	contentType: int32,
	data: Readonly<uint8[]>,
	legacyVersion: int32,
): uint8[] {
	const out: uint8[] = [];
	let at = 0;
	while (at < data.length) {
		const take = Math.min(data.length - at, maxPlaintextLength) as int32;
		out.push(contentType as uint8);
		out.push(((legacyVersion >> 8) & 255) as uint8);
		out.push((legacyVersion & 255) as uint8);
		out.push(((take >> 8) & 255) as uint8);
		out.push((take & 255) as uint8);
		for (let i = 0; i < take; i++) out.push(data[at + i]);
		at += take;
	}
	return out;
}

export enum RecordFailure {
	BadRecordMac,
	RecordOverflow,
	DecodeError,
	/** The sequence number reached `exhaustedSequence`; the connection must end (or rekey) before another record. */
	SequenceExhausted,
}

function copyRange(out: uint8[], at: int32, data: Readonly<uint8[]>, from: int32, to: int32): void {
	for (let i = from; i < to; i++) out[at + i - from] = data[i];
}

function putHeader(out: uint8[], at: int32, contentType: int32, length: int32): void {
	out[at] = contentType as uint8;
	out[at + 1] = 0x03;
	out[at + 2] = 0x03;
	out[at + 3] = ((length >> 8) & 255) as uint8;
	out[at + 4] = (length & 255) as uint8;
}

/** Bytes of the protected record of `length` bytes of content, header included. */
function sealedLength(keys: TrafficKeys, length: int32): int32 {
	const body = keys.tls12 ? explicitNonceLength(keys) + length : length + 1;
	return recordHeaderLength + body + aeadTagLength;
}

/**
 * Writes the protected record of `data[from, to)` as `contentType` to `out` from `at`, sealing in place, and
 * advances the sequence number; returns the end of the record.
 */
function sealInto(keys: TrafficKeys, contentType: int32, data: Readonly<uint8[]>, from: int32, to: int32, out: uint8[], at: int32): int32 {
	const length = to - from;
	const total = sealedLength(keys, length);
	const bodyAt = at + recordHeaderLength;
	if (keys.tls12) {
		// The explicit nonce is the sequence number, which never repeats under one key.
		const explicitLength = explicitNonceLength(keys);
		const explicit = explicitLength > 0 ? sequenceOctets(keys.sequence) : [];
		putHeader(out, at, contentType, total - recordHeaderLength);
		copyRange(out, bodyAt, explicit, 0, explicitLength);
		copyRange(out, bodyAt + explicitLength, data, from, to);
		const aad = tls12AdditionalData(keys.sequence, contentType, length);
		aeadSealAt(keys.key, tls12Nonce(keys, explicit), aad, out, bodyAt + explicitLength, length);
	} else {
		putHeader(out, at, contentApplicationData, total - recordHeaderLength);
		copyRange(out, bodyAt, data, from, to);
		out[bodyAt + length] = contentType as uint8;
		const header = out.slice(at, bodyAt);
		aeadSealAt(keys.key, recordNonce(keys.iv, keys.sequence), header, out, bodyAt, length + 1);
	}
	keys.sequence = keys.sequence + 1;
	return at + total;
}

/** One protected record holding `data[from, to)` as `contentType`; advances the sequence number. */
export function sealRecord(
	keys: TrafficKeys,
	contentType: int32,
	data: Readonly<uint8[]>,
	from: int32,
	to: int32,
): Result<uint8[], RecordFailure> {
	if (keys.sequence == exhaustedSequence) return Result.err(RecordFailure.SequenceExhausted);
	const out = new Array<uint8>(sealedLength(keys, to - from));
	sealInto(keys, contentType, data, from, to, out, 0);
	return Result.ok(out);
}

/** Protected records of all of `data`, each at most 2^14 bytes of content. */
export function sealRecords(
	keys: TrafficKeys,
	contentType: int32,
	data: Readonly<uint8[]>,
): Result<uint8[], RecordFailure> {
	const length = data.length as int32;
	const full = length / maxPlaintextLength;
	const rest = length - full * maxPlaintextLength;
	const total = full * sealedLength(keys, maxPlaintextLength) + (rest > 0 ? sealedLength(keys, rest) : 0);
	const out = new Array<uint8>(total);
	let at = 0;
	let written = 0;
	while (at < length) {
		if (keys.sequence == exhaustedSequence) return Result.err(RecordFailure.SequenceExhausted);
		const take = Math.min(length - at, maxPlaintextLength) as int32;
		written = sealInto(keys, contentType, data, at, at + take, out, written);
		at += take;
	}
	return Result.ok(out);
}

/** A record as it arrived: outer content type, header and body. */
export interface Record {
	contentType: int32;
	header: uint8[];
	body: uint8[];
}

/** A decrypted TLSInnerPlaintext: the real content type and the content without padding. */
export interface InnerPlaintext {
	contentType: int32;
	content: uint8[];
}

/** One past the last nonzero byte of `plain`, 0 when all are zero, with no branch on the bytes (the padding length is secret). */
function paddingStart(plain: Readonly<uint8[]>, length: int32): int32 {
	let end = 0;
	for (let i = 0; i < length; i++) {
		const octet = plain[i] as int32;
		const nonzero = (octet | -octet) >> 31;
		end = (end & ~nonzero) | ((i + 1) & nonzero);
	}
	return end;
}

/** Decrypts a protected record in place in its body and strips its zero padding; advances the sequence number on success. */
export function openRecord(
	keys: TrafficKeys,
	record: Record,
): Result<InnerPlaintext, RecordFailure> {
	if (keys.sequence == exhaustedSequence) return Result.err(RecordFailure.SequenceExhausted);
	if (keys.tls12) return openTls12Record(keys, record);
	if (record.body.length < aeadTagLength) return Result.err(RecordFailure.RecordOverflow);
	if (record.body.length > maxCiphertextLength) return Result.err(RecordFailure.RecordOverflow);
	const plain = record.body;
	const length = (plain.length as int32) - aeadTagLength;
	if (!aeadOpenAt(keys.key, recordNonce(keys.iv, keys.sequence), record.header, plain, 0, length)) return Result.err(RecordFailure.BadRecordMac);
	keys.sequence = keys.sequence + 1;
	const end = paddingStart(plain, length);
	if (end == 0) return Result.err(RecordFailure.DecodeError);
	if (end - 1 > maxPlaintextLength) return Result.err(RecordFailure.RecordOverflow);
	const contentType = plain[end - 1] as int32;
	plain.setLength(end - 1);
	return Result.ok({ contentType, content: plain });
}

function openTls12Record(keys: TrafficKeys, record: Record): Result<InnerPlaintext, RecordFailure> {
	const explicitLength = explicitNonceLength(keys);
	const body = record.body;
	if (body.length < explicitLength + aeadTagLength || body.length > maxCiphertextLength) return Result.err(RecordFailure.RecordOverflow);
	const explicit = body.slice(0, explicitLength);
	const length = (body.length as int32) - explicitLength - aeadTagLength;
	const aad = tls12AdditionalData(keys.sequence, record.contentType, length);
	if (!aeadOpenAt(keys.key, tls12Nonce(keys, explicit), aad, body, explicitLength, length)) return Result.err(RecordFailure.BadRecordMac);
	if (length > maxPlaintextLength) return Result.err(RecordFailure.RecordOverflow);
	keys.sequence = keys.sequence + 1;
	if (explicitLength == 0) {
		body.setLength(length);
		return Result.ok({ contentType: record.contentType, content: body });
	}
	return Result.ok({ contentType: record.contentType, content: body.slice(explicitLength, explicitLength + length) });
}

/** Bytes received but not yet cut into records: `pending[start, pending.length)`. */
export class RecordBuffer {
	pending: uint8[];
	start: int32;
}

export function newRecordBuffer(): RecordBuffer {
	return { pending: [], start: 0 };
}

export function append(this buffer: RecordBuffer, data: Readonly<uint8[]>): void {
	if (buffer.start == buffer.pending.length) {
		buffer.pending = data.slice(0);
		buffer.start = 0;
		return;
	}
	if (buffer.start > 0) {
		buffer.pending = buffer.pending.slice(buffer.start);
		buffer.start = 0;
	}
	const at = buffer.pending.length as int32;
	buffer.pending.setLength(at + data.length);
	copyRange(buffer.pending, at, data, 0, data.length as int32);
}

/** The length the next record needs, or -1 when its header has not arrived. */
export function nextRecordLength(this buffer: RecordBuffer): int32 {
	const start = buffer.start;
	if (buffer.pending.length - start < recordHeaderLength) return -1;
	return ((buffer.pending[start + 3] as int32) << 8) | (buffer.pending[start + 4] as int32);
}

/** The next whole record, or null when more bytes are needed; check `nextRecordLength` against the limit first. */
export function takeRecord(this buffer: RecordBuffer): Record | null {
	const length = buffer.nextRecordLength();
	const start = buffer.start;
	if (length < 0 || buffer.pending.length - start < recordHeaderLength + length) return null;
	const bodyAt = start + recordHeaderLength;
	const end = bodyAt + length;
	const record: Record = {
		contentType: buffer.pending[start] as int32,
		header: buffer.pending.slice(start, bodyAt),
		body: buffer.pending.slice(bodyAt, end),
	};
	if (end == buffer.pending.length) {
		buffer.pending = [];
		buffer.start = 0;
	} else {
		buffer.start = end;
	}
	return record;
}
