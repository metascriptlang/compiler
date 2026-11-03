// The async hmac, random and key-derivation functions complete inside the async function with what the Sync form
// (or the published vector) gives: RFC 4231 test case 2, RFC 6070 c=1, RFC 5869 case 1.
//
// @stdout: hmac 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843 true
// @stdout: pbkdf2 0c60c80f961f0e71f3a9b524af6012062fe037a6
// @stdout: hkdf 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
// @stdout: randomBytes 32 true
// @stdout: randomInt true
// @stdout: randomUUID 36 true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the hash family; no hmac, random or key derivation

@passC("-Werror=incompatible-pointer-types");

import { Buffer } from "std/core/buffer";
import { CryptoError, fromHex, hkdf, hmac, hmacSync, pbkdf2, randomBytes, randomInt, randomUUID, toHex } from "std/crypto";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const mac = must(await hmac("sha256", "Jefe", "what do ya want for nothing?"));
console.log("hmac", toHex(mac), toHex(mac) == toHex(must(hmacSync("sha256", "Jefe", "what do ya want for nothing?"))));
console.log("pbkdf2", toHex(must(await pbkdf2("password", "salt", 1, 20, "sha1"))));
const ikm = must(fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"));
const salt = must(fromHex("000102030405060708090a0b0c"));
const info = must(fromHex("f0f1f2f3f4f5f6f7f8f9"));
console.log("hkdf", toHex(must(await hkdf("sha256", ikm, salt, info, 42))));

const a = must(await randomBytes(32));
const b = must(await randomBytes(32));
console.log("randomBytes", a.length, Buffer.compare(a, b) != 0);
const n = must(await randomInt(10, 20));
console.log("randomInt", n >= 10 && n < 20);
const uuid = must(await randomUUID());
console.log("randomUUID", uuid.length, uuid.charAt(14) == "4");
