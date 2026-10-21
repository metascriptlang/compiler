// AES-GCM `open` accepts a sealed blob only when its tag verifies: an empty plaintext is a valid
// result, so a forged or AAD-mismatched blob must fail even when its ciphertext is empty.
//
// @stdout: 16 empty genuine true forged false aad false|16 text genuine true forged false aad false|32 empty genuine true forged false aad false|32 text genuine true forged false aad false
// @exit: 0
// @skip-js: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.jms
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

import { seal, open } from "std/crypto/aes";

function zeros(count: int32): string {
	let out = "";
	for (let i: int32 = 0; i < count; i++) out += "\x00";
	return out;
}

function row(key: string, plainText: string): string {
	const sealed = seal(key, plainText, "header");
	if (!sealed.ok) throw new Error("seal failed");
	const genuine = open(key, sealed.value, "header");
	const genuineOk = genuine.ok && genuine.value == plainText;
	const forged = open(key, zeros(sealed.value.byteLength), "header");
	const wrongAad = open(key, sealed.value, "other");
	const label = plainText.byteLength == 0 ? "empty" : "text";
	return `${key.byteLength} ${label} genuine ${genuineOk} forged ${forged.ok} aad ${wrongAad.ok}`;
}

const key16 = "0123456789abcdef";
const key32 = "0123456789abcdef0123456789abcdef";
console.log([row(key16, ""), row(key16, "attack at dawn"), row(key32, ""), row(key32, "attack at dawn")].join("|"));
