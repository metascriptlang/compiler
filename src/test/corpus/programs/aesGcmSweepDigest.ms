// AES-GCM seal agrees with the vendored mbedTLS gcm.c on every length 0..300 against every AAD
// length 0..40 under a fixed key and nonce, and open returns each plaintext. The digests were taken
// with the hardware path forced off, so a host that runs it (Arm AES+PMULL, x86 AES-NI+PCLMUL)
// must reproduce the generic bytes, and a host without it must too.
//
// @stdout: aes128 8117b942f0bd360bf8d3c06bb1dbce69a2264df9184760718fe61b343fe63b63 opened true
// @stdout: aes256 d7251f32bcb2d82b93b198fc5b9240359c5fec4c9dee66d071290548ce7ca9c0 opened true
// @exit: 0
// @skip-js: the fixed-nonce seal is the C test seam msCryptoAesSealWithNonceInto; cryptoJsAesSweep pins the same digests through the portable seal
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

@include("runtime/crypto/ciphers/aes.h");

import { Buffer } from "std/core/buffer";
import { rawString } from "std/core/buffer/bytes";
import { sha256 } from "std/crypto/sha256";
import { AesKey, open } from "std/crypto/aes";
import { newUninitOutputBuffer, outputBytes } from "std/crypto/outputBuffer";

extern function msCryptoAesSealWithNonceInto(key: int64, nonce: string, plainText: string, aad: string, out: Ptr<uint8>): int64;

function pattern(count: int32, salt: int32): Buffer {
	const out = newUninitOutputBuffer(count as int64);
	for (let i: int32 = 0; i < count; i++) out[i] = ((i * 7 + salt) & 255) as uint8;
	return out;
}

async function sweep(keyLength: int32): Promise<string> {
	const imported = AesKey.import(pattern(keyLength, 1));
	if (!imported.ok) throw new Error("import failed");
	const key = imported.value;
	const nonce = rawString(pattern(12, 99));
	let digest = "";
	let opened = true;
	for (let len: int32 = 0; len <= 300; len++) {
		const plain = pattern(len, 3);
		const plainText = rawString(plain);
		for (let aadLength: int32 = 0; aadLength <= 40; aadLength++) {
			const aad = rawString(pattern(aadLength, 200));
			const sealed = newUninitOutputBuffer(12 + (len as int64) + 16);
			if (msCryptoAesSealWithNonceInto(key._handle, nonce, plainText, aad, outputBytes(sealed)) != 1) throw new Error("seal failed");
			const back = await open(key, sealed, aad);
			if (!back.ok || back.value.toHex() != plain.toHex()) opened = false;
			digest = sha256(Buffer.fromString(digest + sealed.toHex(), "utf8")).toHex();
		}
	}
	return `aes${keyLength * 8} ${digest} opened ${opened}`;
}

console.log(await sweep(16));
console.log(await sweep(32));
