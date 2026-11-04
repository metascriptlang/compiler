// The pure AES against the public std/crypto/aes surface: on C that is the vendored mbedTLS (with AES-NI or the
// ARMv8 AES extension where the CPU has them) and runtime/crypto/ciphers/aesGcmHw.c; on JS its `*Sync` forms are this
// pure code, so there the run only proves the two entry points agree.

import { expandKey, expandKeyDecrypt, gcmSealWithNonce, gcmOpen, cbcEncrypt, cbcDecrypt } from "./aes";
import { AesKey, CryptoError, sealSync, openSync, cbcEncryptSync, cbcDecryptSync } from "../aes";
import { Buffer } from "std/core/buffer";

class Rng {
	state: uint32 = 0x9e3779b9;
}

function nextWord(rng: Rng): uint32 {
	let x = rng.state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	rng.state = x;
	return x;
}

function randomBytes(rng: Rng, size: int32): Buffer {
	const out = Buffer.alloc(size);
	for (let i = 0; i < size; i++) out[i] = (nextWord(rng) & 0xff) as uint8;
	return out;
}

function keyOf(raw: Buffer): AesKey {
	const key = AesKey.import(raw);
	if (!key.ok) throw new Error(key.error.message);
	return key.value;
}

function bytesOf(result: Result<Buffer, CryptoError>, what: string): Buffer {
	if (!result.ok) throw new Error(`${what}: ${result.error.message}`);
	return result.value;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

function lengths(): int32[] {
	const out: int32[] = [];
	for (let n = 0; n <= 48; n++) out.push(n);
	for (const edge of [63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2047, 2048]) out.push(edge);
	return out;
}

class Count {
	cases: int32 = 0;
	mismatches: string[] = [];
}

function gcmRound(rng: Rng, keySize: int32, size: int32, count: Count): void {
	const raw = randomBytes(rng, keySize);
	const key = keyOf(raw);
	const xk = expandKey(raw);
	const plain = randomBytes(rng, size);
	const aad = randomBytes(rng, (nextWord(rng) % 40) as int32);
	const vendor = bytesOf(sealSync(key, plain, aad), "sealSync");
	const pure = gcmSealWithNonce(xk, vendor.slice(0, 12), plain, aad);
	const label = `gcm key=${keySize} size=${size}`;
	count.cases += 1;
	if (!sameBytes(vendor, pure)) count.mismatches.push(`${label}: sealed bytes differ`);
	const opened = gcmOpen(xk, vendor, aad);
	if (opened == null || !sameBytes(opened, plain)) count.mismatches.push(`${label}: pure open of the vendor blob`);
	const back = openSync(key, pure, aad);
	if (!back.ok || !sameBytes(back.value, plain)) count.mismatches.push(`${label}: vendor open of the pure blob`);
	const forged = pure.slice(0);
	const at = (nextWord(rng) % (forged.length as uint32)) as int32;
	forged[at] = forged[at] ^ ((1 << (nextWord(rng) % 8)) as uint8);
	if (gcmOpen(xk, forged, aad) != null || openSync(key, forged, aad).ok) count.mismatches.push(`${label}: a forged byte at ${at} was accepted`);
}

function cbcRound(rng: Rng, keySize: int32, size: int32, count: Count): void {
	const raw = randomBytes(rng, keySize);
	const key = keyOf(raw);
	const iv = randomBytes(rng, 16);
	const plain = randomBytes(rng, size);
	const label = `cbc key=${keySize} size=${size}`;
	count.cases += 1;
	const vendor = bytesOf(cbcEncryptSync(key, plain, iv), "cbcEncryptSync");
	const pure = cbcEncrypt(expandKey(raw), iv, plain);
	if (!sameBytes(vendor, pure)) count.mismatches.push(`${label}: cipher text differs`);
	const xkD = expandKeyDecrypt(raw);
	const opened = cbcDecrypt(xkD, iv, vendor);
	if (opened == null || !sameBytes(opened, plain)) count.mismatches.push(`${label}: pure decrypt of the vendor cipher text`);
	const forged = Buffer.copy(vendor);
	forged[forged.length - 1] = forged[forged.length - 1] ^ ((1 + nextWord(rng) % 255) as uint8);
	const pureForged = cbcDecrypt(xkD, iv, forged);
	const vendorForged = cbcDecryptSync(key, forged, iv);
	if ((pureForged == null) != !vendorForged.ok) count.mismatches.push(`${label}: accept/reject differs on a forged last byte`);
	if (pureForged != null && vendorForged.ok && !sameBytes(pureForged, vendorForged.value)) count.mismatches.push(`${label}: forged plain text differs`);
}

test "pure AES-GCM and AES-CBC match the public surface on seeded random inputs" {
	const rng = new Rng();
	const count = new Count();
	for (const keySize of [16, 32]) {
		for (const size of lengths()) {
			gcmRound(rng, keySize, size, count);
			cbcRound(rng, keySize, size, count);
		}
	}
	console.log(`aes differential: ${count.cases} cases, ${count.mismatches.length} mismatches`);
	for (const line of count.mismatches) console.log(`  ${line}`);
	assert count.mismatches.length == 0;
}
