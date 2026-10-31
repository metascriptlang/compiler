// Ed25519: RFC 8032 tests 1 and 2 sign and verify; a secret key whose stored public half was tampered
// signs exactly like the honest key (the public half is derived from the seed); a small-order public
// key with R = identity and S = 0 verifies no message.
//
// @stdout: t1 true true
// @stdout: t2 true true
// @stdout: tampered sig equals honest true pub equals honest true
// @stdout: small-order false false
// @stdout: small-order R false
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over mbedTLS and Monocypher); there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, fromHex, toHex } from "std/crypto";
import { ed25519FromSeed, ed25519PublicKey, ed25519Sign, ed25519Verify } from "std/crypto/ed25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const seed1 = fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
const pub1 = fromHex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
const sig1 = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
const key1 = must(ed25519FromSeed(seed1));
const got1 = must(ed25519Sign(key1, ""));
console.log("t1", toHex(got1) == sig1, ed25519Verify(fromHex(sig1), pub1, ""));

const seed2 = fromHex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
const pub2 = fromHex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
const sig2 = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
const key2 = must(ed25519FromSeed(seed2));
const got2 = must(ed25519Sign(key2, fromHex("72")));
console.log("t2", toHex(got2) == sig2, ed25519Verify(fromHex(sig2), pub2, fromHex("72")));

const tamperedKey = fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" + "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511b");
const tamperedSig = ed25519Sign(tamperedKey, "pay 100");
const honestSig = must(ed25519Sign(key1, "pay 100"));
console.log("tampered sig equals honest", tamperedSig.ok && toHex(tamperedSig.value) == toHex(honestSig),
	"pub equals honest", toHex(must(ed25519PublicKey(tamperedKey))) == toHex(pub1));

const identity = fromHex("01" + "00".repeat(31));
const zeroSig = fromHex("01" + "00".repeat(31) + "00".repeat(32));
console.log("small-order", ed25519Verify(zeroSig, identity, "pay 100"), ed25519Verify(zeroSig, identity, "pay 999"));
const honestPub = must(ed25519PublicKey(key1));
console.log("small-order R", ed25519Verify(zeroSig, honestPub, "pay 100"));
