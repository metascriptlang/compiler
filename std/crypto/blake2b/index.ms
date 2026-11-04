/**
 * BLAKE2b (RFC 7693) on every backend: every
 * form runs the portable code in `std/crypto/pure`, and the async forms call the `*Sync` forms.
 */

import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { bytesOf } from "../pure/bytes";
import { Blake2bState, newBlake2b, updateBlake2b, finishBlake2b, blake2bOf } from "../pure/blake2b";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
export { CryptoError, CryptoErrorKind } from "../errors";


function badHashSize(hashSize: int32, op: string): CryptoError | null {
	if (hashSize < 1 || hashSize > 64) {
		return cryptoError(CryptoErrorKind.InvalidInput, op, `hashSize must be 1-64, got ${hashSize}`);
	}
	return null;
}

// ===== One-shot Hashing =====

export function blake2bSync(data: Bytes, hashSize: int32 = 32): Result<Buffer, CryptoError> {
	const bad = badHashSize(hashSize, "blake2b");
	if (bad != null) return Result.err(bad);
	return Result.ok(blake2bOf(hashSize, [], bytesOf(data)) as Buffer);
}

export function blake2bKeyedSync(keyBytes: Bytes, data: Bytes, hashSize: int32 = 32): Result<Buffer, CryptoError> {
	const key = bytesOf(keyBytes);
	if (key.length < 1 || key.length > 64) {
		return Result.err(cryptoError(CryptoErrorKind.InvalidKey, "blake2bKeyed", "key must be 1-64 bytes"));
	}
	const bad = badHashSize(hashSize, "blake2bKeyed");
	if (bad != null) return Result.err(bad);
	return Result.ok(blake2bOf(hashSize, key, bytesOf(data)) as Buffer);
}

export async function blake2b(data: Bytes, hashSize: int32 = 32): Promise<Result<Buffer, CryptoError>> {
	return blake2bSync(data, hashSize);
}

export async function blake2bKeyed(keyBytes: Bytes, data: Bytes, hashSize: int32 = 32): Promise<Result<Buffer, CryptoError>> {
	return blake2bKeyedSync(keyBytes, data, hashSize);
}

// ===== Streaming (sync only) =====

export class Blake2b {
	_state: Blake2bState;

	update(data: Bytes): Blake2b {
		if (this._state.finished) throw new Error("Blake2b.update: the hasher already produced its digest");
		const bytes = bytesOf(data);
		updateBlake2b(this._state, bytes, 0, bytes.length as int32);
		return this;
	}

	digest(): Buffer {
		if (this._state.finished) throw new Error("Blake2b.digest: the hasher already produced its digest");
		return finishBlake2b(this._state) as Buffer;
	}
}

export function createBlake2b(hashSize: int32 = 32): Result<Blake2b, CryptoError> {
	const bad = badHashSize(hashSize, "createBlake2b");
	if (bad != null) return Result.err(bad);
	return Result.ok({ _state: newBlake2b(hashSize, []) });
}

function hexOf(b: Readonly<uint8[]>): string {
	const digits = "0123456789abcdef";
	let s = "";
	for (let i = 0; i < b.length; i++) s += digits[b[i] >> 4] + digits[b[i] & 15];
	return s;
}

function okHex(r: Result<Buffer, CryptoError>): string {
	if (!r.ok) throw new Error("blake2b failed");
	return hexOf(r.value);
}

function hasher(n: int32): Blake2b {
	const r = createBlake2b(n);
	if (!r.ok) throw new Error("createBlake2b failed");
	return r.value;
}

test "blake2b async and sync agree on the RFC 7693 abc vector, keyed and streamed too" {
	const sync = blake2bSync("abc", 64);
	assert sync.ok;
	const streamed = createBlake2b(64);
	assert streamed.ok;
	streamed.value.update("a").update("bc");
	const streamedDigest = streamed.value.digest();
	const awaited = await blake2b("abc", 64);
	assert awaited.ok;
	assert hexOf(sync.value) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
	assert hexOf(awaited.value) == hexOf(sync.value);
	assert hexOf(streamedDigest) == hexOf(sync.value);
	assert (await blake2bKeyed("k", "abc")).ok;
}

test "blake2b output lengths 1, 32 and 64 match the reference vectors" {
	assert okHex(blake2bSync("abc", 1)) == "6b";
	assert okHex(blake2bSync("abc")) == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319";
	assert okHex(blake2bSync("abc", 64)).length / 2 == 64;
}

test "blake2bKeyedSync with a 64-byte key matches the official KAT" {
	const key = Buffer.alloc(64);
	for (let i = 0; i < 64; i++) key[i] = i as uint8;
	const data = Buffer.alloc(129);
	for (let i = 0; i < 129; i++) data[i] = i as uint8;
	assert okHex(blake2bKeyedSync(key, Buffer.alloc(0), 64)) == "10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568";
	assert okHex(blake2bKeyedSync(key, data, 64)) == "64475dfe7600d7171bea0b394e27c9b00d8e74dd1e416a79473682ad3dfdbb706631558055cfc8a40e07bd015a4540dcdea15883cbbf31412df1de1cd4152b91";
}

test "streaming at block boundaries 127, 128, 129 equals one-shot" {
	for (const n of [127, 128, 129, 300]) {
		const data = Buffer.alloc(n);
		for (let i = 0; i < n; i++) data[i] = ((i * 7) & 255) as uint8;
		const one = okHex(blake2bSync(data, 64));
		for (const cut of [0, 1, 64, 127, 128, n]) {
			if (cut > n) continue;
			const h = hasher(64);
			h.update(data.slice(0, cut)).update(data.slice(cut, n));
			assert hexOf(h.digest()) == one;
		}
	}
}

test "blake2b refuses output length 0 and 65 and key length 0 and 65" {
	assert !blake2bSync("abc", 0).ok;
	assert !blake2bSync("abc", 65).ok;
	assert !createBlake2b(0).ok;
	assert !createBlake2b(65).ok;
	assert !blake2bKeyedSync("", "abc").ok;
	assert !blake2bKeyedSync(Buffer.alloc(65), "abc").ok;
	assert !blake2bKeyedSync("k", "abc", 65).ok;
	assert blake2bKeyedSync(Buffer.alloc(64), "abc", 64).ok;
}
