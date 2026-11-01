// An AesKey owns its native key state: it exists once per key object however many names refer to
// it, survives an await that uses it, and is wiped and freed exactly once when the last name is gone
// (a double free aborts under MSCORPUS_SAN, a leak leaves the live count above zero). A key of the
// wrong length never creates any state, and exportRaw copies the bytes out so they outlive the key.
//
// @stdout: scope before 0 inside 1 after 0
// @stdout: alias inside 1 after 0
// @stdout: await inside 1 sealed true opened true after 0
// @stdout: bad length refused true live 0
// @stdout: export copy 16 kept true live 0
// @exit: 0
// @skip-js: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.jms
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

@include("runtime/crypto/ciphers/aes.h");

import { AesKey, seal, open } from "std/crypto/aes";

extern function msCryptoAesKeysLive(): int64;

function generate(bits: int32): AesKey {
	const made = AesKey.generate(bits);
	if (!made.ok) throw new Error("generate failed");
	return made.value;
}

function scope(): string {
	const before = msCryptoAesKeysLive();
	let inside: int64 = -1;
	{
		const key = generate(256);
		inside = msCryptoAesKeysLive();
		key.exportRaw();
	}
	return `before ${before} inside ${inside} after ${msCryptoAesKeysLive()}`;
}

function alias(): string {
	let inside: int64 = -1;
	{
		const key = generate(128);
		const same = key;
		inside = msCryptoAesKeysLive();
		same.exportRaw();
		key.exportRaw();
	}
	return `inside ${inside} after ${msCryptoAesKeysLive()}`;
}

async function awaited(): Promise<string> {
	let inside: int64 = -1;
	let sealedOk = false;
	let openedOk = false;
	{
		const key = generate(256);
		const sealed = await seal(key, "attack at dawn", "hdr");
		inside = msCryptoAesKeysLive();
		sealedOk = sealed.ok;
		if (sealed.ok) {
			const opened = await open(key, sealed.value, "hdr");
			openedOk = opened.ok && opened.value.asString() == "attack at dawn";
		}
	}
	return `inside ${inside} sealed ${sealedOk} opened ${openedOk}`;
}

function badLength(): string {
	const refused = !AesKey.import("fifteen bytes!!").ok && !AesKey.generate(192).ok;
	return `refused ${refused} live ${msCryptoAesKeysLive()}`;
}

function exported(): string {
	const key = generate(128);
	const raw = key.exportRaw();
	return `${raw.length} kept ${raw.length == 16}`;
}

console.log(`scope ${scope()}`);
console.log(`alias ${alias()}`);
const awaitedLine = await awaited();
console.log(`await ${awaitedLine} after ${msCryptoAesKeysLive()}`);
console.log(`bad length ${badLength()}`);
console.log(`export copy ${exported()} live ${msCryptoAesKeysLive()}`);
