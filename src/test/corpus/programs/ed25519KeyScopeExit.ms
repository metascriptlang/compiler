// A key that goes out of scope is destroyed once: Ed25519 and X25519 private keys and the public keys
// taken from them are made, used and dropped by scope exit, a thousand times. Under SAN a missing
// destroy is a leak and a second one is a double free; the DRC ledger must balance.
//
// @stdout: scopes 1000 signed 1000 agreed 1000
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over mbedTLS and Monocypher); there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { Ed25519PrivateKey, sign, verify } from "std/crypto/ed25519";
import { X25519PrivateKey, sharedSecret } from "std/crypto/x25519";

let signed = 0;
let agreed = 0;

async function signScope(): Promise<void> {
	const key = await Ed25519PrivateKey.generate();
	if (!key.ok) return;
	const signature = await sign(key.value, "x");
	if (!signature.ok) return;
	const checked = await verify(key.value.publicKey(), signature.value, "x");
	if (checked) signed += 1;
}

async function agreeScope(): Promise<void> {
	const a = await X25519PrivateKey.generate();
	const b = await X25519PrivateKey.generate();
	if (!a.ok || !b.ok) return;
	const ab = await sharedSecret(a.value, b.value.publicKey());
	const ba = await sharedSecret(b.value, a.value.publicKey());
	if (ab.ok && ba.ok && Buffer.compare(ab.value, ba.value) == 0) agreed += 1;
}

for (let i = 0; i < 1000; i++) {
	await signScope();
	await agreeScope();
}
console.log(`scopes 1000 signed ${signed} agreed ${agreed}`);
