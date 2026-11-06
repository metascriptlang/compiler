// @stdout: hmac 9c196e32dc0175f8 9c196e32dc0175f8 9c196e32dc0175f8 fd7adb152c05ef80 fd7adb152c05ef80
// @stdout: equal true true false true
// @stdout: stream c490aea7e19cad1b c1206bd0275fbfed
// @stdout: kdf 061df616343cb988307172e2c3074be6 true fe8f9615d2374c0d17f77d1aeaf408c2 true
// @stdout: async ba7816bf8f01cfea 9c196e32dc0175f8 061df616343cb988307172e2c3074be6 fe8f9615d2374c0d17f77d1aeaf408c2
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the hash family; hmac, the streaming forms and key derivation are absent there

import { Buffer } from "std/core/buffer";
import { CryptoError, createHash, createHmac, hkdf, hkdfSync, hmac, hmacSync, pbkdf2, pbkdf2Sync, sha256, timingSafeEqual, toHex } from "std/crypto";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function head(digest: Buffer): string {
	return toHex(digest).slice(0, 16);
}

function ascii(text: string): Uint8Array {
	const bytes = text.asBytes();
	const out = new Uint8Array(bytes.length);
	for (let i = 0; i < bytes.length; i++) out[i] = bytes[i];
	return out;
}

const key = ascii("key");
const keyVec: uint8[] = [107, 101, 121];
const data = ascii("abc");
const none = new Uint8Array(0);

console.log("hmac", head(must(hmacSync("sha256", "key", "abc"))), head(must(hmacSync("sha256", key, "abc"))),
	head(must(hmacSync("sha256", keyVec, data))), head(must(hmacSync("sha256", none, data))), head(must(hmacSync("sha256", "", "abc"))));

console.log("equal", timingSafeEqual("abc", data), timingSafeEqual(none, ""), timingSafeEqual(key, data), timingSafeEqual(keyVec, key));

const hasher = createHash("sha256").update("abc").update(data.subarray(1, 3));
const mac = createHmac("sha256", key).update(data).update("bc");
console.log("stream", head(hasher.digest()), head(mac.digest()));

const derived = must(pbkdf2Sync(ascii("pw"), "salt", 2, 16, "sha256"));
const expanded = must(hkdfSync("sha256", ascii("ikm"), "salt", ascii("info"), 16));
console.log("kdf", toHex(derived), Buffer.compare(derived, must(pbkdf2Sync("pw", ascii("salt"), 2, 16, "sha256"))) == 0,
	toHex(expanded), Buffer.compare(expanded, must(hkdfSync("sha256", "ikm", ascii("salt"), "info", 16))) == 0);

const ad = await sha256(data);
const am = await hmac("sha256", key, data);
const ap = await pbkdf2(ascii("pw"), ascii("salt"), 2, 16, "sha256");
const ah = await hkdf("sha256", "ikm", "salt", ascii("info"), 16);
console.log("async", head(must(ad)), head(must(am)), toHex(must(ap)), toHex(must(ah)));
