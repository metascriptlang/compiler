// AES agrees across forms and backends: the portable seal reproduces the NIST SP 800-38D blobs (cases 2, 4, 14, 16)
// byte for byte, CBC gives the NIST SP 800-38A first blocks, every `*Sync` form and its async twin accept each
// other's output and refuse the same forgeries with the same error kind, and a GCM blob and a CBC cipher text
// sealed by the C backend (mbedTLS) open on whichever backend runs this.
//
// @stdout: nist case2 true|case4 true|case14 true|case16 true
// @stdout: cbc128 true true true|cbc256 true true true
// @stdout: aes128 sizes true|aes256 sizes true
// @stdout: short true true|tag true true|aad true true|cbc pad true true|cbc ragged true true|cbc empty true true|iv true true
// @stdout: from C gcm true true cbc true true
// @exit: 0
// @skip-raiser: std/crypto has no raiser Buffer API and std/crypto/aes has no raiser backend

import { Buffer } from "std/core/buffer";
import { CryptoError, fromHex, toHex } from "std/crypto";
import { AesKey, seal, open, sealSync, openSync, cbcEncrypt, cbcDecrypt, cbcEncryptSync, cbcDecryptSync } from "std/crypto/aes";
import { expandKey, gcmSealWithNonce } from "std/crypto/pure/aes";

function bytes(hex: string): Buffer {
	const decoded = fromHex(hex);
	if (!decoded.ok) throw new Error("bad hex");
	return decoded.value;
}

function importKey(raw: Buffer): AesKey {
	const imported = AesKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	return imported.value;
}

function pattern(count: int32, salt: int32): Buffer {
	const out = Buffer.alloc(count);
	for (let i: int32 = 0; i < count; i++) out[i] = ((i * 7 + salt) & 255) as uint8;
	return out;
}

function flip(blob: Buffer, index: int32): Buffer {
	const copy = Buffer.copy(blob);
	copy[index] = (copy[index] ^ 1) as uint8;
	return copy;
}

function nist(name: string, keyHex: string, nonceHex: string, plainHex: string, aadHex: string, bodyHex: string, tagHex: string): string {
	const sealed = gcmSealWithNonce(expandKey(bytes(keyHex)), bytes(nonceHex), bytes(plainHex), bytes(aadHex));
	return `${name} ${toHex(sealed as Buffer) == nonceHex + bodyHex + tagHex}`;
}

const message = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
const header = "feedfacedeadbeeffeedfacedeadbeefabaddad2";
const nonce = "cafebabefacedbaddecaf888";
const zeroNonce = "000000000000000000000000";
const key128 = "feffe9928665731c6d6a8f9467308308";
console.log([
	nist("nist case2", "00".repeat(16), zeroNonce, "00".repeat(16), "", "0388dace60b6a392f328c2b971b2fe78", "ab6e47d42cec13bdf53a67b21257bddf"),
	nist("case4", key128, nonce, message, header, "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091", "5bc94fbc3221a5db94fae95ae7121a47"),
	nist("case14", "00".repeat(32), zeroNonce, "00".repeat(16), "", "cea7403d4d606b6e074ec5d3baf39d18", "d0d1c8a799996bf0265b98b5d48ab919"),
	nist("case16", key128 + key128, nonce, message, header, "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662", "76fc6ece0f4e1768cddf8853bb2d551b"),
].join("|"));

async function cbcVector(name: string, keyHex: string, expected: string): Promise<string> {
	const key = importKey(bytes(keyHex));
	const iv = bytes("000102030405060708090a0b0c0d0e0f");
	const plain = bytes("6bc1bee22e409f96e93d7e117393172a");
	const viaSync = cbcEncryptSync(key, plain, iv);
	const viaAsync = await cbcEncrypt(key, plain, iv);
	const syncOk = viaSync.ok && toHex(viaSync.value.slice(0, 16)) == expected;
	const asyncOk = viaAsync.ok && toHex(viaAsync.value.slice(0, 16)) == expected;
	const back = viaSync.ok ? await cbcDecrypt(key, viaSync.value, iv) : null;
	return `${name} ${syncOk} ${asyncOk} ${back != null && back.ok && toHex(back.value) == toHex(plain)}`;
}

console.log([
	await cbcVector("cbc128", "2b7e151628aed2a6abf7158809cf4f3c", "7649abac8119b246cee98e9b12e9197d"),
	await cbcVector("cbc256", "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", "f58c4c04d6e5f1ba779eabfb5f7bfbd6"),
].join("|"));

async function sizes(keyLength: int32): Promise<string> {
	const key = importKey(pattern(keyLength, 5));
	const iv = pattern(16, 77);
	let good = true;
	for (const size of [0, 1, 15, 16, 17, 31, 32, 33, 255, 4096, 65536]) {
		const plain = pattern(size, 9);
		const hex = toHex(plain);
		const a = sealSync(key, plain, "aad");
		const b = await seal(key, plain, "aad");
		if (!a.ok || !b.ok || a.value.length != size + 28 || b.value.length != size + 28) {
			good = false;
			continue;
		}
		const crossA = await open(key, a.value, "aad");
		const crossB = openSync(key, b.value, "aad");
		if (!crossA.ok || toHex(crossA.value) != hex || !crossB.ok || toHex(crossB.value) != hex) good = false;
		const ca = cbcEncryptSync(key, plain, iv);
		const cb = await cbcEncrypt(key, plain, iv);
		if (!ca.ok || !cb.ok || toHex(ca.value) != toHex(cb.value) || ca.value.length != size + 16 - (size % 16)) {
			good = false;
			continue;
		}
		const da = cbcDecryptSync(key, cb.value, iv);
		const db = await cbcDecrypt(key, ca.value, iv);
		if (!da.ok || toHex(da.value) != hex || !db.ok || toHex(db.value) != hex) good = false;
	}
	return `aes${keyLength * 8} sizes ${good}`;
}

console.log(`${await sizes(16)}|${await sizes(32)}`);

function kindOf(result: Result<Buffer, CryptoError>): number {
	return result.ok ? -1 : result.error.kind as number;
}

async function sameKind(sync: Result<Buffer, CryptoError>, async: Promise<Result<Buffer, CryptoError>>): Promise<string> {
	const viaAsync = kindOf(await async);
	const viaSync = kindOf(sync);
	return `${viaSync >= 0} ${viaSync == viaAsync}`;
}

const key = importKey(pattern(32, 21));
const sealed = sealSync(key, "attack at dawn", "aad");
if (!sealed.ok) throw new Error("seal failed");
const ivBytes = pattern(16, 3);
const cbcSealed = cbcEncryptSync(key, "attack at dawn", ivBytes);
if (!cbcSealed.ok) throw new Error("cbc failed");
const lastBlock = cbcSealed.value.length - 1;
const padCorrupt = flip(cbcSealed.value, lastBlock);
console.log([
	`short ${await sameKind(openSync(key, sealed.value.slice(0, 27), "aad"), open(key, sealed.value.slice(0, 27), "aad"))}`,
	`tag ${await sameKind(openSync(key, flip(sealed.value, sealed.value.length - 1), "aad"), open(key, flip(sealed.value, sealed.value.length - 1), "aad"))}`,
	`aad ${await sameKind(openSync(key, sealed.value, "other"), open(key, sealed.value, "other"))}`,
	`cbc pad ${await sameKind(cbcDecryptSync(key, padCorrupt, ivBytes), cbcDecrypt(key, padCorrupt, ivBytes))}`,
	`cbc ragged ${await sameKind(cbcDecryptSync(key, cbcSealed.value.slice(0, 15), ivBytes), cbcDecrypt(key, cbcSealed.value.slice(0, 15), ivBytes))}`,
	`cbc empty ${await sameKind(cbcDecryptSync(key, "", ivBytes), cbcDecrypt(key, "", ivBytes))}`,
	`iv ${await sameKind(cbcEncryptSync(key, "x", "short"), cbcEncrypt(key, "x", "short"))}`,
].join("|"));

const cGcm = "898523be310ed97aeb5031f17ec81f10eb604dcf4a7e66015e162029b8da1c9c432117221d9adb2da517d9e811410d47536f1ef2d3298bd04bb2002a2dd853dcaf";
const cCbc = "0964d7e8052a9b35ea05414b42fc8f7e985eb15f0f2fabea9aefa8e88967913b91873cb8e3669cdc93f47de3f97bcaa4";
const cKey = importKey(Buffer.fromString("0123456789abcdef0123456789abcdef", "utf8"));
const wanted = "sealed on the C backend, opened on JS";
const gcmAsync = await open(cKey, bytes(cGcm), "hdr");
const gcmSync = openSync(cKey, bytes(cGcm), "hdr");
const cbcAsync = await cbcDecrypt(cKey, bytes(cCbc), "fedcba9876543210");
const cbcSync = cbcDecryptSync(cKey, bytes(cCbc), "fedcba9876543210");
console.log(`from C gcm ${gcmAsync.ok && gcmAsync.value.asString() == wanted} ${gcmSync.ok && gcmSync.value.asString() == wanted} cbc ${cbcAsync.ok && cbcAsync.value.asString() == wanted} ${cbcSync.ok && cbcSync.value.asString() == wanted}`);
