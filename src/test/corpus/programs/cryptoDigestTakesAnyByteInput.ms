// @stdout: string ba7816bf8f01cfea uint8array ba7816bf8f01cfea vec ba7816bf8f01cfea span ba7816bf8f01cfea
// @stdout: either ba7816bf8f01cfea 1e0bbd6c686ba050 bytes ba7816bf8f01cfea e3b0c44298fc1c14
// @stdout: text 616263 616263 YWJj YWJj
// @exit: 0

import { Bytes } from "std/core/buffer/bytes";
import { Buffer } from "std/core/buffer";
import { CryptoError, digestSync, sha256Sync, toHex, toBase64 } from "std/crypto";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function head(digest: Buffer): string {
	return toHex(digest).slice(0, 16);
}

function viaSpan(s: Readonly<Span<uint8>>): string {
	return head(must(digestSync("sha256", s)));
}

function either(text: boolean): string | Uint8Array {
	if (text) return "abc";
	const u = new Uint8Array(2);
	u[0] = 98;
	u[1] = 99;
	return u;
}

function bytes(text: boolean): Bytes {
	if (text) return "abc";
	const empty: uint8[] = [];
	return empty;
}

const vec: uint8[] = [97, 98, 99];
const u = new Uint8Array(4);
u[0] = 120;
u[1] = 97;
u[2] = 98;
u[3] = 99;
const abc = u.subarray(1, 4);

console.log("string", head(must(sha256Sync("abc"))), "uint8array", head(must(sha256Sync(abc))),
	"vec", head(must(sha256Sync(vec))), "span", viaSpan(abc));
console.log("either", head(must(sha256Sync(either(true)))), head(must(sha256Sync(either(false)))),
	"bytes", head(must(sha256Sync(bytes(true)))), head(must(sha256Sync(bytes(false)))));
console.log("text", toHex("abc"), toHex(abc), toBase64(vec), toBase64(abc));
