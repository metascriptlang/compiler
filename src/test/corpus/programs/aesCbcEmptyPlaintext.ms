// AES-CBC decrypt reports failure out of band, so an empty plaintext (one padding block) round-trips
// for both key sizes beside one-byte, 15-byte and 16-byte plaintexts; a corrupted padding byte, a
// ragged cipher text length and an empty cipher text still fail.
//
// @stdout: 16 empty true 16 | 1 true 16 | 15 true 16 | 16 true 32 | bad pad false | ragged false | none false
// @stdout: 32 empty true 16 | 1 true 16 | 15 true 16 | 16 true 32 | bad pad false | ragged false | none false
// @exit: 0
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

import { Buffer } from "std/core/buffer";
import { AesKey, cbcEncrypt, cbcDecrypt } from "std/crypto/aes";

const iv = "0123456789abcdef";

function importKey(raw: string): AesKey {
	const imported = AesKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	return imported.value;
}

async function roundTrip(key: AesKey, plain: string): Promise<string> {
	const sealed = await cbcEncrypt(key, plain, iv);
	if (!sealed.ok) return "encrypt failed";
	const opened = await cbcDecrypt(key, sealed.value, iv);
	return `${opened.ok && opened.value.asString() == plain} ${sealed.value.length}`;
}

async function rows(raw: string): Promise<string> {
	const key = importKey(raw);
	const sealed = await cbcEncrypt(key, "x", iv);
	if (!sealed.ok) return "encrypt failed";
	const corrupt = Buffer.copy(sealed.value);
	corrupt[15] = (corrupt[15] ^ 1) as uint8;
	const ragged = sealed.value.slice(0, 15);
	return [
		`${raw.byteLength} empty ${await roundTrip(key, "")}`,
		`1 ${await roundTrip(key, "x")}`,
		`15 ${await roundTrip(key, "fifteen bytes!!")}`,
		`16 ${await roundTrip(key, "sixteen bytes!!!")}`,
		`bad pad ${(await cbcDecrypt(key, corrupt, iv)).ok}`,
		`ragged ${(await cbcDecrypt(key, ragged, iv)).ok}`,
		`none ${(await cbcDecrypt(key, "", iv)).ok}`,
	].join(" | ");
}

console.log(await rows("0123456789abcdef"));
console.log(await rows("0123456789abcdef0123456789abcdef"));
