// HMAC (RFC 4231, RFC 2202), PBKDF2 (RFC 6070) and HKDF (RFC 5869) vectors agree on the C backend and on JS, where
// the async forms run WebCrypto and the Sync forms the portable code: each value is checked in both forms, the
// empty HMAC key and empty HKDF input (which WebCrypto refuses) still derive, and createHmac in uneven chunks equals
// the one-shot MAC.
//
// @stdout: hmac sha256 true true
// @stdout: hmac sha512 true true
// @stdout: hmac sha1 true true
// @stdout: hmac md5 true true
// @stdout: hmac long key true true
// @stdout: hmac empty key true true
// @stdout: pbkdf2 sha1 c=1 true true
// @stdout: pbkdf2 sha1 c=4096 true true
// @stdout: pbkdf2 sha256 c=1 true true
// @stdout: pbkdf2 empty password true true
// @stdout: hkdf case 1 true true
// @stdout: hkdf empty salt and info true true
// @stdout: hkdf empty ikm true true
// @stdout: streaming hmac true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs
import { Buffer } from "std/core/buffer";
import { CryptoError, HashAlgorithm, createHmac, hkdf, hkdfSync, hmac, hmacSync, pbkdf2, pbkdf2Sync, toHex } from "std/crypto";

function same(result: Result<Buffer, CryptoError>, expected: string): boolean {
	return result.ok && toHex(result.value) == expected;
}

async function checkHmac(label: string, algorithm: HashAlgorithm, key: Buffer, data: string, expected: string): Promise<void> {
	console.log(label, same(hmacSync(algorithm, key, data), expected), same(await hmac(algorithm, key, data), expected));
}

async function checkPbkdf2(label: string, digest: HashAlgorithm, password: string, salt: string, iterations: int32, length: int32, expected: string): Promise<void> {
	console.log(label, same(pbkdf2Sync(password, salt, iterations, length, digest), expected), same(await pbkdf2(password, salt, iterations, length, digest), expected));
}

function repeated(count: int32, value: uint8): Buffer {
	const out = Buffer.alloc(count);
	for (let i = 0; i < count; i++) out[i] = value;
	return out;
}

const short = repeated(20, 0x0b);
await checkHmac("hmac sha256", "sha256", short, "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
await checkHmac("hmac sha512", "sha512", short, "Hi There", "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
await checkHmac("hmac sha1", "sha1", short, "Hi There", "b617318655057264e28bc0b6fb378c8ef146be00");
await checkHmac("hmac md5", "md5", repeated(16, 0x0b), "Hi There", "9294727a3638bb1c13f48ef8158bfc9d");
await checkHmac("hmac long key", "sha256", repeated(131, 0xaa), "Test Using Larger Than Block-Size Key - Hash Key First", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
await checkHmac("hmac empty key", "sha256", Buffer.alloc(0), "", "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");

await checkPbkdf2("pbkdf2 sha1 c=1", "sha1", "password", "salt", 1, 20, "0c60c80f961f0e71f3a9b524af6012062fe037a6");
await checkPbkdf2("pbkdf2 sha1 c=4096", "sha1", "password", "salt", 4096, 20, "4b007901b765489abead49d926f721d065a429c1");
await checkPbkdf2("pbkdf2 sha256 c=1", "sha256", "password", "salt", 1, 32, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
await checkPbkdf2("pbkdf2 empty password", "sha256", "", "salt", 2, 20, "62384466264daadc4144018c6bd864648272b34d");

const salt = Buffer.alloc(13);
for (let i = 0; i < 13; i++) salt[i] = i as uint8;
const info = Buffer.alloc(10);
for (let i = 0; i < 10; i++) info[i] = (0xf0 + i) as uint8;
const okm1 = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865";
console.log("hkdf case 1", same(hkdfSync("sha256", repeated(22, 0x0b), salt, info, 42), okm1), same(await hkdf("sha256", repeated(22, 0x0b), salt, info, 42), okm1));
const okm3 = "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8";
console.log("hkdf empty salt and info", same(hkdfSync("sha256", repeated(22, 0x0b), "", "", 42), okm3), same(await hkdf("sha256", repeated(22, 0x0b), "", "", 42), okm3));
const emptyIkm = "";
const viaSync = hkdfSync("sha256", emptyIkm, "salt", "info", 42);
const viaAsync = await hkdf("sha256", emptyIkm, "salt", "info", 42);
console.log("hkdf empty ikm", viaSync.ok && viaAsync.ok, viaSync.ok && viaAsync.ok && toHex(viaSync.value) == toHex(viaAsync.value));

const streamed = createHmac("sha256", "key");
streamed.update("The quick brown ");
streamed.update("");
streamed.update("fox jumps over the lazy dog");
const oneShot = hmacSync("sha256", "key", "The quick brown fox jumps over the lazy dog");
console.log("streaming hmac", oneShot.ok && toHex(streamed.digest()) == toHex(oneShot.value));
