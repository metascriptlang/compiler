// A ChaChaKey owns its native key state: one per key object however many names refer to it, kept
// across an await that uses it, wiped and freed exactly once when the last name is gone (a double
// free aborts under MSCORPUS_SAN, a leak leaves the live count above zero). XChaCha20-Poly1305 opens
// the draft-irtf-cfrg-xchacha A.3.1 vector, refuses a flipped tag bit, a flipped body bit and a
// wrong AAD, and a key of the wrong length never creates any state.
//
// @stdout: scope before 0 inside 1 after 0
// @stdout: alias inside 1 after 0
// @stdout: vector length 114 opens true tag false body false aad false
// @stdout: round trip sealed 54 opened true fresh nonce true after 0
// @stdout: bad length refused true live 0
// @exit: 0
// @skip-js: the program counts native key state through msChacha20KeysLive, which only the C backend has; a JS key holds plain words and nothing to free (cryptoJsChacha pins the JS tier)
// @skip-raiser: std/crypto/chacha20 has only a C backend (index.cms over Monocypher); there is no chacha20.rms

@include("runtime/crypto/ciphers/chacha20.h");

import { Buffer } from "std/core/buffer";
import { ChaChaKey, seal, open } from "std/crypto/chacha20";

extern function msChacha20KeysLive(): int64;

function generate(): ChaChaKey {
	const made = ChaChaKey.generate();
	if (!made.ok) throw new Error("generate failed");
	return made.value;
}

function importKey(raw: Buffer): ChaChaKey {
	const imported = ChaChaKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	return imported.value;
}

function flip(blob: Buffer, index: int32): Buffer {
	const copy = Buffer.copy(blob);
	copy[index] = (copy[index] ^ 1) as uint8;
	return copy;
}

function flipLast(blob: Buffer): Buffer {
	return flip(blob, blob.length - 1);
}

function scope(): string {
	const before = msChacha20KeysLive();
	let inside: int64 = -1;
	{
		const key = generate();
		inside = msChacha20KeysLive();
		key.exportRaw();
	}
	return `before ${before} inside ${inside} after ${msChacha20KeysLive()}`;
}

function alias(): string {
	let inside: int64 = -1;
	{
		const key = generate();
		const same = key;
		inside = msChacha20KeysLive();
		same.exportRaw();
		key.exportRaw();
	}
	return `inside ${inside} after ${msChacha20KeysLive()}`;
}

async function vector(): Promise<string> {
	const key = importKey(Buffer.fromString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f", "hex"));
	const nonce = "404142434445464748494a4b4c4d4e4f5051525354555657";
	const body = "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e";
	const tag = "c0875924c1c7987947deafd8780acf49";
	const blob = Buffer.fromString(nonce + body + tag, "hex");
	const aad = Buffer.fromString("50515253c0c1c2c3c4c5c6c7", "hex");
	const opened = await open(key, blob, aad);
	const plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
	const opens = opened.ok && opened.value.asString() == plain;
	const tagFlip = (await open(key, flipLast(blob), aad)).ok;
	const bodyFlip = (await open(key, flip(blob, 24), aad)).ok;
	const noAad = (await open(key, blob, "")).ok;
	return `length ${plain.byteLength} opens ${opens} tag ${tagFlip} body ${bodyFlip} aad ${noAad}`;
}

async function roundTrip(): Promise<string> {
	let line = "";
	{
		const key = generate();
		const first = await seal(key, "attack at dawn", "hdr");
		const second = await seal(key, "attack at dawn", "hdr");
		if (!first.ok || !second.ok) throw new Error("seal failed");
		const opened = await open(key, first.value, "hdr");
		let fresh = false;
		for (let i = 0; i < 24; i++) if (first.value[i] != second.value[i]) fresh = true;
		line = `sealed ${first.value.length} opened ${opened.ok && opened.value.asString() == "attack at dawn"} fresh nonce ${fresh}`;
	}
	return line;
}

function badLength(): string {
	return `refused ${!ChaChaKey.import("fifteen bytes!!").ok} live ${msChacha20KeysLive()}`;
}

console.log(`scope ${scope()}`);
console.log(`alias ${alias()}`);
console.log(`vector ${await vector()}`);
const roundTripLine = await roundTrip();
console.log(`round trip ${roundTripLine} after ${msChacha20KeysLive()}`);
console.log(`bad length ${badLength()}`);
