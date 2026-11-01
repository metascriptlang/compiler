// std/crypto/blake2b refuses an output size outside 1..64 and a key size outside 1..64 with an error
// Result, in the async, the sync and the streaming forms, instead of hashing with another size; the
// streaming hasher throws on a second digest and on an update after its digest; sizes 1 and 64 and a
// key of 64 bytes stay valid, and the async, sync and streamed forms agree on the RFC 7693 "abc" vector.
//
// @stdout: keyed size 0 err|keyed size 65 err|keyed size -1 err|keyed size 1 ok 1|keyed size 64 ok 64|keyed key 65 err|keyed key 64 ok
// @stdout: one-shot size 0 err|one-shot size 100 err|one-shot size 1 ok 1|one-shot size 64 ok 64
// @stdout: stream size 0 err|stream size 65 err|stream size 64 ok 64|digest twice threw|update after digest threw
// @stdout: sync size 0 err|sync size 65 err|sync size 1 ok 1|sync keyed size 0 err|sync keyed key 65 err|sync keyed key 64 ok
// @stdout: abc512 ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923 async true stream true
// @exit: 0
// @skip-raiser: std/crypto has only a C backend (blake2b/index.cms over Monocypher); there is no blake2b.rms

import { Blake2b, blake2b, blake2bKeyed, blake2bSync, blake2bKeyedSync, createBlake2b } from "std/crypto/blake2b";

const key = "0123456789abcdef";

async function keyed(size: int32): Promise<string> {
	const result = await blake2bKeyed(key, "data", size);
	return result.ok ? `ok ${result.value.length}` : "err";
}

async function oneShot(size: int32): Promise<string> {
	const result = await blake2b("data", size);
	return result.ok ? `ok ${result.value.length}` : "err";
}

function stream(size: int32): string {
	const hasher = createBlake2b(size);
	if (!hasher.ok) return "err";
	hasher.value.update("data");
	return `ok ${hasher.value.digest().length}`;
}

function made(size: int32): Blake2b {
	const hasher = createBlake2b(size);
	if (!hasher.ok) throw new Error("create failed");
	return hasher.value;
}

function digestTwice(): string {
	try {
		const hasher = made(32);
		hasher.update("data");
		hasher.digest();
		hasher.digest();
		return "returned";
	} catch (e) {
		return "threw";
	}
}

function updateAfterDigest(): string {
	try {
		const hasher = made(32);
		hasher.digest();
		hasher.update("data");
		return "returned";
	} catch (e) {
		return "threw";
	}
}

async function keySize(length: int32): Promise<string> {
	const result = await blake2bKeyed("k".repeat(length), "data", 32);
	return result.ok ? "ok" : "err";
}

function syncOneShot(size: int32): string {
	const result = blake2bSync("data", size);
	return result.ok ? `ok ${result.value.length}` : "err";
}

function syncKeyed(keyLength: int32, size: int32): string {
	const result = blake2bKeyedSync("k".repeat(keyLength), "data", size);
	return result.ok ? "ok" : "err";
}

console.log([
	`keyed size 0 ${await keyed(0)}`,
	`keyed size 65 ${await keyed(65)}`,
	`keyed size -1 ${await keyed(-1)}`,
	`keyed size 1 ${await keyed(1)}`,
	`keyed size 64 ${await keyed(64)}`,
	`keyed key 65 ${await keySize(65)}`,
	`keyed key 64 ${await keySize(64)}`,
].join("|"));
console.log([
	`one-shot size 0 ${await oneShot(0)}`,
	`one-shot size 100 ${await oneShot(100)}`,
	`one-shot size 1 ${await oneShot(1)}`,
	`one-shot size 64 ${await oneShot(64)}`,
].join("|"));
console.log([
	`stream size 0 ${stream(0)}`,
	`stream size 65 ${stream(65)}`,
	`stream size 64 ${stream(64)}`,
	`digest twice ${digestTwice()}`,
	`update after digest ${updateAfterDigest()}`,
].join("|"));
console.log([
	`sync size 0 ${syncOneShot(0)}`,
	`sync size 65 ${syncOneShot(65)}`,
	`sync size 1 ${syncOneShot(1)}`,
	`sync keyed size 0 ${syncKeyed(16, 0)}`,
	`sync keyed key 65 ${syncKeyed(65, 32)}`,
	`sync keyed key 64 ${syncKeyed(64, 32)}`,
].join("|"));

const sync = blake2bSync("abc", 64);
const awaited = await blake2b("abc", 64);
const streamed = made(64);
streamed.update("a").update("bc");
const streamedDigest = streamed.digest();
if (!sync.ok || !awaited.ok) throw new Error("hash failed");
console.log(`abc512 ${sync.value.toHex()} async ${awaited.value.toHex() == sync.value.toHex()} stream ${streamedDigest.toHex() == sync.value.toHex()}`);
