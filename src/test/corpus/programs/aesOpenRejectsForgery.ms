// AES-GCM `open` accepts a sealed blob only when its tag verifies: an empty plaintext is a valid
// result, so a forged or AAD-mismatched blob must fail even when its ciphertext is empty.
//
// @stdout: 16 empty genuine true forged false aad false|16 text genuine true forged false aad false|32 empty genuine true forged false aad false|32 text genuine true forged false aad false
// @exit: 0
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

import { AesKey, seal, open } from "std/crypto/aes";

function zeros(count: int32): string {
	let out = "";
	for (let i: int32 = 0; i < count; i++) out += "\x00";
	return out;
}

async function row(raw: string, plainText: string): Promise<string> {
	const imported = AesKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	const key = imported.value;
	const sealed = await seal(key, plainText, "header");
	if (!sealed.ok) throw new Error("seal failed");
	const genuine = await open(key, sealed.value, "header");
	const genuineOk = genuine.ok && genuine.value.asString() == plainText;
	const forged = await open(key, zeros(sealed.value.length), "header");
	const wrongAad = await open(key, sealed.value, "other");
	const label = plainText.byteLength == 0 ? "empty" : "text";
	return `${raw.byteLength} ${label} genuine ${genuineOk} forged ${forged.ok} aad ${wrongAad.ok}`;
}

const key16 = "0123456789abcdef";
const key32 = "0123456789abcdef0123456789abcdef";
console.log([await row(key16, ""), await row(key16, "attack at dawn"), await row(key32, ""), await row(key32, "attack at dawn")].join("|"));
