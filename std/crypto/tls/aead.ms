/**
 * The TLS 1.3 and TLS 1.2 ECDHE cipher suites this client offers and their AEADs:
 * AES-GCM and the RFC 8439 ChaCha20-Poly1305 with a 96-bit nonce, both from
 * the portable kernels, sealing and opening in place.
 */

import { KeySchedule, expandKey, wipeKeySchedule, gcmEncryptInto, gcmDecryptInto } from "../pure/aes";
import { keyWords, chacha20Poly1305SealInto, chacha20Poly1305OpenInto, chacha20Poly1305SealAt, chacha20Poly1305OpenAt } from "../pure/chacha";
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
	aesSchedule: KeySchedule;
	chachaKey: uint32[];
}

function onDestroy(this key: AeadKey): void {
	wipeBytes(key.key);
	wipeKeySchedule(key.aesSchedule);
	wipeWords(key.chachaKey);
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

/** Seals `buf[at, +length)` in place and writes its tag to `buf[at + length, +aeadTagLength)`. */
export function aeadSealAt(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	buf: uint8[],
	at: int32,
	length: int32,
): void {
	if (usesChacha(key.suite)) {
		if (!chacha20Poly1305SealAt(key.chachaKey, nonce, aad, buf, at, length)) throw new Error(`chacha20-poly1305: bad nonce or range`);
		return;
	}
	gcmEncryptInto(key.aesSchedule, nonce, aad, buf, at, length, buf, at, buf, at + length);
}

/** Opens `buf[at, +length)` in place once the tag after it verifies; false, with nothing written, when it does not. */
export function aeadOpenAt(
	key: AeadKey,
	nonce: Readonly<uint8[]>,
	aad: Readonly<uint8[]>,
	buf: uint8[],
	at: int32,
	length: int32,
): boolean {
	if (usesChacha(key.suite)) return chacha20Poly1305OpenAt(key.chachaKey, nonce, aad, buf, at, length);
	return gcmDecryptInto(key.aesSchedule, nonce, aad, buf, at, length, buf, at + length, buf, at);
}

function chachaKeyOf(key: Readonly<uint8[]>): uint32[] {
	const words = new Array<uint32>(8);
	if (!keyWords(key, words)) throw new Error(`chacha20-poly1305: key must be 32 bytes, got ${key.length}`);
	return words;
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
