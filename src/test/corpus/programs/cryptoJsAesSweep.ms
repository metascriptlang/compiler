// The portable AES-GCM (the code the JS `*Sync` forms run) reproduces the vendored mbedTLS digests of
// aesGcmSweepDigest on every length 0..300 against every AAD length 0..40 under a fixed key and nonce, and the
// backend's own async `open` and `openSync` accept every blob. JS has no fixed-nonce seal in the module (the
// C test seam msCryptoAesSealWithNonceInto does not exist there), so the blobs come from the portable
// `gcmSealWithNonce` that `sealSync` calls; the expected digests were produced by mbedTLS on C.
//
// @stdout: aes128 8117b942f0bd360bf8d3c06bb1dbce69a2264df9184760718fe61b343fe63b63 opened true true
// @stdout: aes256 d7251f32bcb2d82b93b198fc5b9240359c5fec4c9dee66d071290548ce7ca9c0 opened true true
// @exit: 0
// @skip-raiser: std/crypto/aes has no raiser backend (index.cms and index.jms only)

import { Buffer } from "std/core/buffer";
import { sha256Sync, toHex } from "std/crypto";
import { AesKey, open, openSync } from "std/crypto/aes";
import { expandKey, gcmSealWithNonce } from "std/crypto/pure/aes";

function pattern(count: int32, salt: int32): Buffer {
	const out = Buffer.alloc(count);
	for (let i: int32 = 0; i < count; i++) out[i] = ((i * 7 + salt) & 255) as uint8;
	return out;
}

async function sweep(keyLength: int32): Promise<string> {
	const raw = pattern(keyLength, 1);
	const imported = AesKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	const key = imported.value;
	const schedule = expandKey(raw);
	const nonce = pattern(12, 99);
	let digest = "";
	let opened = true;
	let openedSync = true;
	for (let len: int32 = 0; len <= 300; len++) {
		const plain = pattern(len, 3);
		const plainHex = toHex(plain);
		for (let aadLength: int32 = 0; aadLength <= 40; aadLength++) {
			const aad = pattern(aadLength, 200);
			const sealed = gcmSealWithNonce(schedule, nonce, plain, aad) as Buffer;
			const back = await open(key, sealed, aad);
			if (!back.ok || toHex(back.value) != plainHex) opened = false;
			const backSync = openSync(key, sealed, aad);
			if (!backSync.ok || toHex(backSync.value) != plainHex) openedSync = false;
			const next = sha256Sync(digest + toHex(sealed));
			if (!next.ok) throw new Error("sha256 failed");
			digest = toHex(next.value);
		}
	}
	return `aes${keyLength * 8} ${digest} opened ${opened} ${openedSync}`;
}

console.log(await sweep(16));
console.log(await sweep(32));
