// Async asymmetric calls composed with Promise.all: six keys generated, signed and verified at
// once, each result a key or a signature that verifies.
//
// @stdout: generated 6 signed 6 verified 6
// @exit: 0
// @skip-raiser: std/crypto/ec has a C and a JS backend and no ec.rms
// @xfail(san): Promise.all over Results never destroys their payloads (ledger EcPrivateKey alloc=6 destroy=0; no spawn involved), inbox card 2026-11-01-promise-all-of-spawned-results-leaks-their-payload

import { EcPrivateKey, ecdsaSign, ecdsaVerify } from "std/crypto/ec";

const generatedKeys = await Promise.all([
	EcPrivateKey.generate("p256"), EcPrivateKey.generate("p256"), EcPrivateKey.generate("p384"),
	EcPrivateKey.generate("p384"), EcPrivateKey.generate("p256"), EcPrivateKey.generate("p384"),
]);
const keys: EcPrivateKey[] = [];
for (const key of generatedKeys) {
	if (key.ok) keys.push(key.value);
}
if (keys.length != 6) throw new Error("EcPrivateKey.generate failed");

const signatures = await Promise.all([
	ecdsaSign(keys[0], "m0", "sha256"), ecdsaSign(keys[1], "m1", "sha256"),
	ecdsaSign(keys[2], "m2", "sha256"), ecdsaSign(keys[3], "m3", "sha256"),
	ecdsaSign(keys[4], "m4", "sha256"), ecdsaSign(keys[5], "m5", "sha256"),
]);
let signed = 0;
let verified = 0;
for (let i = 0; i < 6; i++) {
	const signature = signatures[i];
	if (!signature.ok) continue;
	signed += 1;
	const check = await ecdsaVerify(keys[i].publicKey(), `m${i}`, signature.value, "sha256");
	if (check) verified += 1;
}
console.log(`generated ${keys.length} signed ${signed} verified ${verified}`);
