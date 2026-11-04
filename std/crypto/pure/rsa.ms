/**
 * RSA key encodings (PKCS#1, PKCS#8, SPKI) and the RFC 8017 operations over key integers held as minimal
 * big-endian bytes. The arithmetic is `rsaArith`: `ff` limbs on C, BigInt on JavaScript.
 */

import {
	DerItem, derItem, derChildren, derRoot, derUnsigned, derSame, derSequence, derUnsignedInteger, derSmallInteger,
	derOctets, derBits, derOidOf, derTlv, derJoin, tagSequence, tagOctetString, tagBitString, tagNull, tagOid,
	oidRsaEncryption,
} from "./asn1";
import { RsaPublicData, RsaPrivateData, bytesBitLength, rsaModulusBytes, sameBytes, wipeBytes } from "./rsaKey";
import { rsaPublicOperation, rsaPrivateOperation, rsaKeyConsistent, rsaGenerateKey } from "./rsaArith";
import { randomOctets } from "./random";
import { hashKind, hashOf } from "./hash";
import { kindSha256 } from "./state";

export { RsaPublicData, RsaPrivateData, rsaModulusBytes } from "./rsaKey";

export const rsaMinBits: int32 = 2048;

// Byte order of minimal big-endian integers: a shorter one is smaller.
function below(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return a.length < b.length;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return a[i] < b[i];
	}
	return false;
}

function atLeastThree(value: Readonly<uint8[]>): boolean {
	return !below(value, [3]);
}

function publicFromSequence(buf: Readonly<uint8[]>, seq: DerItem): RsaPublicData | null {
	const parts = derChildren(buf, seq);
	if (parts == null || parts.length != 2) return null;
	const n = derUnsigned(buf, parts[0]);
	const e = derUnsigned(buf, parts[1]);
	if (n == null || e == null || bytesBitLength(n) < rsaMinBits || (n[n.length - 1] & 1) == 0) return null;
	if (!atLeastThree(e) || (e[e.length - 1] & 1) == 0 || !below(e, n)) return null;
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
	return parts[0].tag == tagOid && derSame(buf, parts[0], oidRsaEncryption()) && parts[1].tag == tagNull && parts[1].end == parts[1].body;
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
	return derSequence([derOidOf(oidRsaEncryption()), derTlv(tagNull, [])]);
}

export function rsaPublicToSpki(pub: RsaPublicData): uint8[] {
	const key = derSequence([derUnsignedInteger(pub.n), derUnsignedInteger(pub.e)]);
	return derSequence([rsaAlgorithm(), derBits(key)]);
}

function privateFromSequence(buf: Readonly<uint8[]>, seq: DerItem): RsaPrivateData | null {
	const parts = derChildren(buf, seq);
	if (parts == null || parts.length != 9) return null;
	const version = derUnsigned(buf, parts[0]);
	if (version == null || version.length != 1 || version[0] != 0) return null;
	const values: uint8[][] = [];
	for (let i = 1; i < 9; i++) {
		const value = derUnsigned(buf, parts[i]);
		if (value == null) return null;
		values.push(value);
	}
	const key: RsaPrivateData = { n: values[0], e: values[1], d: values[2], p: values[3], q: values[4], dp: values[5], dq: values[6], qi: values[7] };
	if (bytesBitLength(key.n) < rsaMinBits || !atLeastThree(key.p) || !atLeastThree(key.q)) return null;
	if (!rsaKeyConsistent(key)) return null;
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
		derSmallInteger(0), derUnsignedInteger(key.n), derUnsignedInteger(key.e), derUnsignedInteger(key.d),
		derUnsignedInteger(key.p), derUnsignedInteger(key.q), derUnsignedInteger(key.dp), derUnsignedInteger(key.dq),
		derUnsignedInteger(key.qi),
	]);
}

export function rsaPrivateToPkcs8(key: RsaPrivateData): uint8[] {
	return derSequence([derSmallInteger(0), rsaAlgorithm(), derOctets(rsaPrivateToPkcs1(key))]);
}

export function rsaPublicOf(key: RsaPrivateData): RsaPublicData {
	return { n: key.n, e: key.e };
}

const digestPrefixSha1: Readonly<uint8[]> = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14];
const digestPrefixSha256: Readonly<uint8[]> = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20];
const digestPrefixSha384: Readonly<uint8[]> = [0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30];
const digestPrefixSha512: Readonly<uint8[]> = [0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40];

function digestPrefix(hash: string): Readonly<uint8[]> | null {
	if (hash == "sha1") return digestPrefixSha1;
	if (hash == "sha256") return digestPrefixSha256;
	if (hash == "sha384") return digestPrefixSha384;
	if (hash == "sha512") return digestPrefixSha512;
	return null;
}

function xorInto(target: uint8[], mask: Readonly<uint8[]>): void {
	for (let i = 0; i < mask.length; i++) target[i] = (target[i] ^ mask[i]) as uint8;
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
	return rsaPrivateOperation(key, encoded);
}

export function rsaVerifyPkcs1(key: RsaPublicData, hash: string, message: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	const prefix = digestPrefix(hash);
	const size = rsaModulusBytes(key.n);
	if (prefix == null || signature.length != size) return false;
	const opened = rsaPublicOperation(key, signature);
	const expected = pkcs1Encoding(prefix, hashOf(hashKind(hash), message), size);
	if (opened == null || expected == null) return false;
	return sameBytes(opened, expected);
}

function pssLayout(n: Readonly<uint8[]>, hashSize: int32): int32 {
	return ((bytesBitLength(n) - 1 + 7) >> 3) - hashSize - 2;
}

export function rsaSignPss(key: RsaPrivateData, hash: string, message: Readonly<uint8[]>): uint8[] | null {
	if (digestPrefix(hash) == null) return null;
	const kind = hashKind(hash);
	const mHash = hashOf(kind, message);
	const hashSize = mHash.length as int32;
	const emBits = bytesBitLength(key.n) - 1;
	const emLength = (emBits + 7) >> 3;
	const zeros = pssLayout(key.n, hashSize) - hashSize;
	if (zeros < 0) return null;
	const salt = randomOctets(hashSize);
	const h = hashOf(kind, derJoin([new Array<uint8>(8), mHash, salt]));
	const block = derJoin([new Array<uint8>(zeros), [1] as uint8[], salt]);
	xorInto(block, mgf1(kind, h, emLength - hashSize - 1));
	block[0] = ((block[0] as int32) & (255 >> (8 * emLength - emBits))) as uint8;
	const encoded = derJoin([block, h, [0xbc] as uint8[]]);
	return rsaPrivateOperation(key, encoded);
}

export function rsaVerifyPss(key: RsaPublicData, hash: string, message: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	if (digestPrefix(hash) == null || signature.length != rsaModulusBytes(key.n)) return false;
	const kind = hashKind(hash);
	const mHash = hashOf(kind, message);
	const hashSize = mHash.length as int32;
	const emBits = bytesBitLength(key.n) - 1;
	const emLength = (emBits + 7) >> 3;
	if (emLength < hashSize + 2) return false;
	const m = rsaPublicOperation(key, signature);
	if (m == null || bytesBitLength(m) > emBits) return false;
	const encoded = m.slice(m.length - emLength);
	if (encoded[emLength - 1] != 0xbc) return false;
	const block = encoded.slice(0, emLength - hashSize - 1);
	const h = encoded.slice(emLength - hashSize - 1, emLength - 1);
	xorInto(block, mgf1(kind, h, block.length as int32));
	block[0] = ((block[0] as int32) & (255 >> (8 * emLength - emBits))) as uint8;
	let at = 0;
	while (at < block.length - 1 && block[at] == 0) at += 1;
	if (block[at] != 1) return false;
	const salt = block.slice(at + 1);
	return sameBytes(hashOf(kind, derJoin([new Array<uint8>(8), mHash, salt])), h);
}

export function rsaOaepEncrypt(key: RsaPublicData, message: Readonly<uint8[]>): uint8[] | null {
	const size = rsaModulusBytes(key.n);
	const fill = size - message.length - 66;
	if (fill < 0) return null;
	const labelHash = hashOf(kindSha256, []);
	const seed = randomOctets(32);
	const block = derJoin([labelHash, new Array<uint8>(fill), [1] as uint8[], message]);
	xorInto(block, mgf1(kindSha256, seed, size - 33));
	const maskedSeed = seed;
	xorInto(maskedSeed, mgf1(kindSha256, block, 32));
	const encoded = derJoin([[0] as uint8[], maskedSeed, block]);
	return rsaPublicOperation(key, encoded);
}

export function rsaOaepDecrypt(key: RsaPrivateData, ciphertext: Readonly<uint8[]>): uint8[] | null {
	const size = rsaModulusBytes(key.n);
	if (ciphertext.length != size || size < 66) return null;
	const encoded = rsaPrivateOperation(key, ciphertext);
	if (encoded == null) return null;
	const seed = encoded.slice(1, 33);
	const block = encoded.slice(33);
	xorInto(seed, mgf1(kindSha256, block, 32));
	xorInto(block, mgf1(kindSha256, seed, size - 33));
	const labelHash = hashOf(kindSha256, []);
	let bad = encoded[0] as int32;
	for (let i = 0; i < 32; i++) bad |= (block[i] ^ labelHash[i]) as int32;
	let inPadding = 1;
	let padding = 0;
	for (let i = 32; i < block.length - 1; i++) {
		inPadding &= (((block[i] as int32) - 1) >> 8) & 1;
		padding += inPadding;
	}
	const at = 32 + padding;
	bad |= (block[at] ^ 1) as int32;
	const message = bad == 0 ? block.slice(at + 1) : null;
	for (const scratch of [encoded, seed, block]) wipeBytes(scratch);
	return message;
}

export function rsaGenerate(bits: int32): RsaPrivateData {
	return rsaGenerateKey(bits);
}
