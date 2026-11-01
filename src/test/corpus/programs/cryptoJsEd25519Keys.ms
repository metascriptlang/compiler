// Ed25519 keys behave the same on the C backend (Monocypher) and on JS (WebCrypto): a generated key signs and verifies,
// a changed message or signature fails, the exported seed rebuilds the same public key, a seed or public key of the
// wrong size is refused, and a signature whose S has L added (the same signature, malleated) is refused.
//
// @stdout: generated sign verify true
// @stdout: tampered message false
// @stdout: flipped signature byte false
// @stdout: seed round trip true
// @stdout: wrong sizes refused true true true
// @stdout: malleated S refused false honest S accepted true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs
import { Buffer } from "std/core/buffer";
import { CryptoError, Ed25519PrivateKey, Ed25519PublicKey, sign, verify } from "std/crypto/ed25519";
import { toHex } from "std/crypto";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const key = must(await Ed25519PrivateKey.generate());
const signature = must(await sign(key, "hello"));
console.log("generated sign verify", await verify(key.publicKey(), signature, "hello"));
console.log("tampered message", await verify(key.publicKey(), signature, "hellp"));
const flipped = signature.slice(0);
flipped[10] = (flipped[10] ^ 1) as uint8;
console.log("flipped signature byte", await verify(key.publicKey(), flipped, "hello"));

const seed = must(await key.exportSeed());
const rebuilt = must(await Ed25519PrivateKey.fromSeed(seed));
console.log("seed round trip", toHex(must(await rebuilt.publicKey().export())) == toHex(must(await key.publicKey().export())));

const shortSeed = await Ed25519PrivateKey.fromSeed(Buffer.alloc(31));
const longSeed = await Ed25519PrivateKey.fromSeed(Buffer.alloc(33));
const shortPublic = await Ed25519PublicKey.import(Buffer.alloc(31));
console.log("wrong sizes refused", !shortSeed.ok, !longSeed.ok, !shortPublic.ok);

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
console.log("malleated S refused", await verify(key.publicKey(), malleated, "hello"), "honest S accepted", await verify(key.publicKey(), signature, "hello"));
