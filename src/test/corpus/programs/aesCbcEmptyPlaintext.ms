// AES-CBC decrypt reports failure out of band, so an empty plaintext (one padding block) round-trips
// for both key sizes beside one-byte, 15-byte and 16-byte plaintexts; a corrupted padding byte, a
// ragged cipher text length and an empty cipher text still fail.
//
// @stdout: 16 empty true 16 | 1 true 16 | 15 true 16 | 16 true 32 | bad pad false | ragged false | none false
// @stdout: 32 empty true 16 | 1 true 16 | 15 true 16 | 16 true 32 | bad pad false | ragged false | none false
// @exit: 0
// @skip-js: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.jms
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

import { Buffer } from "std/core/buffer";
import { fromHex, toHex } from "std/crypto";
import { cbcEncrypt, cbcDecrypt } from "std/crypto/aes";

const iv = "0123456789abcdef";

function roundTrip(key: string, plain: string): string {
	const sealed = cbcEncrypt(key, plain, iv);
	if (!sealed.ok) return "encrypt failed";
	const opened = cbcDecrypt(key, sealed.value, iv);
	return `${opened.ok && opened.value.asString() == plain} ${sealed.value.length}`;
}

function rows(key: string): string {
	const sealed = cbcEncrypt(key, "x", iv);
	if (!sealed.ok) return "encrypt failed";
	const corrupt = Buffer.copy(sealed.value);
	corrupt[15] = (corrupt[15] ^ 1) as uint8;
	const ragged = fromHex(toHex(sealed.value).substring(0, 30));
	return [
		`${key.byteLength} empty ${roundTrip(key, "")}`,
		`1 ${roundTrip(key, "x")}`,
		`15 ${roundTrip(key, "fifteen bytes!!")}`,
		`16 ${roundTrip(key, "sixteen bytes!!!")}`,
		`bad pad ${cbcDecrypt(key, corrupt, iv).ok}`,
		`ragged ${cbcDecrypt(key, ragged, iv).ok}`,
		`none ${cbcDecrypt(key, "", iv).ok}`,
	].join(" | ");
}

console.log(rows("0123456789abcdef"));
console.log(rows("0123456789abcdef0123456789abcdef"));
