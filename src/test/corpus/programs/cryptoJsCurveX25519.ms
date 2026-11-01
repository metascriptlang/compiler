// X25519 agrees on every backend and on both forms: the RFC 7748 5.2 and 6.1 vectors come out the same through the
// Sync and the async API, a key built either way agrees with a key built the other way, and every low-order public
// key is refused instead of returning an all-zero shared secret.
//
// @stdout: rfc7748 5.2 true true
// @stdout: rfc7748 5.2 true true
// @stdout: rfc7748 6.1 true true true true true true
// @stdout: mixed forms true true
// @stdout: low-order refused 7 7
// @stdout: generated agree true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, X25519PrivateKey, X25519PublicKey, sharedSecret, sharedSecretSync } from "std/crypto/x25519";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function hex(text: string): Buffer {
	return Buffer.fromString(text, "hex");
}

async function vector52(scalarHex: string, uHex: string, outHex: string): Promise<void> {
	const syncOut = must(sharedSecretSync(must(X25519PrivateKey.fromRawSync(hex(scalarHex))), must(X25519PublicKey.importSync(hex(uHex)))));
	const asyncOut = must(await sharedSecret(must(await X25519PrivateKey.fromRaw(hex(scalarHex))), must(await X25519PublicKey.import(hex(uHex)))));
	console.log("rfc7748 5.2", syncOut.toHex() == outHex, asyncOut.toHex() == outHex);
}

await vector52("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
	"c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
await vector52("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d", "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
	"95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957");

const alicePrivate = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a";
const bobPrivate = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb";
const aliceSync = must(X25519PrivateKey.fromRawSync(hex(alicePrivate)));
const bobSync = must(X25519PrivateKey.fromRawSync(hex(bobPrivate)));
const aliceAsync = must(await X25519PrivateKey.fromRaw(hex(alicePrivate)));
const bobAsync = must(await X25519PrivateKey.fromRaw(hex(bobPrivate)));
const shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
console.log("rfc7748 6.1",
	must(aliceSync.publicKey().exportSync()).toHex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
	must(bobSync.publicKey().exportSync()).toHex() == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f",
	must(sharedSecretSync(aliceSync, bobSync.publicKey())).toHex() == shared,
	must(sharedSecretSync(bobSync, aliceSync.publicKey())).toHex() == shared,
	must(await sharedSecret(aliceAsync, bobAsync.publicKey())).toHex() == shared,
	must(await sharedSecret(bobAsync, aliceAsync.publicKey())).toHex() == shared);

console.log("mixed forms", must(await sharedSecret(aliceSync, bobAsync.publicKey())).toHex() == shared, must(sharedSecretSync(bobAsync, aliceSync.publicKey())).toHex() == shared);

const lowOrder = [
	"00".repeat(32),
	"01" + "00".repeat(31),
	"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
	"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
];
let refusedSync = 0;
let refusedAsync = 0;
for (const point of lowOrder) {
	if (!sharedSecretSync(aliceSync, must(X25519PublicKey.importSync(hex(point)))).ok) refusedSync++;
	if (!(await sharedSecret(aliceAsync, must(await X25519PublicKey.import(hex(point))))).ok) refusedAsync++;
}
console.log("low-order refused", refusedSync, refusedAsync);

const first = must(X25519PrivateKey.generateSync());
const second = must(await X25519PrivateKey.generate());
console.log("generated agree", must(sharedSecretSync(first, second.publicKey())).toHex() == must(await sharedSecret(second, first.publicKey())).toHex());
