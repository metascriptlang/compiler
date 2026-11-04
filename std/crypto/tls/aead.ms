/**
 * The TLS 1.3 and TLS 1.2 ECDHE cipher suites this client offers and their AEADs:
 * AES-GCM and the RFC 8439 ChaCha20-Poly1305 with a 96-bit nonce, both from
 * the portable kernels, sealing and opening in place.
 */

import { expandKey, gcmEncryptInto, gcmDecryptInto } from "../pure/aes";
import { keyWords, chacha20Poly1305SealInto, chacha20Poly1305OpenInto } from "../pure/chacha";
import { kindSha256, kindSha384 } from "../pure/state";
import { wipeBytes, wipeWords } from "../pure/secret";

export const suiteAes128GcmSha256: int32 = 0x1301;
export const suiteAes256GcmSha384: int32 = 0x1302;
export const suiteChacha20Poly1305Sha256: int32 = 0x1303;

export const suiteEcdheEcdsaAes128GcmSha256: int32 = 0xc02b;
export const suiteEcdheEcdsaAes256GcmSha384: int32 = 0xc02c;
export const suiteEcdheRsaAes128GcmSha256: int32 = 0xc02f;
export const suiteEcdheRsaAes256GcmSha384: int32 = 0xc030;
export const suiteEcdheRsaChacha20Poly1305Sha256: int32 = 0xcca8;
export const suiteEcdheEcdsaChacha20Poly1305Sha256: int32 = 0xcca9;

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

/** A TLS 1.2 suite's PRF hash and AEAD key length, or null when this client does not implement it. */
export function tls12CipherSuiteOf(code: int32): CipherSuite | null {
	if (code == suiteEcdheEcdsaAes128GcmSha256 || code == suiteEcdheRsaAes128GcmSha256) return { code, hashKind: kindSha256, keyLength: 16 };
	if (code == suiteEcdheEcdsaAes256GcmSha384 || code == suiteEcdheRsaAes256GcmSha384) return { code, hashKind: kindSha384, keyLength: 32 };
	if (code == suiteEcdheEcdsaChacha20Poly1305Sha256 || code == suiteEcdheRsaChacha20Poly1305Sha256) return { code, hashKind: kindSha256, keyLength: 32 };
	return null;
}

/** Whether a TLS 1.2 suite's ServerKeyExchange is signed with ECDSA rather than RSA. */
export function tls12SuiteSignsWithEcdsa(code: int32): boolean {
	return code == suiteEcdheEcdsaAes128GcmSha256 || code == suiteEcdheEcdsaAes256GcmSha384 || code == suiteEcdheEcdsaChacha20Poly1305Sha256;
}

/** RFC 5288 3 and RFC 7905 2: the implicit IV a TLS 1.2 key block yields, 4 bytes for GCM and 12 for ChaCha20-Poly1305. */
export function tls12FixedIvLength(code: int32): int32 {
	return usesChacha(code) ? aeadNonceLength : 4;
}

function usesChacha(code: int32): boolean {
	return code == suiteChacha20Poly1305Sha256 || code == suiteEcdheRsaChacha20Poly1305Sha256 || code == suiteEcdheEcdsaChacha20Poly1305Sha256;
}

/** One direction's AEAD key, expanded once. */
export class AeadKey {
	suite: int32;
	key: uint8[];
	aesSchedule: uint32[];
	chachaKey: uint32[];
}

function onDestroy(this key: AeadKey): void {
	wipeBytes(key.key);
	wipeWords(key.aesSchedule);
}

export function newAeadKey(suite: int32, key: Readonly<uint8[]>): AeadKey {
	const own: uint8[] = [...key];
	const chacha = usesChacha(suite);
	return { suite, key: own, aesSchedule: chacha ? [] : expandKey(own), chachaKey: chacha ? chachaKeyOf(own) : [] };
}

/** cipher text || tag. */
export function aeadSeal(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	plain: Readonly<uint8[]>,
): uint8[] {
	const length = plain.length as int32;
	const out = new Array<uint8>(length + aeadTagLength);
	if (usesChacha(key.suite)) {
		if (!chacha20Poly1305SealInto(key.chachaKey, nonce, aad, plain, out)) throw new Error(`chacha20-poly1305: nonce must be 12 bytes, got ${nonce.length}`);
		return out;
	}
	gcmEncryptInto(key.aesSchedule, nonce, aad, plain, 0, length, out, 0, out, length);
	return out;
}

/** The plain text of cipher text || tag, or null when the tag does not verify. */
export function aeadOpen(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	sealed: Readonly<uint8[]>,
): uint8[] | null {
	const length = (sealed.length as int32) - aeadTagLength;
	if (length < 0) return null;
	const out = new Array<uint8>(length);
	if (usesChacha(key.suite)) return chacha20Poly1305OpenInto(key.chachaKey, nonce, aad, sealed, out) ? out : null;
	return gcmDecryptInto(key.aesSchedule, nonce, aad, sealed, 0, length, sealed, length, out, 0) ? out : null;
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
	wipeBytes(oneTimeKey);
	return tag;
}

/** RFC 8439 2.8 AEAD_CHACHA20_POLY1305 seal: cipher text || tag. */
export function chachaPolySeal(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	plain: Readonly<uint8[]>,
): uint8[] {
	return aeadSeal(newAeadKey(suiteChacha20Poly1305Sha256, key), nonce, aad, plain);
}

export function chachaPolyOpen(
	key: Readonly<uint8[]>,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	sealed: Readonly<uint8[]>,
): uint8[] | null {
	return aeadOpen(newAeadKey(suiteChacha20Poly1305Sha256, key), nonce, aad, sealed);
}
