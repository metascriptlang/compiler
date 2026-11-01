// A spawn worker cannot run a promise-returning thunk, so it signs with the Sync forms: ecdsaSignSync and ed25519
// signSync run on the worker, and the main thread verifies what the worker returns.
//
// @stdout: ecdsa worker signature verified true
// @stdout: ed25519 worker signature verified true matches main true
// @exit: 0
// @skip-js: std/crypto/ec has no JS tier yet, and std/crypto/ed25519 has no *Sync forms on JS
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family and cannot spawn

import { CryptoError, fromHex, toHex } from "std/crypto";
import { EcPrivateKey, ecdsaSignSync, ecdsaVerify } from "std/crypto/ec";
import { Ed25519PrivateKey, signSync as edSignSync, verify as edVerify } from "std/crypto/ed25519";

function must<T>(r: Result<T, CryptoError>): T {
	if (!r.ok) throw new Error(`unexpected error: ${r.error.message}`);
	return r.value;
}

const seed = "0123456789abcdef0123456789abcdef";

function ecdsaOnWorker(pem: string): string {
	const key = EcPrivateKey.importPemSync(pem);
	if (!key.ok) return "";
	const sig = ecdsaSignSync(key.value, "message", "sha256");
	return sig.ok ? toHex(sig.value) : "";
}

function ed25519OnWorker(workerSeed: string): string {
	const key = Ed25519PrivateKey.fromSeedSync(workerSeed);
	if (!key.ok) return "";
	const sig = edSignSync(key.value, "message");
	return sig.ok ? toHex(sig.value) : "";
}

const ecKey = must((await EcPrivateKey.generate("p256")));
const pem = must((await ecKey.exportPem()));
const ecHex = await spawn(() => ecdsaOnWorker(pem));
const ecSig = fromHex(ecHex);
console.log(`ecdsa worker signature verified ${await ecdsaVerify(ecKey.publicKey(), "message", must(ecSig), "sha256")}`);

const edKey = must((await Ed25519PrivateKey.fromSeed(seed)));
const edHex = await spawn(() => ed25519OnWorker(seed));
const edSig = fromHex(edHex);
const mainSig = edSignSync(edKey, "message");
console.log(`ed25519 worker signature verified ${await edVerify(edKey.publicKey(), must(edSig), "message")} matches main ${edHex == toHex(must(mainSig))}`);
