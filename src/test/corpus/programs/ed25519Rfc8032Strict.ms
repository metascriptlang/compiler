// Ed25519: RFC 8032 tests 1 and 2 sign and verify; a 64-byte secret key (seed plus a public half the
// caller chose) is refused where a seed is expected, so the public half always comes from the seed;
// a small-order public key with R = identity and S = 0 verifies no message.
//
// @stdout: t1 true true
// @stdout: t2 true true
// @stdout: 64-byte seed refused true pub equals honest true
// @stdout: small-order false false
// @stdout: small-order R false
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, Ed25519PrivateKey, Ed25519PublicKey, sign, verify } from "std/crypto/ed25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function hex(text: string): Buffer {
	return Buffer.fromString(text, "hex");
}

async function verifies(pub: Ed25519PublicKey, signature: Buffer, message: string | Buffer): Promise<boolean> {
	return await verify(pub, signature, message);
}

const seed1 = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
const pub1Hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
const pub1 = must(await Ed25519PublicKey.import(hex(pub1Hex)));
const sig1 = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
const key1 = must(await Ed25519PrivateKey.fromSeed(seed1));
const got1 = must(await sign(key1, ""));
console.log("t1", got1.toHex() == sig1, await verifies(pub1, hex(sig1), ""));

const seed2 = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
const pub2 = must(await Ed25519PublicKey.import(hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")));
const sig2 = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
const key2 = must(await Ed25519PrivateKey.fromSeed(seed2));
const got2 = must(await sign(key2, hex("72")));
console.log("t2", got2.toHex() == sig2, await verifies(pub2, hex(sig2), hex("72")));

const seedWithPublicHalf = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" + "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511b");
const refused = await Ed25519PrivateKey.fromSeed(seedWithPublicHalf);
console.log("64-byte seed refused", !refused.ok, "pub equals honest", must(await key1.publicKey().export()).toHex() == pub1Hex);

const identity = must(await Ed25519PublicKey.import(hex("01" + "00".repeat(31))));
const zeroSig = hex("01" + "00".repeat(31) + "00".repeat(32));
console.log("small-order", await verifies(identity, zeroSig, "pay 100"), await verifies(identity, zeroSig, "pay 999"));
console.log("small-order R", await verifies(key1.publicKey(), zeroSig, "pay 100"));
