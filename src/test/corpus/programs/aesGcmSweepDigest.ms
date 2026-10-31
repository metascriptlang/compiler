// AES-GCM seal agrees with the vendored mbedTLS gcm.c on every length 0..300 against every AAD
// length 0..40 under a fixed key and nonce, and open returns each plaintext. The digests were taken
// with the hardware path forced off, so a host that runs it (Arm AES+PMULL, x86 AES-NI+PCLMUL)
// must reproduce the generic bytes, and a host without it must too.
//
// @stdout: aes128 8117b942f0bd360bf8d3c06bb1dbce69a2264df9184760718fe61b343fe63b63 opened true
// @stdout: aes256 d7251f32bcb2d82b93b198fc5b9240359c5fec4c9dee66d071290548ce7ca9c0 opened true
// @exit: 0
// @skip-js: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.jms
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

@include("runtime/crypto/ciphers/aes.h");

import { Buffer } from "std/core/buffer";
import { rawString } from "std/core/buffer/bytes";
import { sha256, toHex } from "std/crypto";
import { open } from "std/crypto/aes";
import { newOutputBuffer, outputBytes } from "std/crypto/outputBuffer";

extern function msCryptoAesSealWithNonceInto(key: string, nonce: string, plainText: string, aad: string, out: Ptr<uint8>): int64;

function pattern(count: int32, salt: int32): Buffer {
	const out = newOutputBuffer(count as int64);
	for (let i: int32 = 0; i < count; i++) out[i] = ((i * 7 + salt) & 255) as uint8;
	return out;
}

function sweep(keyLength: int32): string {
	const key = rawString(pattern(keyLength, 1));
	const nonce = rawString(pattern(12, 99));
	let digest = "";
	let opened = true;
	for (let len: int32 = 0; len <= 300; len++) {
		const plain = pattern(len, 3);
		const plainText = rawString(plain);
		for (let aadLength: int32 = 0; aadLength <= 40; aadLength++) {
			const aad = rawString(pattern(aadLength, 200));
			const sealed = newOutputBuffer(12 + (len as int64) + 16);
			if (msCryptoAesSealWithNonceInto(key, nonce, plainText, aad, outputBytes(sealed)) != 1) throw new Error("seal failed");
			const back = open(key, sealed, aad);
			if (!back.ok || toHex(back.value) != toHex(plain)) opened = false;
			const next = sha256(digest + toHex(sealed));
			if (!next.ok) throw new Error("sha256 failed");
			digest = next.value;
		}
	}
	return `aes${keyLength * 8} ${digest} opened ${opened}`;
}

console.log(sweep(16));
console.log(sweep(32));
