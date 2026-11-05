import { RsaPrivateKey, decryptSync } from "std/crypto/pure/rsaNative";
import { keyAPkcs8, oaepSha256, message } from "std/crypto/pure/rsaFixtures";
import { decodeHex, encodeHex } from "std/core/encoding";

const imported = RsaPrivateKey.importPemSync(keyAPkcs8);
if (!imported.ok) throw new Error("rsaOaepScratch: key import failed");
const opened = decryptSync(imported.value, oaepSha256.decodeHex());
if (!opened.ok) throw new Error("rsaOaepScratch: decryption failed");
const actual = opened.value.encodeHex();
if (actual != message.asBytes().encodeHex()) {
	throw new Error("rsaOaepScratch: plaintext mismatch");
}
console.log(actual);
