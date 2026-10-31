// @stdout: 0102ff 0102ff 3034
// @stdout: 4f9d true true false
// @stdout: true 8
// @stdout: true true
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over mbedTLS and Monocypher); there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Bytes APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, hashBuffer, hmacBuffer, sha256, timingSafeEqual, toHex } from "std/crypto";
import { decode } from "std/serialize/cbor";
import { cborBytes } from "std/serialize/cbor/builder";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const plain: uint8[] = [1, 2, 255];
const branded = plain as Buffer;
console.log(toHex(plain), toHex(branded), toHex("04"));

const key: uint8[] = [107, 101, 121];
const viaPlain = toHex(must(hmacBuffer("sha256", key, plain)));
const viaBuffer = toHex(must(hmacBuffer("sha256", key as Buffer, branded)));
console.log(viaPlain.slice(0, 4), viaPlain == viaBuffer, timingSafeEqual(plain, branded), timingSafeEqual(plain, "abc"));
console.log(must(sha256(plain)) == must(sha256(branded)), toHex(must(hashBuffer("sha256", plain))).length / 8);

const wire: uint8[] = [0x18, 0x2a];
console.log(decode(wire).ok, decode(wire as Buffer).ok);
