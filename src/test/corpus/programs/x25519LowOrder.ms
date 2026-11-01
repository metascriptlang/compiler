// X25519: the RFC 7748 6.1 vectors agree on 4a5d9d5b...; a low-order public key (all-zero and the
// order-8 point) is refused instead of returning an all-zero shared secret.
//
// @stdout: rfc7748 true true
// @stdout: export true true
// @stdout: low-order zero false
// @stdout: low-order order8 false
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, X25519PrivateKey, X25519PublicKey, sharedSecret } from "std/crypto/x25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function hex(text: string): Buffer {
	return Buffer.fromString(text, "hex");
}

const alice = must(await X25519PrivateKey.fromRaw(hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")));
const bob = must(await X25519PrivateKey.fromRaw(hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")));
const expected = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
const aliceSecret = must(await sharedSecret(alice, bob.publicKey()));
const bobSecret = must(await sharedSecret(bob, alice.publicKey()));
console.log("rfc7748", aliceSecret.toHex() == expected, bobSecret.toHex() == expected);

const zero = must(await X25519PublicKey.import(hex("00".repeat(32))));
const order8 = must(await X25519PublicKey.import(hex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")));
const order8Hex = "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800";
console.log("export", must(await order8.export()).toHex() == order8Hex, must(await alice.publicKey().export()).toHex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
console.log("low-order zero",(await sharedSecret(alice, zero)).ok);
console.log("low-order order8", (await sharedSecret(alice, order8)).ok);
