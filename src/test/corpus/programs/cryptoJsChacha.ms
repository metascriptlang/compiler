// XChaCha20-Poly1305 gives the same bytes on the C backend (Monocypher) and on JS (the portable
// code in std/crypto/pure, since WebCrypto has no ChaCha20): the RFC 8439 2.5.2 Poly1305 tag, in one
// piece and fed in 7-byte chunks; the draft-irtf-cfrg-xchacha A.3.1 vector opens through the async and
// the Sync form and refuses a flipped tag bit, body bit and AAD; seal and open round-trip at every block
// edge; and two blobs sealed by the C backend (embedded below) open on every backend.
//
// @stdout: poly1305 a8061dc1305136c6c22b8baf0c0127a9 chunked true
// @stdout: vector opens true sync true tag false body false aad false
// @stdout: edges 0 1 15 16 17 63 64 65 127 128 129 1000 ok
// @stdout: edge tamper refused true
// @stdout: c sealed 70 opens true wrong aad false
// @stdout: c sealed 0 opens true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, toHex } from "std/crypto";
import { ChaChaKey, open, openSync, seal, sealSync } from "std/crypto/chacha20";
import { newPoly1305, updatePoly1305, finishPoly1305 } from "std/crypto/pure/poly1305";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(`crypto call failed: ${result.error.message}`);
	return result.value;
}

function hex(text: string): Buffer {
	return Buffer.fromString(text, "hex");
}

function flip(blob: Buffer, index: int32): Buffer {
	const copy = Buffer.copy(blob);
	copy[index] = (copy[index] ^ 1) as uint8;
	return copy;
}

function polyTag(message: Buffer, chunk: int32): string {
	const mac = newPoly1305(hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), 0);
	for (let at = 0; at < message.length; at += chunk) {
		const take = message.length - at < chunk ? message.length - at : chunk;
		updatePoly1305(mac, message, at, take);
	}
	const tag = Buffer.alloc(16);
	finishPoly1305(mac, tag, 0);
	return toHex(tag);
}

const message = Buffer.fromString("Cryptographic Forum Research Group", "utf8");
const whole = polyTag(message, 64);
console.log(`poly1305 ${whole} chunked ${polyTag(message, 7) == whole}`);

const vectorKey = must(ChaChaKey.import(hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")));
const vector = hex("404142434445464748494a4b4c4d4e4f5051525354555657"
	+ "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e"
	+ "c0875924c1c7987947deafd8780acf49");
const vectorAad = hex("50515253c0c1c2c3c4c5c6c7");
const plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
const opened = await open(vectorKey, vector, vectorAad);
const openedSync = openSync(vectorKey, vector, vectorAad);
const opens = opened.ok && opened.value.asString() == plain;
const opensSync = openedSync.ok && openedSync.value.asString() == plain;
const tagFlip = (await open(vectorKey, flip(vector, vector.length - 1), vectorAad)).ok;
const bodyFlip = (await open(vectorKey, flip(vector, 24), vectorAad)).ok;
const noAad = (await open(vectorKey, vector, "")).ok;
console.log(`vector opens ${opens} sync ${opensSync} tag ${tagFlip} body ${bodyFlip} aad ${noAad}`);

const key = must(ChaChaKey.import("0123456789abcdef0123456789abcdef"));
const sizes = [0, 1, 15, 16, 17, 63, 64, 65, 127, 128, 129, 1000];
let edges = "";
let tamperRefused = true;
for (const size of sizes) {
	const data = Buffer.alloc(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 7 + 3) % 256) as uint8;
	const sealed = must(await seal(key, data, "aad"));
	const sealedSync = must(sealSync(key, data, "aad"));
	if (sealed.length != size + 40 || sealedSync.length != size + 40) throw new Error(`size ${size} sealed to ${sealed.length}`);
	const back = must(await open(key, sealedSync, "aad"));
	const backSync = must(openSync(key, sealed, "aad"));
	if (toHex(back) != toHex(data) || toHex(backSync) != toHex(data)) throw new Error(`size ${size} did not round-trip`);
	if ((await open(key, flip(sealed, 30), "aad")).ok || (await open(key, sealed, "other")).ok) tamperRefused = false;
	edges += `${size} `;
}
console.log(`edges ${edges}ok`);
console.log(`edge tamper refused ${tamperRefused}`);

// Sealed by the C backend with this key, these plain texts and AAD.
const cKey = Buffer.alloc(32);
for (let i = 0; i < 32; i++) cKey[i] = (i * 5 + 3) as uint8;
const cKeyObject = must(ChaChaKey.import(cKey));
const cPlain = Buffer.alloc(70);
for (let i = 0; i < 70; i++) cPlain[i] = ((i * 3 + 1) % 256) as uint8;
const cSealed70 = hex("5f693a144ffccdd434612a1e9cebfdfab25645b53ba348aeddfceb8f6620b0e3886af360dee02b12ffa097d4cdc8fd54e8a76b664af9aa9142ae618a00e78072470eddb801e2ab85b290ed8d5c0d822601f1bfc123d257b2a76891474cd69a793e5c14b1fd117fd9c50b162382b9");
const cSealed0 = hex("712c78e851cca4db13dbc1c3a45a940be429d035a4762448bd264f688dc74ba89da18d2c1e87beb8");
const open70 = must(await open(cKeyObject, cSealed70, "header"));
console.log(`c sealed 70 opens ${toHex(open70) == toHex(cPlain)} wrong aad ${(await open(cKeyObject, cSealed70, "other")).ok}`);
console.log(`c sealed 0 opens ${must(await open(cKeyObject, cSealed0, "")).length == 0}`);
