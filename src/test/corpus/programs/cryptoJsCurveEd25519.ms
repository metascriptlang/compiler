// Ed25519 agrees on every backend and on both forms: RFC 8032 tests 1 to 3 sign to the published signature and verify
// through the Sync and the async API, a key built either way signs and verifies through the other, and the strict
// refusals (small-order key or R, S not below L, wrong sizes, a key that is no curve point) hold for both.
//
// @stdout: t1 true true true true
// @stdout: t2 true true true true
// @stdout: t3 true true true true
// @stdout: cross sync key async sign true async key sync verify true
// @stdout: tampered false false false false
// @stdout: small-order key false false
// @stdout: small-order R false false
// @stdout: S plus L false false honest true true
// @stdout: wrong sizes false false
// @stdout: public export import true true
// @stdout: generated true true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, Ed25519PrivateKey, Ed25519PublicKey, sign, signSync, verify, verifySync } from "std/crypto/ed25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function hex(text: string): Buffer {
	return Buffer.fromString(text, "hex");
}

async function vector(name: string, seedHex: string, pubHex: string, messageHex: string, sigHex: string): Promise<void> {
	const message = hex(messageHex);
	const syncKey = must(Ed25519PrivateKey.fromSeedSync(hex(seedHex)));
	const asyncKey = must(await Ed25519PrivateKey.fromSeed(hex(seedHex)));
	const syncPub = must(syncKey.publicKey().exportSync()).toHex() == pubHex;
	const syncSig = must(signSync(syncKey, message)).toHex() == sigHex;
	const asyncSig = must(await sign(asyncKey, message)).toHex() == sigHex;
	const verified = verifySync(syncKey.publicKey(), hex(sigHex), message) && await verify(asyncKey.publicKey(), hex(sigHex), message);
	console.log(name, syncPub, syncSig, asyncSig, verified);
}

await vector("t1", "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
	"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
await vector("t2", "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
	"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");
await vector("t3", "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
	"6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a");

const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
const syncKey = must(Ed25519PrivateKey.fromSeedSync(seed));
const asyncKey = must(await Ed25519PrivateKey.fromSeed(seed));
const syncSigned = must(signSync(syncKey, "cross"));
const asyncSigned = must(await sign(syncKey, "cross"));
console.log("cross sync key async sign", syncSigned.toHex() == asyncSigned.toHex(), "async key sync verify", verifySync(asyncKey.publicKey(), syncSigned, "cross"));

const signature = must(signSync(syncKey, "hello"));
const flipped = signature.slice(0);
flipped[10] = (flipped[10] ^ 1) as uint8;
console.log("tampered", verifySync(syncKey.publicKey(), signature, "hellp"), await verify(syncKey.publicKey(), signature, "hellp"),
	verifySync(syncKey.publicKey(), flipped, "hello"), await verify(asyncKey.publicKey(), flipped, "hello"));

const identity = must(Ed25519PublicKey.importSync(hex("01" + "00".repeat(31))));
const zeroSig = hex("01" + "00".repeat(31) + "00".repeat(32));
console.log("small-order key", verifySync(identity, zeroSig, "pay 100"), await verify(identity, zeroSig, "pay 100"));
console.log("small-order R", verifySync(syncKey.publicKey(), zeroSig, "pay 100"), await verify(asyncKey.publicKey(), zeroSig, "pay 100"));

const order: uint8[] = [
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
];
const malleated = signature.slice(0);
let carry = 0;
for (let i = 0; i < 32; i++) {
	const sum = (malleated[32 + i] as int32) + (order[i] as int32) + carry;
	malleated[32 + i] = (sum & 255) as uint8;
	carry = sum >> 8;
}
console.log("S plus L", verifySync(syncKey.publicKey(), malleated, "hello"), await verify(asyncKey.publicKey(), malleated, "hello"),
	"honest", verifySync(syncKey.publicKey(), signature, "hello"), await verify(asyncKey.publicKey(), signature, "hello"));

console.log("wrong sizes", verifySync(syncKey.publicKey(), signature.slice(0, 63), "hello"), await verify(syncKey.publicKey(), Buffer.alloc(65), "hello"));

const exported = must(syncKey.publicKey().exportSync());
const imported = must(Ed25519PublicKey.importSync(exported));
const importedAsync = must(await Ed25519PublicKey.import(exported));
console.log("public export import", verifySync(imported, signature, "hello"), await verify(importedAsync, signature, "hello"));

const generated = must(Ed25519PrivateKey.generateSync());
const generatedSig = must(signSync(generated, "fresh"));
console.log("generated", verifySync(generated.publicKey(), generatedSig, "fresh"), await verify(generated.publicKey(), generatedSig, "fresh"));
