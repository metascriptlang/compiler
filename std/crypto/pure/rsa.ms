/**
 * RSA on `bigint`: key encodings (PKCS#1, PKCS#8, SPKI) and, for the JavaScript `*Sync` forms, the RFC 8017
 * operations. Not constant-time and slow: a 2048-bit private operation takes milliseconds where a native
 * library takes microseconds, so use the asynchronous forms (WebCrypto) unless you need a synchronous call.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, derJoin, tagSequence, tagOctetString, tagBitString, tagNull, tagOid,
	oidRsaEncryption,
} from "./asn1";
import { bigFromBytes, bigToBytes, bitLength, mod, modPow, modInverse, gcd, randomBelow, randomOctets } from "./bigint";
import { hashKind, hashOf } from "./hash";
import { kindSha256 } from "./state";

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

export function rsaPublicFromPkcs1(der: Readonly<uint8[]>): RsaPublicData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return publicFromSequence(der, root);
}

function isRsaAlgorithm(buf: Readonly<uint8[]>, algorithm: DerItem): boolean {
	if (algorithm.tag != tagSequence) return false;
	const parts = derChildren(buf, algorithm);
	if (parts == null || parts.length != 2) return false;
	return parts[0].tag == tagOid && derSame(buf, parts[0], oidRsaEncryption) && parts[1].tag == tagNull && parts[1].end == parts[1].body;
}

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

export function rsaPrivateFromPkcs1(der: Readonly<uint8[]>): RsaPrivateData | null {
	const root = derRoot(der, tagSequence);
	if (root == null) return null;
	return privateFromSequence(der, root);
}

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

const digestPrefixSha1: uint8[] = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14];
const digestPrefixSha256: uint8[] = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20];
const digestPrefixSha384: uint8[] = [0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30];
const digestPrefixSha512: uint8[] = [0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40];

function digestPrefix(hash: string): uint8[] | null {
	if (hash == "sha1") return digestPrefixSha1;
	if (hash == "sha256") return digestPrefixSha256;
	if (hash == "sha384") return digestPrefixSha384;
	if (hash == "sha512") return digestPrefixSha512;
	return null;
}

function xorInto(target: uint8[], mask: Readonly<uint8[]>): void {
	for (let i = 0; i < mask.length; i++) target[i] = (target[i] ^ mask[i]) as uint8;
}

function slice(bytes: Readonly<uint8[]>, from: int32, to: int32): uint8[] {
	const out: uint8[] = [];
	for (let i = from; i < to; i++) out.push(bytes[i]);
	return out;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]) as int32;
	return diff == 0;
}

function mgf1(kind: int32, seed: Readonly<uint8[]>, length: int32): uint8[] {
	const out: uint8[] = [];
	let counter = 0;
	while (out.length < length) {
		const block = hashOf(kind, derJoin([seed, [((counter >> 24) & 255) as uint8, ((counter >> 16) & 255) as uint8, ((counter >> 8) & 255) as uint8, (counter & 255) as uint8]]));
		for (let i = 0; i < block.length && out.length < length; i++) out.push(block[i]);
		counter += 1;
	}
	return out;
}

function privateOperation(key: RsaPrivateData, value: bigint): bigint | null {
	const m1 = modPow(value % key.p, key.dp, key.p);
	const m2 = modPow(value % key.q, key.dq, key.q);
	const h = mod(key.qi * (m1 - m2), key.p);
	const result = m2 + h * key.q;
	if (modPow(result, key.e, key.n) != value) return null;
	return result;
}

function pkcs1Encoding(prefix: Readonly<uint8[]>, digest: Readonly<uint8[]>, size: int32): uint8[] | null {
	const tail = derJoin([prefix, digest]);
	if (size < tail.length + 11) return null;
	const out: uint8[] = [0, 1];
	for (let i = 0; i < size - tail.length - 3; i++) out.push(255);
	out.push(0);
	return derJoin([out, tail]);
}

export function rsaSignPkcs1(key: RsaPrivateData, hash: string, message: Readonly<uint8[]>): uint8[] | null {
	const prefix = digestPrefix(hash);
	if (prefix == null) return null;
	const size = rsaModulusBytes(key.n);
	const encoded = pkcs1Encoding(prefix, hashOf(hashKind(hash), message), size);
	if (encoded == null) return null;
	const signed = privateOperation(key, bigFromBytes(encoded));
	if (signed == null) return null;
	return bigToBytes(signed, size);
}

export function rsaVerifyPkcs1(key: RsaPublicData, hash: string, message: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	const prefix = digestPrefix(hash);
	const size = rsaModulusBytes(key.n);
	if (prefix == null || signature.length != size) return false;
	const s = bigFromBytes(signature);
	if (s >= key.n) return false;
	const expected = pkcs1Encoding(prefix, hashOf(hashKind(hash), message), size);
	if (expected == null) return false;
	return sameBytes(bigToBytes(modPow(s, key.e, key.n), size), expected);
}

function pssLayout(n: bigint, hashSize: int32): int32 {
	return ((bitLength(n) - 1 + 7) >> 3) - hashSize - 2;
}

export function rsaSignPss(key: RsaPrivateData, hash: string, message: Readonly<uint8[]>): uint8[] | null {
	if (digestPrefix(hash) == null) return null;
	const kind = hashKind(hash);
	const mHash = hashOf(kind, message);
	const hashSize = mHash.length as int32;
	const emBits = bitLength(key.n) - 1;
	const emLength = (emBits + 7) >> 3;
	const zeros = pssLayout(key.n, hashSize) - hashSize;
	if (zeros < 0) return null;
	const salt = randomOctets(hashSize);
	const h = hashOf(kind, derJoin([repeated(8, 0), mHash, salt]));
	const block = derJoin([repeated(zeros, 0), [1] as uint8[], salt]);
	xorInto(block, mgf1(kind, h, emLength - hashSize - 1));
	block[0] = ((block[0] as int32) & (255 >> (8 * emLength - emBits))) as uint8;
	const encoded = derJoin([block, h, [0xbc] as uint8[]]);
	const signed = privateOperation(key, bigFromBytes(encoded));
	if (signed == null) return null;
	return bigToBytes(signed, rsaModulusBytes(key.n));
}

export function rsaVerifyPss(key: RsaPublicData, hash: string, message: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	if (digestPrefix(hash) == null || signature.length != rsaModulusBytes(key.n)) return false;
	const kind = hashKind(hash);
	const mHash = hashOf(kind, message);
	const hashSize = mHash.length as int32;
	const emBits = bitLength(key.n) - 1;
	const emLength = (emBits + 7) >> 3;
	const zeros = pssLayout(key.n, hashSize) - hashSize;
	const s = bigFromBytes(signature);
	if (zeros < 0 || s >= key.n) return false;
	const m = modPow(s, key.e, key.n);
	if (bitLength(m) > emBits) return false;
	const encoded = bigToBytes(m, emLength);
	if (encoded[emLength - 1] != 0xbc) return false;
	const block = slice(encoded, 0, emLength - hashSize - 1);
	const h = slice(encoded, emLength - hashSize - 1, emLength - 1);
	const top: int32 = 255 >> (8 * emLength - emBits);
	if (((block[0] as int32) & ~top & 255) != 0) return false;
	xorInto(block, mgf1(kind, h, emLength - hashSize - 1));
	block[0] = ((block[0] as int32) & top) as uint8;
	for (let i = 0; i < zeros; i++) {
		if (block[i] != 0) return false;
	}
	if (block[zeros] != 1) return false;
	const salt = slice(block, zeros + 1, block.length as int32);
	return sameBytes(hashOf(kind, derJoin([repeated(8, 0), mHash, salt])), h);
}

function repeated(count: int32, value: uint8): uint8[] {
	const out: uint8[] = [];
	for (let i = 0; i < count; i++) out.push(value);
	return out;
}

export function rsaOaepEncrypt(key: RsaPublicData, message: Readonly<uint8[]>): uint8[] | null {
	const size = rsaModulusBytes(key.n);
	const fill = size - message.length - 66;
	if (fill < 0) return null;
	const labelHash = hashOf(kindSha256, []);
	const seed = randomOctets(32);
	const block = derJoin([labelHash, repeated(fill, 0), [1] as uint8[], message]);
	xorInto(block, mgf1(kindSha256, seed, size - 33));
	const maskedSeed = seed;
	xorInto(maskedSeed, mgf1(kindSha256, block, 32));
	const encoded = derJoin([[0] as uint8[], maskedSeed, block]);
	return bigToBytes(modPow(bigFromBytes(encoded), key.e, key.n), size);
}

export function rsaOaepDecrypt(key: RsaPrivateData, ciphertext: Readonly<uint8[]>): uint8[] | null {
	const size = rsaModulusBytes(key.n);
	if (ciphertext.length != size || size < 66) return null;
	const c = bigFromBytes(ciphertext);
	if (c >= key.n) return null;
	const opened = privateOperation(key, c);
	if (opened == null) return null;
	const encoded = bigToBytes(opened, size);
	const seed = slice(encoded, 1, 33);
	const block = slice(encoded, 33, size);
	xorInto(seed, mgf1(kindSha256, block, 32));
	xorInto(block, mgf1(kindSha256, seed, size - 33));
	let bad = encoded[0] != 0 || !sameBytes(slice(block, 0, 32), hashOf(kindSha256, []));
	let at = 32;
	while (at < block.length && block[at] == 0) at += 1;
	if (at == block.length || block[at] != 1) bad = true;
	if (bad) return null;
	return slice(block, at + 1, block.length as int32);
}

const smallPrimes: int32[] = [];

function smallPrimeList(): int32[] {
	if (smallPrimes.length == 0) {
		for (let candidate = 3; candidate < 2000; candidate += 2) {
			let prime = true;
			for (const known of smallPrimes) {
				if (known * known > candidate) break;
				if (candidate % known == 0) {
					prime = false;
					break;
				}
			}
			if (prime) smallPrimes.push(candidate);
		}
	}
	return smallPrimes;
}

function millerRabin(n: bigint, rounds: int32): boolean {
	let odd = n - 1n;
	let twos = 0;
	while (odd % 2n == 0n) {
		odd = odd >> 1n;
		twos += 1;
	}
	for (let round = 0; round < rounds; round++) {
		const base = randomBelow(n - 3n) + 1n;
		let x = modPow(base, odd, n);
		if (x == 1n || x == n - 1n) continue;
		let witness = true;
		for (let i = 1; i < twos; i++) {
			x = (x * x) % n;
			if (x == n - 1n) {
				witness = false;
				break;
			}
		}
		if (witness) return false;
	}
	return true;
}

function randomPrime(bits: int32, e: bigint): bigint {
	const small = smallPrimeList();
	while (true) {
		const bytes = randomOctets(bits >> 3);
		bytes[0] = (bytes[0] | 0xc0) as uint8;
		bytes[bytes.length - 1] = (bytes[bytes.length - 1] | 1) as uint8;
		const candidate = bigFromBytes(bytes);
		let divisible = false;
		for (const prime of small) {
			if (candidate % BigInt(prime) == 0n) {
				divisible = true;
				break;
			}
		}
		if (divisible || (candidate - 1n) % e == 0n) continue;
		if (millerRabin(candidate, 8)) return candidate;
	}
}

export function rsaGenerate(bits: int32): RsaPrivateData {
	const e = 65537n;
	while (true) {
		const p = randomPrime(bits >> 1, e);
		const q = randomPrime(bits >> 1, e);
		const n = p * q;
		if (p == q || bitLength(n) != bits) continue;
		const big = p > q ? p : q;
		const little = p > q ? q : p;
		const lambda = ((big - 1n) * (little - 1n)) / gcd(big - 1n, little - 1n);
		const d = modInverse(e, lambda);
		return { n, e, d, p: big, q: little, dp: d % (big - 1n), dq: d % (little - 1n), qi: modInverse(little, big) };
	}
}
