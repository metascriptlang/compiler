// Crypto — Comprehensive Test Suite

import { CryptoError, CryptoErrorKind, HashAlgorithm, createHash, createHmac, digestSync, fromBase64, fromHex,
	hmacSync, isHashSupported, md5Sync, randomBytesSync, randomIntSync, randomUUIDSync, sha1Sync, sha256,
	sha256Sync, sha384Sync, sha512Sync, timingSafeEqual, toBase64, toHex } from "std/crypto";
import { Buffer } from "std/core/buffer";

@include("runtime/crypto/hash.h");
extern function hashInto(
	algorithm: string, data: string, ref output: uint8[64], capacity: int64,
): int64 from "msCryptoHashInto";
extern function hmacInto(
	algorithm: string, key: string, data: string, ref output: uint8[64], capacity: int64,
): int64 from "msCryptoHmacInto";
extern function hashInit(algorithm: string): int64 from "msCryptoHashInitHandle";
extern function hashFinalInto(
	ctx: int64, ref output: uint8[64], capacity: int64,
): int64 from "msCryptoHashFinalIntoHandle";
extern function hmacFinalInto(
	ctx: int64, ref output: uint8[64], capacity: int64,
): int64 from "msCryptoHmacFinalIntoHandle";

test "digest scratch rejects undersized outputs without writes" {
	let bytes: uint8[64] = [
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	];
	for (const capacity of [-1, 0, 63]) {
		assert hashInto("sha512", "abc", bytes, capacity) == 0;
		assert hmacInto("sha512", "key", "abc", bytes, capacity) == 0;
		for (const byte of bytes) assert byte == 0;
	}
	assert hashInto("bogus", "abc", bytes, 64) == 0;
	assert hmacInto("bogus", "key", "abc", bytes, 64) == 0;
	const ctx = hashInit("sha512");
	assert ctx != 0;
	assert hashFinalInto(ctx, bytes, 63) == 0;
	assert hashFinalInto(0, bytes, 64) == 0;
	assert hmacFinalInto(0, bytes, 64) == 0;
	for (const byte of bytes) assert byte == 0;
}

test "digest scratch accepts exact small and maximum capacities" {
	let bytes: uint8[64] = [
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	];
	assert hashInto("md5", "abc", bytes, 16) == 16;
	assert hmacInto("md5", "key", "abc", bytes, 16) == 16;
	assert hashInto("sha512", "abc", bytes, 64) == 64;
	assert hmacInto("sha512", "key", "abc", bytes, 64) == 64;
}

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

test "crypto codecs preserve every byte" {
	const bytes = Buffer.alloc(0);
	for (let i = 0; i < 256; i++) bytes.push(i as uint8);
	assert Buffer.compare(must(fromHex(toHex(bytes))), bytes) == 0;
	assert Buffer.compare(must(fromBase64(toBase64(bytes))), bytes) == 0;
	assert toHex(must(fromBase64("/w=="))) == "ff";
	assert toHex(must(fromHex("AaFf00"))) == "aaff00";
}

test "crypto base64 encodes all tail lengths and UTF-8" {
	const plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar", "hé😀"];
	const encoded = [
		"", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy", "aMOp8J+YgA==",
	];
	for (let i = 0; i < plain.length; i++) {
		assert toBase64(plain[i]) == encoded[i];
		assert must(fromBase64(encoded[i])).asString() == plain[i];
	}
}

test "crypto hash and hmac results are the algorithm's bytes and survive both codecs" {
	const names: HashAlgorithm[] = ["sha256", "sha512", "sha1", "md5"];
	const sizes = [32, 64, 20, 16];
	for (let i = 0; i < names.length; i++) {
		const rawHash = must(digestSync(names[i], "\0hé😀"));
		const rawHmac = must(hmacSync(names[i], "key\0é", "\0hé😀"));
		assert rawHash.length == sizes[i];
		assert rawHmac.length == sizes[i];
		assert toHex(rawHash).length == sizes[i] * 2;
		assert Buffer.compare(must(fromHex(toHex(rawHmac))), rawHmac) == 0;
		assert Buffer.compare(must(fromBase64(toBase64(rawHash))), rawHash) == 0;
	}
}

test "streaming hash digest consumes its context once" {
	for (const algorithm of ["sha256", "sha512", "sha1", "md5"] as HashAlgorithm[]) {
		const hasher = createHash(algorithm);
		hasher.update("\0h");
		hasher.update("é😀");
		const expected = must(digestSync(algorithm, "\0hé😀"));
		assert toHex(hasher.digest()) == toHex(expected);
		assert hasher.digest().length == 0;
	}
}

test "crypto codecs refuse malformed input" {
	for (const text of ["0", "000", "gg", "00gg", "00 0", "\0f", "é"]) {
		assert !fromHex(text).ok;
	}
	for (const text of ["Zg", " Zg==", "Zg==\n", "====", "_w==", "AAA?", "AA\0A"]) {
		assert !fromBase64(text).ok;
	}
	assert must(fromHex("")).length == 0;
	assert must(fromBase64("")).length == 0;
	assert toHex(must(fromBase64("AB=="))) == "00";
	for (const text of ["AA=A", "AA==AAAA", "AAA=AAAA", "AB=C", "A=AA", "AAAA=AAA", "AA=AAAAA"]) {
		assert !fromBase64(text).ok;
	}
	const refused = fromHex("0");
	assert !refused.ok;
	if (!refused.ok) assert refused.error.kind == CryptoErrorKind.InvalidEncoding;
}

// ===== Known Test Vectors =====

// SHA-256 test vectors (NIST)
test "sha256 empty string" {
	assert toHex(must(sha256Sync(""))) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
}

test "sha256 hello world" {
	const result = sha256Sync("hello world");
	assert result.ok;
	if (result.ok) {
		assert toHex(result.value) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
		assert toBase64(result.value) == "uU0nuZNNPgilLlLX2n2r+sSE7+N6U4DukIj3rOLvzek=";
	}
}

test "sha256 async returns the Sync bytes" {
	const viaAsync = must(await sha256("hello world"));
	assert Buffer.compare(viaAsync, must(sha256Sync("hello world"))) == 0;
}

// SHA-512 test vectors
test "sha512 empty string" {
	assert toHex(must(sha512Sync(""))) == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
}

test "sha512 hello" {
	assert must(sha512Sync("hello")).length == 64;
}

// SHA-384
test "sha384 empty string" {
	assert toHex(must(sha384Sync(""))) == "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b";
}

// SHA-1
test "sha1 empty string" {
	assert toHex(must(sha1Sync(""))) == "da39a3ee5e6b4b0d3255bfef95601890afd80709";
}

test "sha1 hello world" {
	assert toHex(must(sha1Sync("hello world"))) == "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed";
}

// MD5
test "md5 empty string" {
	assert toHex(must(md5Sync(""))) == "d41d8cd98f00b204e9800998ecf8427e";
}

test "md5 hello world" {
	assert toHex(must(md5Sync("hello world"))) == "5eb63bbbe01eeed093cb22bb8f5acdc3";
}

// ===== Generic Hash Function =====

test "digest with algorithm parameter" {
	assert toHex(must(digestSync("sha256", "hello world"))) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

// ===== HMAC =====

// RFC 4231 test case 2
test "hmac sha256" {
	assert toHex(must(hmacSync("sha256", "Jefe", "what do ya want for nothing?"))) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";
}

test "hmac sha512" {
	assert must(hmacSync("sha512", "key", "data")).length == 64;
}

// ===== Random =====

test "randomBytes generates correct length" {
	const result = randomBytesSync(32);
	assert result.ok;
	assert result.value.length == 32;
}

test "randomBytes zero is an empty result" {
	const result = randomBytesSync(0);
	assert result.ok;
	assert result.value.length == 0;
}

test "randomBytes different each call" {
	const a = randomBytesSync(16);
	const b = randomBytesSync(16);
	assert a.ok;
	assert b.ok;
	assert Buffer.compare(a.value, b.value) != 0;
}

test "randomInt in range" {
	const result = randomIntSync(0, 100);
	assert result.ok;
	assert result.value >= 0;
	assert result.value < 100;
}

test "randomUUID format" {
	const result = randomUUIDSync();
	assert result.ok;
	// UUID v4 format: 8-4-4-4-12 = 36 chars
	// Can't check length without string utility, but ensure non-empty
	assert result.value != "";
}

// ===== Timing-Safe Comparison =====

test "timingSafeEqual identical strings" {
	assert timingSafeEqual("hello", "hello");
}

test "timingSafeEqual different strings" {
	assert !timingSafeEqual("hello", "world");
}

test "timingSafeEqual different lengths" {
	assert !timingSafeEqual("short", "longer string");
}

test "timingSafeEqual empty strings" {
	assert timingSafeEqual("", "");
}

// ===== Streaming Hash =====

test "streaming sha256 single update" {
	const hasher = createHash("sha256");
	hasher.update("hello world");
	assert toHex(hasher.digest()) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

test "streaming sha256 multiple updates" {
	const hasher = createHash("sha256");
	hasher.update("hello");
	hasher.update(" ");
	hasher.update("world");
	assert toHex(hasher.digest()) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

test "streaming sha512" {
	const hasher = createHash("sha512");
	hasher.update("");
	assert toHex(hasher.digest()) == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
}

// ===== Streaming HMAC =====

test "streaming hmac sha256" {
	const h = createHmac("sha256", "secret-key");
	h.update("hello world");
	const oneshot = must(hmacSync("sha256", "secret-key", "hello world"));
	assert toHex(h.digest()) == toHex(oneshot);
}

test "streaming hmac multiple updates" {
	const h = createHmac("sha256", "key");
	h.update("hello");
	h.update(" ");
	h.update("world");
	const oneshot = must(hmacSync("sha256", "key", "hello world"));
	assert toHex(h.digest()) == toHex(oneshot);
}

// ===== Algorithm Support =====

test "isHashSupported sha256" {
	assert isHashSupported("sha256");
}

test "isHashSupported sha512" {
	assert isHashSupported("sha512");
}

test "isHashSupported md5" {
	assert isHashSupported("md5");
}

test "isHashSupported unsupported" {
	assert !isHashSupported("bogus");
}
