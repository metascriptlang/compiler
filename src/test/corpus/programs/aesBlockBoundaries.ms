// AES-GCM seal and open stay byte-identical to the portable implementation at lengths on both sides
// of the 8-block (128 byte) and 64-block (1024 byte) boundaries of the hardware path, under AES-128
// and AES-256 with and without AAD. The digest comes from the portable `gcmSealWithNonce` and is
// equal on every backend; the backend's own `seal` must reproduce the portable bytes under the
// nonce it drew, and its `open` must accept the portable blobs.
//
// @stdout: aes128 a8884408d25bdbd8c896c010b0a6ce4497d1387bb175bcf37a38db8e1a0c3b16 sealMatches true opened true
// @stdout: aes256 b95034d1cc3b0cac423e8e9bef4da4e5a5c75c916b7dd46f4b8fba13017bfbc8 sealMatches true opened true
// @exit: 0
// @skip-raiser: std/crypto/aes has no raiser backend (index.cms and index.jms only)

import { Buffer } from "std/core/buffer";
import { sha256Sync, toHex } from "std/crypto";
import { AesKey, open, seal } from "std/crypto/aes";
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
	let sealMatches = true;
	let opened = true;
	for (const len of [127, 128, 129, 255, 256, 257, 1023, 1024, 1025]) {
		const plain = pattern(len, 3);
		for (const aadLength of [0, 17]) {
			const aad = pattern(aadLength, 200);
			const reference = gcmSealWithNonce(schedule, nonce, plain, aad) as Buffer;
			const back = await open(key, reference, aad);
			if (!back.ok || toHex(back.value) != toHex(plain)) opened = false;
			const sealed = await seal(key, plain, aad);
			if (!sealed.ok) throw new Error("seal failed");
			const drawn = sealed.value.slice(0, 12);
			const again = gcmSealWithNonce(schedule, drawn, plain, aad) as Buffer;
			if (toHex(again) != toHex(sealed.value)) sealMatches = false;
			const next = sha256Sync(digest + toHex(reference));
			if (!next.ok) throw new Error("sha256 failed");
			digest = toHex(next.value);
		}
	}
	return `aes${keyLength * 8} ${digest} sealMatches ${sealMatches} opened ${opened}`;
}

console.log(await sweep(16));
console.log(await sweep(32));
