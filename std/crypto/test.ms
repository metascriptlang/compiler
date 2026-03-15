import { hash, sha256, sha512, sha1, md5, hmac, randomBytes, randomInt, randomUUID, pbkdf2, hkdf, toHex, fromHex, toBase64, fromBase64, timingSafeEqual } from "std/crypto";
import { CryptoErrorKind } from "std/crypto/errors";

test "sha256 empty string" {
	const result = sha256("", "hex");
	assert result.ok;
	assert result.value === "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
}

test "sha256 hello" {
	const result = sha256("hello", "hex");
	assert result.ok;
	assert result.value === "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
}

test "sha512 hello" {
	const result = sha512("hello", "hex");
	assert result.ok;
	assert result.value === "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043";
}

test "sha1 hello" {
	const result = sha1("hello", "hex");
	assert result.ok;
	assert result.value === "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d";
}

test "md5 hello" {
	const result = md5("hello", "hex");
	assert result.ok;
	assert result.value === "5d41402abc4b2a76b9719d911017c592";
}

test "hash with base64 encoding" {
	const result = sha256("hello", "base64");
	assert result.ok;
	assert result.value === "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=";
}

test "hash invalid algorithm" {
	const result = hash("invalid", "hello", "hex");
	assert !result.ok;
	assert result.error.kind === CryptoErrorKind.HashFailed;
}

test "hash default encoding" {
	const result = hash("sha256", "hello", "");
	assert result.ok;
	assert result.value === "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
}

test "hmac sha256" {
	const result = hmac("sha256", "key", "hello", "hex");
	assert result.ok;
	assert result.value.length === 64;
}

test "hmac invalid algorithm" {
	const result = hmac("invalid", "key", "data", "hex");
	assert !result.ok;
}

test "randomBytes produces output" {
	const result = randomBytes(32);
	assert result.ok;
	// Verify via hex encoding (32 bytes = 64 hex chars)
	const hex = toHex(result.value);
	assert hex.length === 64;
}

test "randomBytes different each call" {
	const a = randomBytes(16);
	const b = randomBytes(16);
	assert a.ok;
	assert b.ok;
	assert toHex(a.value) !== toHex(b.value);
}

test "randomInt in range" {
	const result = randomInt(10, 20);
	assert result.ok;
	assert result.value >= 10;
	assert result.value < 20;
}

test "randomInt invalid range" {
	const result = randomInt(20, 10);
	assert !result.ok;
}

test "randomUUID format" {
	const result = randomUUID();
	assert result.ok;
	assert result.value.length === 36;
}

test "hex encode/decode roundtrip" {
	const original = "hello world";
	const hexed = toHex(original);
	const decoded = fromHex(hexed);
	assert decoded === original;
}

test "hex known value" {
	assert toHex("AB") === "4142";
}

test "base64 encode/decode roundtrip" {
	const original = "hello world";
	const encoded = toBase64(original);
	const decoded = fromBase64(encoded);
	assert decoded === original;
}

test "base64 known value" {
	assert toBase64("hello") === "aGVsbG8=";
}

test "timingSafeEqual true" {
	assert timingSafeEqual("hello", "hello");
}

test "timingSafeEqual false" {
	assert !timingSafeEqual("hello", "world");
}

test "timingSafeEqual different lengths" {
	assert !timingSafeEqual("short", "longer");
}

test "timingSafeEqual empty" {
	assert timingSafeEqual("", "");
}

test "pbkdf2 produces output" {
	const result = pbkdf2("password", "salt", 1000, 32, "sha256");
	assert result.ok;
	// 32 bytes = 64 hex chars
	assert toHex(result.value).length === 64;
}

test "hkdf produces output" {
	const result = hkdf("sha256", "input key material", "salt", "info", 32);
	assert result.ok;
	// 32 bytes = 64 hex chars
	assert toHex(result.value).length === 64;
}
