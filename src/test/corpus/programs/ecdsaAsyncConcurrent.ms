// The async asymmetric calls run on worker threads: concurrent key generation and signing in one
// process must each return a key or a signature that verifies, with no call made on the main thread
// first.
//
// @stdout: generated 6 signed 6 verified 6
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms
// @xfail(san): Promise.all over spawned Results never destroys their Buffers (ledger msUint8ArrayRefCell alloc=6 destroy=0), inbox card 2026-11-01-promise-all-of-spawned-results-leaks-their-payload

import { ecGenerateAsync, ecdsaSignAsync, ecdsaVerify, ecFree } from "std/crypto/rsa";

const generatedKeys = await Promise.all([
	ecGenerateAsync("p256"), ecGenerateAsync("p256"), ecGenerateAsync("p384"),
	ecGenerateAsync("p384"), ecGenerateAsync("p256"), ecGenerateAsync("p384"),
]);
const handles: int64[] = [];
for (const key of generatedKeys) {
	if (key.ok) handles.push(key.value);
}
if (handles.length != 6) throw new Error("ecGenerateAsync failed");

const signatures = await Promise.all([
	ecdsaSignAsync(handles[0], "m0", "sha256"), ecdsaSignAsync(handles[1], "m1", "sha256"),
	ecdsaSignAsync(handles[2], "m2", "sha256"), ecdsaSignAsync(handles[3], "m3", "sha256"),
	ecdsaSignAsync(handles[4], "m4", "sha256"), ecdsaSignAsync(handles[5], "m5", "sha256"),
]);
let signed = 0;
let verified = 0;
for (let i = 0; i < 6; i++) {
	const signature = signatures[i];
	if (!signature.ok) continue;
	signed += 1;
	if (ecdsaVerify(handles[i], `m${i}`, signature.value, "sha256")) verified += 1;
}
console.log(`generated ${handles.length} signed ${signed} verified ${verified}`);
for (const handle of handles) ecFree(handle);
