/**
 * The TLS record layer (RFC 8446 5): plaintext records, protected TLS 1.3
 * records (sequence-number nonce, inner content type, padding), protected
 * TLS 1.2 AEAD records (RFC 5246 6.2.3.3: explicit-nonce GCM per RFC 5288,
 * ChaCha20-Poly1305 per RFC 7905) and a buffer that cuts a byte stream
 * into whole records.
 */

import { CipherSuite, AeadKey, newAeadKey, aeadSeal, aeadOpen, aeadTagLength, aeadNonceLength } from "./aead";
import { hkdfExpandLabel } from "./keySchedule";

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

/** The key and IV of a traffic secret (RFC 8446 7.3), sequence number 0. */
export function trafficKeysOf(suite: CipherSuite, secret: Readonly<uint8[]>): TrafficKeys {
	const kind = suite.hashKind;
	return {
		suite,
		secret: [...secret],
		key: newAeadKey(suite.code, hkdfExpandLabel(kind, secret, "key", [], suite.keyLength)),
		iv: hkdfExpandLabel(kind, secret, "iv", [], aeadNonceLength),
		sequence: 0,
		tls12: false,
	};
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
	return trafficKeysOf(keys.suite, next);
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

/** One protected record holding `data[from, to)` as `contentType`; advances the sequence number. */
export function sealRecord(
	keys: TrafficKeys,
	contentType: int32,
	data: Readonly<uint8[]>,
	from: int32,
	to: int32,
): uint8[] {
	if (keys.tls12) return sealTls12Record(keys, contentType, data.slice(from, to));
	const inner: uint8[] = [];
	for (let i = from; i < to; i++) inner.push(data[i]);
	inner.push(contentType as uint8);
	const header = recordHeader(contentApplicationData, (inner.length as int32) + aeadTagLength);
	const sealed = aeadSeal(keys.key, recordNonce(keys.iv, keys.sequence), header, inner);
	keys.sequence = keys.sequence + 1;
	const out: uint8[] = [...header];
	for (let i = 0; i < sealed.length; i++) out.push(sealed[i]);
	return out;
}

/** The explicit nonce is the sequence number, which never repeats under one key. */
function sealTls12Record(keys: TrafficKeys, contentType: int32, plain: Readonly<uint8[]>): uint8[] {
	const explicit = explicitNonceLength(keys) > 0 ? sequenceOctets(keys.sequence) : [];
	const aad = tls12AdditionalData(keys.sequence, contentType, plain.length as int32);
	const sealed = aeadSeal(keys.key, tls12Nonce(keys, explicit), aad, plain);
	keys.sequence = keys.sequence + 1;
	const out = recordHeader(contentType, (explicit.length + sealed.length) as int32);
	for (let i = 0; i < explicit.length; i++) out.push(explicit[i]);
	for (let i = 0; i < sealed.length; i++) out.push(sealed[i]);
	return out;
}

/** Protected records of all of `data`, each at most 2^14 bytes of content. */
export function sealRecords(
	keys: TrafficKeys,
	contentType: int32,
	data: Readonly<uint8[]>,
): uint8[] {
	const out: uint8[] = [];
	let at = 0;
	while (at < data.length) {
		const take = Math.min(data.length - at, maxPlaintextLength) as int32;
		const record = sealRecord(keys, contentType, data, at, at + take);
		for (let i = 0; i < record.length; i++) out.push(record[i]);
		at += take;
	}
	return out;
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

export enum OpenFailure {
	BadRecordMac,
	RecordOverflow,
	DecodeError,
}

/** Decrypts a protected record and strips its zero padding; advances the sequence number on success. */
export function openRecord(
	keys: TrafficKeys,
	record: Record,
): Result<InnerPlaintext, OpenFailure> {
	if (keys.tls12) return openTls12Record(keys, record);
	if (record.body.length < aeadTagLength) return Result.err(OpenFailure.RecordOverflow);
	if (record.body.length > maxCiphertextLength) return Result.err(OpenFailure.RecordOverflow);
	const plain = aeadOpen(keys.key, recordNonce(keys.iv, keys.sequence), record.header, record.body);
	if (plain == null) return Result.err(OpenFailure.BadRecordMac);
	keys.sequence = keys.sequence + 1;
	let end = plain.length as int32;
	while (end > 0 && plain[end - 1] == 0) end -= 1;
	if (end == 0) return Result.err(OpenFailure.DecodeError);
	if (end - 1 > maxPlaintextLength) return Result.err(OpenFailure.RecordOverflow);
	return Result.ok({ contentType: plain[end - 1] as int32, content: plain.slice(0, end - 1) });
}

function openTls12Record(keys: TrafficKeys, record: Record): Result<InnerPlaintext, OpenFailure> {
	const explicitLength = explicitNonceLength(keys);
	const body = record.body;
	if (body.length < explicitLength + aeadTagLength || body.length > maxCiphertextLength) return Result.err(OpenFailure.RecordOverflow);
	const explicit = body.slice(0, explicitLength);
	const sealed = body.slice(explicitLength);
	const aad = tls12AdditionalData(keys.sequence, record.contentType, (sealed.length as int32) - aeadTagLength);
	const plain = aeadOpen(keys.key, tls12Nonce(keys, explicit), aad, sealed);
	if (plain == null) return Result.err(OpenFailure.BadRecordMac);
	if (plain.length > maxPlaintextLength) return Result.err(OpenFailure.RecordOverflow);
	keys.sequence = keys.sequence + 1;
	return Result.ok({ contentType: record.contentType, content: plain });
}

/** Bytes received but not yet cut into records. */
export class RecordBuffer {
	pending: uint8[];
}

export function newRecordBuffer(): RecordBuffer {
	return { pending: [] };
}

export function append(this buffer: RecordBuffer, data: Readonly<uint8[]>): void {
	for (let i = 0; i < data.length; i++) buffer.pending.push(data[i]);
}

/** The length the next record needs, or -1 when its header has not arrived. */
export function nextRecordLength(this buffer: RecordBuffer): int32 {
	if (buffer.pending.length < recordHeaderLength) return -1;
	return ((buffer.pending[3] as int32) << 8) | (buffer.pending[4] as int32);
}

/** The next whole record, or null when more bytes are needed; check `nextRecordLength` against the limit first. */
export function takeRecord(this buffer: RecordBuffer): Record | null {
	const length = buffer.nextRecordLength();
	if (length < 0 || buffer.pending.length < recordHeaderLength + length) return null;
	const end = recordHeaderLength + length;
	const record: Record = {
		contentType: buffer.pending[0] as int32,
		header: buffer.pending.slice(0, recordHeaderLength),
		body: buffer.pending.slice(recordHeaderLength, end),
	};
	buffer.pending = buffer.pending.slice(end);
	return record;
}
