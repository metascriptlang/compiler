// X25519: the RFC 7748 6.1 vectors agree on 4a5d9d5b...; a low-order public key (all-zero and the
// order-8 point) is refused instead of returning an all-zero shared secret.
//
// @stdout: rfc7748 true true
// @stdout: low-order zero false
// @stdout: low-order order8 false
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over mbedTLS and Monocypher); there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { CryptoError, fromHex, toHex } from "std/crypto";
import { x25519PublicKey, x25519SharedSecret } from "std/crypto/x25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const alice = fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
const bob = fromHex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
const alicePublic = must(x25519PublicKey(alice));
const bobPublic = must(x25519PublicKey(bob));
const expected = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
console.log("rfc7748", toHex(must(x25519SharedSecret(alice, bobPublic))) == expected, toHex(must(x25519SharedSecret(bob, alicePublic))) == expected);

console.log("low-order zero", x25519SharedSecret(alice, fromHex("00".repeat(32))).ok);
console.log("low-order order8", x25519SharedSecret(alice, fromHex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")).ok);
