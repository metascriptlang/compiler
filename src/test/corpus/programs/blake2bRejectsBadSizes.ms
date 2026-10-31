// std/crypto/blake2b refuses an output size outside 1..64 and a key size outside 1..64 instead of
// hashing with another size, and the streaming hasher refuses a second digest and an update after
// its digest; sizes 1 and 64 and a key of 64 bytes stay valid.
//
// @stdout: keyed size 0 err|keyed size 65 err|keyed size -1 err|keyed size 1 ok 1|keyed size 64 ok 64|keyed key 65 err|keyed key 64 ok
// @stdout: one-shot size 0 threw|one-shot size 100 threw|one-shot size 1 ok 1|one-shot size 64 ok 64
// @stdout: stream size 0 threw|stream size 65 threw|stream size 64 ok 64|digest twice threw|update after digest threw
// @exit: 0
// @skip-js: std/crypto has only a C backend (blake2b/index.cms over Monocypher); there is no blake2b.jms
// @skip-raiser: std/crypto has only a C backend (blake2b/index.cms over Monocypher); there is no blake2b.rms

import { blake2b, blake2bKeyed, createBlake2b } from "std/crypto/blake2b";

const key = "0123456789abcdef";

function keyed(size: int32): string {
	const result = blake2bKeyed(key, "data", size);
	return result.ok ? `ok ${result.value.length}` : "err";
}

function oneShot(size: int32): string {
	try {
		return `ok ${blake2b("data", size).length}`;
	} catch (e) {
		return "threw";
	}
}

function stream(size: int32): string {
	try {
		const hasher = createBlake2b(size);
		hasher.update("data");
		return `ok ${hasher.digest().length}`;
	} catch (e) {
		return "threw";
	}
}

function digestTwice(): string {
	try {
		const hasher = createBlake2b(32);
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
		const hasher = createBlake2b(32);
		hasher.digest();
		hasher.update("data");
		return "returned";
	} catch (e) {
		return "threw";
	}
}

function keySize(length: int32): string {
	const result = blake2bKeyed("k".repeat(length), "data", 32);
	return result.ok ? "ok" : "err";
}

console.log([
	`keyed size 0 ${keyed(0)}`,
	`keyed size 65 ${keyed(65)}`,
	`keyed size -1 ${keyed(-1)}`,
	`keyed size 1 ${keyed(1)}`,
	`keyed size 64 ${keyed(64)}`,
	`keyed key 65 ${keySize(65)}`,
	`keyed key 64 ${keySize(64)}`,
].join("|"));
console.log([
	`one-shot size 0 ${oneShot(0)}`,
	`one-shot size 100 ${oneShot(100)}`,
	`one-shot size 1 ${oneShot(1)}`,
	`one-shot size 64 ${oneShot(64)}`,
].join("|"));
console.log([
	`stream size 0 ${stream(0)}`,
	`stream size 65 ${stream(65)}`,
	`stream size 64 ${stream(64)}`,
	`digest twice ${digestTwice()}`,
	`update after digest ${updateAfterDigest()}`,
].join("|"));
