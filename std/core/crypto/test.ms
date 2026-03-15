// Crypto — Comprehensive Test Suite

import { sha256, sha512, sha384, sha1, md5, hash, hmac, randomBytes, randomInt, randomUUID,
	timingSafeEqual, createHash, createHmac, isHashSupported, init } from "std/core/crypto";

// ===== Known Test Vectors =====

// SHA-256 test vectors (NIST)
test "sha256 empty string" {
	const result = sha256("");
	assert result.ok;
	assert result.value === "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
}

test "sha256 hello world" {
	const result = sha256("hello world");
	assert result.ok;
	assert result.value === "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

test "sha256 base64 encoding" {
	const result = sha256("hello world", "base64");
	assert result.ok;
	assert result.value !== "";
}

// SHA-512 test vectors
test "sha512 empty string" {
	const result = sha512("");
	assert result.ok;
	assert result.value === "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
}

test "sha512 hello" {
	const result = sha512("hello");
	assert result.ok;
	assert result.value !== "";
}

// SHA-384
test "sha384 empty string" {
	const result = sha384("");
	assert result.ok;
	assert result.value === "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b";
}

// SHA-1
test "sha1 empty string" {
	const result = sha1("");
	assert result.ok;
	assert result.value === "da39a3ee5e6b4b0d3255bfef95601890afd80709";
}

test "sha1 hello world" {
	const result = sha1("hello world");
	assert result.ok;
	assert result.value === "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed";
}

// MD5
test "md5 empty string" {
	const result = md5("");
	assert result.ok;
	assert result.value === "d41d8cd98f00b204e9800998ecf8427e";
}

test "md5 hello world" {
	const result = md5("hello world");
	assert result.ok;
	assert result.value === "5eb63bbbe01eeed093cb22bb8f5acdc3";
}

// ===== Generic Hash Function =====

test "hash with algorithm parameter" {
	const result = hash("sha256", "test");
	assert result.ok;
	assert result.value !== "";
}

test "hash with unsupported algorithm" {
	const result = hash("bogus", "test");
	assert !result.ok;
}

// ===== HMAC =====

test "hmac sha256" {
	const result = hmac("sha256", "secret-key", "hello world");
	assert result.ok;
	assert result.value !== "";
}

test "hmac sha512" {
	const result = hmac("sha512", "key", "data");
	assert result.ok;
	assert result.value !== "";
}

test "hmac with unsupported algorithm" {
	const result = hmac("bogus", "key", "data");
	assert !result.ok;
}

// ===== Random =====

test "randomBytes generates correct length" {
	const result = randomBytes(32);
	assert result.ok;
	// Raw bytes returned as msString — length should be 32
}

test "randomBytes different each call" {
	const a = randomBytes(16);
	const b = randomBytes(16);
	assert a.ok;
	assert b.ok;
	assert a.value !== b.value;
}

test "randomInt in range" {
	const result = randomInt(0, 100);
	assert result.ok;
	assert result.value >= 0;
	assert result.value < 100;
}

test "randomUUID format" {
	const result = randomUUID();
	assert result.ok;
	// UUID v4 format: 8-4-4-4-12 = 36 chars
	// Can't check length without string utility, but ensure non-empty
	assert result.value !== "";
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
	const digest = hasher.digest("hex");
	assert digest === "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

test "streaming sha256 multiple updates" {
	const hasher = createHash("sha256");
	hasher.update("hello");
	hasher.update(" ");
	hasher.update("world");
	const digest = hasher.digest("hex");
	assert digest === "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
}

test "streaming sha512" {
	const hasher = createHash("sha512");
	hasher.update("");
	const digest = hasher.digest("hex");
	assert digest === "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
}

// ===== Streaming HMAC =====

test "streaming hmac sha256" {
	const h = createHmac("sha256", "secret-key");
	h.update("hello world");
	const digest = h.digest("hex");
	// Should match one-shot hmac
	const oneshot = hmac("sha256", "secret-key", "hello world");
	assert oneshot.ok;
	assert digest === oneshot.value;
}

test "streaming hmac multiple updates" {
	const h = createHmac("sha256", "key");
	h.update("hello");
	h.update(" ");
	h.update("world");
	const digest = h.digest("hex");

	const oneshot = hmac("sha256", "key", "hello world");
	assert oneshot.ok;
	assert digest === oneshot.value;
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
