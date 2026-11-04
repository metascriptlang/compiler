/**
 * The three TLS 1.3 cipher suites this client offers and their AEADs:
 * AES-GCM from the portable AES kernel and the RFC 8439 ChaCha20-Poly1305
 * with a 96-bit nonce, built on the portable Poly1305.
 */

import { expandKey, gcmSealWithNonce, gcmOpen } from "../pure/aes";
import { newPoly1305, updatePoly1305, padPoly1305, finishPoly1305 } from "../pure/poly1305";
import { kindSha256, kindSha384 } from "../pure/state";

export const suiteAes128GcmSha256: int32 = 0x1301;
export const suiteAes256GcmSha384: int32 = 0x1302;
export const suiteChacha20Poly1305Sha256: int32 = 0x1303;

export const aeadTagLength: int32 = 16;
export const aeadNonceLength: int32 = 12;

/** A cipher suite's hash and AEAD key length. */
export interface CipherSuite {
	code: int32;
	hashKind: int32;
	keyLength: int32;
}

/** The suite of a wire code, or null when this client does not implement it. */
export function cipherSuiteOf(code: int32): CipherSuite | null {
	if (code == suiteAes128GcmSha256) return { code, hashKind: kindSha256, keyLength: 16 };
	if (code == suiteAes256GcmSha384) return { code, hashKind: kindSha384, keyLength: 32 };
	if (code == suiteChacha20Poly1305Sha256) return { code, hashKind: kindSha256, keyLength: 32 };
	return null;
}

/** One direction's AEAD key, expanded once. */
export class AeadKey {
	suite: int32;
	key: uint8[];
	aesSchedule: uint32[];
}

export function newAeadKey(suite: int32, key: Readonly<uint8[]>): AeadKey {
	const own: uint8[] = [...key];
	const aesSchedule = suite == suiteChacha20Poly1305Sha256 ? [] : expandKey(own);
	return { suite, key: own, aesSchedule };
}

/** cipher text || tag. */
export function aeadSeal(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	plain: Readonly<uint8[]>,
): uint8[] {
	if (key.suite == suiteChacha20Poly1305Sha256) return chachaPolySeal(key.key, nonce, aad, plain);
	const sealed = gcmSealWithNonce(key.aesSchedule, nonce, plain, aad);
	return sealed.slice(aeadNonceLength);
}

/** The plain text of cipher text || tag, or null when the tag does not verify. */
export function aeadOpen(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	sealed: Readonly<uint8[]>,
): uint8[] | null {
	if (sealed.length < aeadTagLength) return null;
	if (key.suite == suiteChacha20Poly1305Sha256) return chachaPolyOpen(key.key, nonce, aad, sealed);
	const joined: uint8[] = [...nonce];
	for (let i = 0; i < sealed.length; i++) joined.push(sealed[i]);
	return gcmOpen(key.aesSchedule, joined, aad);
}

function load32(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) |
		((data[at + 1] as uint32) << 8) |
		((data[at + 2] as uint32) << 16) |
		((data[at + 3] as uint32) << 24);
}

function rotl(x: uint32, n: uint32): uint32 {
	return (x << n) | (x >> (32 - n));
}

function quarterRound(x: uint32[], a: int32, b: int32, c: int32, d: int32): void {
	x[a] = x[a] + x[b];
	x[d] = rotl(x[d] ^ x[a], 16);
	x[c] = x[c] + x[d];
	x[b] = rotl(x[b] ^ x[c], 12);
	x[a] = x[a] + x[b];
	x[d] = rotl(x[d] ^ x[a], 8);
	x[c] = x[c] + x[d];
	x[b] = rotl(x[b] ^ x[c], 7);
}

/** RFC 8439 2.3: the 64-byte block for `counter` under a 32-byte key and 12-byte nonce. */
export function chachaBlock(
	key: Readonly<uint8[]>,
	counter: uint32,
	nonce: Readonly<uint8[]>,
): uint8[] {
	const state = new Array<uint32>(16);
	state[0] = 0x61707865;
	state[1] = 0x3320646e;
	state[2] = 0x79622d32;
	state[3] = 0x6b206574;
	for (let i = 0; i < 8; i++) state[4 + i] = load32(key, i * 4);
	state[12] = counter;
	for (let i = 0; i < 3; i++) state[13 + i] = load32(nonce, i * 4);
	const x: uint32[] = [...state];
	for (let round = 0; round < 10; round++) {
		quarterRound(x, 0, 4, 8, 12);
		quarterRound(x, 1, 5, 9, 13);
		quarterRound(x, 2, 6, 10, 14);
		quarterRound(x, 3, 7, 11, 15);
		quarterRound(x, 0, 5, 10, 15);
		quarterRound(x, 1, 6, 11, 12);
		quarterRound(x, 2, 7, 8, 13);
		quarterRound(x, 3, 4, 9, 14);
	}
	const out = new Array<uint8>(64);
	for (let i = 0; i < 16; i++) {
		const word = x[i] + state[i];
		out[i * 4] = (word & 255) as uint8;
		out[i * 4 + 1] = ((word >> 8) & 255) as uint8;
		out[i * 4 + 2] = ((word >> 16) & 255) as uint8;
		out[i * 4 + 3] = ((word >> 24) & 255) as uint8;
	}
	return out;
}

function chachaXor(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	src: Readonly<uint8[]>,
): uint8[] {
	const out = new Array<uint8>(src.length);
	let counter: uint32 = 1;
	for (let at = 0; at < src.length; at += 64) {
		const block = chachaBlock(key, counter, nonce);
		counter = counter + 1;
		for (let i = 0; i < 64 && at + i < src.length; i++) out[at + i] = src[at + i] ^ block[i];
	}
	return out;
}

function lengthOctets(value: int32): uint8[] {
	const out = new Array<uint8>(8);
	for (let i = 0; i < 4; i++) out[i] = ((value >> (8 * i)) & 255) as uint8;
	return out;
}

function chachaPolyTag(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	cipher: Readonly<uint8[]>,
	cipherLength: int32,
): uint8[] {
	const oneTimeKey = chachaBlock(key, 0, nonce);
	const mac = newPoly1305(oneTimeKey, 0);
	updatePoly1305(mac, aad, 0, aad.length as int32);
	padPoly1305(mac);
	updatePoly1305(mac, cipher, 0, cipherLength);
	padPoly1305(mac);
	updatePoly1305(mac, lengthOctets(aad.length as int32), 0, 8);
	updatePoly1305(mac, lengthOctets(cipherLength), 0, 8);
	const tag = new Array<uint8>(16);
	finishPoly1305(mac, tag, 0);
	return tag;
}

/** RFC 8439 2.8 AEAD_CHACHA20_POLY1305 seal: cipher text || tag. */
export function chachaPolySeal(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	plain: Readonly<uint8[]>,
): uint8[] {
	const out = chachaXor(key, nonce, plain);
	const tag = chachaPolyTag(key, nonce, aad, out, out.length as int32);
	for (let i = 0; i < 16; i++) out.push(tag[i]);
	return out;
}

export function chachaPolyOpen(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	sealed: Readonly<uint8[]>,
): uint8[] | null {
	const length = (sealed.length as int32) - 16;
	if (length < 0) return null;
	const tag = chachaPolyTag(key, nonce, aad, sealed, length);
	let diff = 0;
	for (let i = 0; i < 16; i++) diff |= (tag[i] ^ sealed[length + i]) as int32;
	if (diff != 0) return null;
	return chachaXor(key, nonce, sealed.slice(0, length));
}
