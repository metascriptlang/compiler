/**
 * RSA on `bigint`: key encodings (PKCS#1, PKCS#8, SPKI) and, for the JavaScript `*Sync` forms, the RFC 8017
 * operations. Not constant-time and slow: a 2048-bit private operation takes milliseconds where a native
 * library takes microseconds, so use the asynchronous forms (WebCrypto) unless you need a synchronous call.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, tagSequence, tagOctetString, tagBitString, tagNull, tagOid,
	oidRsaEncryption,
} from "./asn1";
import { bigFromBytes, bigToBytes, bitLength } from "./bigint";

/** Keys below this are refused on every backend. */
export const rsaMinBits: int32 = 2048;

export interface RsaPublicData {
	n: bigint;
	e: bigint;
}

export interface RsaPrivateData {
	n: bigint;
	e: bigint;
	d: bigint;
	p: bigint;
	q: bigint;
	dp: bigint;
	dq: bigint;
	qi: bigint;
}

export function rsaModulusBytes(n: bigint): int32 {
	return (bitLength(n) + 7) >> 3;
}

function integerAt(buf: Readonly<uint8[]>, item: DerItem): bigint | null {
	const bytes = derUnsigned(buf, item);
	if (bytes == null) return null;
	return bigFromBytes(bytes);
}

function publicFromSequence(buf: Readonly<uint8[]>, seq: DerItem): RsaPublicData | null {
	const parts = derChildren(buf, seq);
	if (parts == null || parts.length != 2) return null;
	const n = integerAt(buf, parts[0]);
	const e = integerAt(buf, parts[1]);
	if (n == null || e == null || bitLength(n) < rsaMinBits || e < 3n || e % 2n == 0n || e >= n) return null;
	return { n, e };
}

/** RSAPublicKey (`RSA PUBLIC KEY`). */
export function rsaPublicFromPkcs1(der: Readonly<uint8[]>): RsaPublicData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return publicFromSequence(der, root);
}

/** The AlgorithmIdentifier for rsaEncryption must come first: SEQUENCE { OID, NULL }. */
function isRsaAlgorithm(buf: Readonly<uint8[]>, algorithm: DerItem): boolean {
	if (algorithm.tag != tagSequence) return false;
	const parts = derChildren(buf, algorithm);
	if (parts == null || parts.length != 2) return false;
	return parts[0].tag == tagOid && derSame(buf, parts[0], oidRsaEncryption) && parts[1].tag == tagNull && parts[1].end == parts[1].body;
}

/** SubjectPublicKeyInfo (`PUBLIC KEY`). */
export function rsaPublicFromSpki(der: Readonly<uint8[]>): RsaPublicData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = derChildren(der, root);
	if (parts == null || parts.length != 2 || !isRsaAlgorithm(der, parts[0])) return null;
	const bits = parts[1];
	if (bits.tag != tagBitString || bits.end - bits.body < 2 || der[bits.body] != 0) return null;
	const inner = derItem(der, bits.body + 1, bits.end);
	if (inner == null || inner.tag != tagSequence || inner.end != bits.end) return null;
	return publicFromSequence(der, inner);
}

function rsaAlgorithm(): uint8[] {
	return derSequence([derOidOf(oidRsaEncryption), derTlv(tagNull, [])]);
}

function unsignedOf(value: bigint): uint8[] {
	return derUnsignedInteger(bigToBytes(value, ((bitLength(value) + 7) >> 3) as int32));
}

export function rsaPublicToSpki(pub: RsaPublicData): uint8[] {
	const key = derSequence([unsignedOf(pub.n), unsignedOf(pub.e)]);
	return derSequence([rsaAlgorithm(), derBits(key)]);
}

function privateFromSequence(buf: Readonly<uint8[]>, seq: DerItem): RsaPrivateData | null {
	const parts = derChildren(buf, seq);
	if (parts == null || parts.length != 9) return null;
	const version = derUnsigned(buf, parts[0]);
	if (version == null || version.length != 1 || version[0] != 0) return null;
	const values: bigint[] = [];
	for (let i = 1; i < 9; i++) {
		const value = integerAt(buf, parts[i]);
		if (value == null) return null;
		values.push(value);
	}
	const key: RsaPrivateData = { n: values[0], e: values[1], d: values[2], p: values[3], q: values[4], dp: values[5], dq: values[6], qi: values[7] };
	if (bitLength(key.n) < rsaMinBits || key.p < 3n || key.q < 3n) return null;
	if (key.p * key.q != key.n) return null;
	if ((key.e * key.dp) % (key.p - 1n) != 1n || (key.e * key.dq) % (key.q - 1n) != 1n) return null;
	if ((key.qi * key.q) % key.p != 1n) return null;
	return key;
}

/** RSAPrivateKey (`RSA PRIVATE KEY`), two primes only. */
export function rsaPrivateFromPkcs1(der: Readonly<uint8[]>): RsaPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return privateFromSequence(der, root);
}

/** PrivateKeyInfo (`PRIVATE KEY`). */
export function rsaPrivateFromPkcs8(der: Readonly<uint8[]>): RsaPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	const parts = derChildren(der, root);
	if (parts == null || parts.length != 3) return null;
	const version = derUnsigned(der, parts[0]);
	if (version == null || version.length != 1 || version[0] != 0 || !isRsaAlgorithm(der, parts[1])) return null;
	if (parts[2].tag != tagOctetString) return null;
	const inner = derItem(der, parts[2].body, parts[2].end);
	if (inner == null || inner.tag != tagSequence || inner.end != parts[2].end) return null;
	return privateFromSequence(der, inner);
}

export function rsaPrivateToPkcs1(key: RsaPrivateData): uint8[] {
	return derSequence([
		derSmallInteger(0), unsignedOf(key.n), unsignedOf(key.e), unsignedOf(key.d), unsignedOf(key.p),
		unsignedOf(key.q), unsignedOf(key.dp), unsignedOf(key.dq), unsignedOf(key.qi),
	]);
}

export function rsaPrivateToPkcs8(key: RsaPrivateData): uint8[] {
	return derSequence([derSmallInteger(0), rsaAlgorithm(), derOctets(rsaPrivateToPkcs1(key))]);
}

export function rsaPublicOf(key: RsaPrivateData): RsaPublicData {
	return { n: key.n, e: key.e };
}
