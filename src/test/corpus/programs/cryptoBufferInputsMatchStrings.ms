// A Buffer fed to digest, hmac, aes and chacha is read in place: its bytes reach the primitive
// exactly, high bytes and ill-formed UTF-8 included, and a string input gives the digest of its
// UTF-8 bytes. The sealed blob is written whole into an uninitialised output, so a 1 MiB round
// trip and a tampered tag pin that no stale byte survives.
//
// @stdout: bad-utf8 203ecd2a12ce01d4e1e4b2cafc4b6e9329f08f6935b32043073938fec0a76e13 7f667381cf4b6ad1bac0d14944af71ef03cbbe5f1abc31b16c65a8c60175bdb5
// @stdout: pattern 07f4465ef6fe98070beaf8d8d01454b5d11f6cd4ff86a139d92cd031b46ddfdc
// @stdout: text 432153d2dfe8f523419f5d46201f6f943a6192a486b13ac1f7d50cf832d03b4e fe8fe69a1005577e51f947551580544253e76c821f329a4d53e33ec8b2f9dcae19b42fcc8795db48dcddc157cd8a25727807a0e759544586f574f1756f331b8c true true
// @stdout: aes 41 true true false true 1048604 true false
// @stdout: chacha 53 true true false true 1048616 true false
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, digestSync, hmacSync, toHex } from "std/crypto";
import { AesKey, sealSync as aesSeal, openSync as aesOpen } from "std/crypto/aes";
import { ChaChaKey, sealSync as chachaSeal, openSync as chachaOpen } from "std/crypto/chacha20";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function sameBytes(a: Buffer, b: Buffer): boolean {
	return Buffer.compare(a, b) == 0;
}

const bad = Buffer.fromString("80ff00c0afeda080f4908080c3", "hex");
console.log("bad-utf8", toHex(must(digestSync("sha256", bad))), toHex(must(hmacSync("sha256", bad, bad))));

const pattern = Buffer.alloc(1048576);
for (let i = 0; i < pattern.length; i++) pattern[i] = ((i * 7 + i / 251) % 256) as uint8;
console.log("pattern", toHex(must(digestSync("sha256", pattern))));

const text = "é€😀 ß";
const textBytes = Buffer.fromString(text, "utf8");
const textDigest = must(digestSync("sha256", text));
const textHmac = must(hmacSync("sha512", text, text));
console.log("text", toHex(textDigest), toHex(textHmac),
	sameBytes(textDigest, must(digestSync("sha256", textBytes))),
	sameBytes(textHmac, must(hmacSync("sha512", textBytes, textBytes))));

const aesKey = must(AesKey.import("0123456789abcdef0123456789abcdef"));
const aesSmall = must(aesSeal(aesKey, bad, bad));
const aesText = must(aesSeal(aesKey, text, text));
const aesBig = must(aesSeal(aesKey, pattern, bad));
const aesForged = Buffer.copy(aesBig);
aesForged[aesForged.length - 1] = (aesForged[aesForged.length - 1] ^ 1) as uint8;
console.log("aes", aesSmall.length,
	sameBytes(must(aesOpen(aesKey, aesSmall, bad)), bad),
	sameBytes(must(aesOpen(aesKey, aesText, textBytes)), textBytes),
	aesOpen(aesKey, aesSmall, "").ok,
	sameBytes(must(aesOpen(aesKey, aesBig, bad)), pattern),
	aesBig.length,
	aesOpen(aesKey, aesBig, bad).ok,
	aesOpen(aesKey, aesForged, bad).ok);

const chachaKey = must(ChaChaKey.import("0123456789abcdef0123456789abcdef"));
const chachaSmall = must(chachaSeal(chachaKey, bad, bad));
const chachaText = must(chachaSeal(chachaKey, text, text));
const chachaBig = must(chachaSeal(chachaKey, pattern, bad));
const chachaForged = Buffer.copy(chachaBig);
chachaForged[chachaForged.length - 1] = (chachaForged[chachaForged.length - 1] ^ 1) as uint8;
console.log("chacha", chachaSmall.length,
	sameBytes(must(chachaOpen(chachaKey, chachaSmall, bad)), bad),
	sameBytes(must(chachaOpen(chachaKey, chachaText, textBytes)), textBytes),
	chachaOpen(chachaKey, chachaSmall, "").ok,
	sameBytes(must(chachaOpen(chachaKey, chachaBig, bad)), pattern),
	chachaBig.length,
	chachaOpen(chachaKey, chachaBig, bad).ok,
	chachaOpen(chachaKey, chachaForged, bad).ok);
