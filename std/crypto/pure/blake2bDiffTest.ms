import { newBlake2b, updateBlake2b, finishBlake2b, blake2bOf } from "./blake2b";
import { blake2bSync as vendorSync, blake2bKeyedSync as vendorKeyedSync, createBlake2b as vendorCreate } from "./blake2bVendor";
import { blake2bSync, blake2bKeyedSync } from "../oracle/blake2b";
import { Buffer } from "std/core/buffer";

class Rng {
	s: uint32;
}

function nextU32(r: Rng): uint32 {
	let x = r.s;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	r.s = x;
	return x;
}

function randomBytes(r: Rng, n: int32): uint8[] {
	const b = new Array<uint8>(n);
	for (let i = 0; i < n; i++) b[i] = (nextU32(r) & 255) as uint8;
	return b;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

function lengthAt(r: Rng, i: int32): int32 {
	const boundaries = [0, 1, 63, 64, 65, 127, 128, 129, 255, 256, 257, 383, 384, 385, 1023, 1024, 1025, 2047, 2048];
	if (i < boundaries.length) return boundaries[i];
	return (nextU32(r) % 2049) as int32;
}

test "pure BLAKE2b equals the Monocypher oracle on seeded inputs, keyed and unkeyed, one-shot and streamed" {
	const r: Rng = { s: 0x9e3779b9 };
	let checked = 0;
	for (let i = 0; i < 4000; i++) {
		const n = lengthAt(r, i % 40);
		const data = randomBytes(r, n);
		const outLen = (1 + nextU32(r) % 64) as int32;
		const keyLen = (nextU32(r) % 65) as int32;
		const key = randomBytes(r, keyLen);
		const expected = keyLen == 0 ? vendorSync(data as Buffer, outLen) : vendorKeyedSync(key as Buffer, data as Buffer, outLen);
		if (!expected.ok) throw new Error("vendor refused a valid input");
		assert sameBytes(blake2bOf(outLen, key, data), expected.value);
		if (keyLen == 0) {
			const cut = n == 0 ? 0 : (nextU32(r) % ((n + 1) as uint32)) as int32;
			const s = newBlake2b(outLen, key);
			updateBlake2b(s, data, 0, cut);
			updateBlake2b(s, data, cut, n - cut);
			const v = vendorCreate(outLen);
			if (!v.ok) throw new Error("vendor refused a valid size");
			v.value.update((data as Buffer).slice(0, cut)).update((data as Buffer).slice(cut, n));
			assert sameBytes(finishBlake2b(s), v.value.digest());
		}
		checked++;
	}
	assert checked == 4000;
}

test "the oracle and the pure surface refuse the same sizes" {
	for (const outLen of [0, 65, -1]) assert vendorSync("abc", outLen).ok == blake2bSync("abc", outLen).ok;
	for (const keyLen of [0, 1, 64, 65]) assert vendorKeyedSync(Buffer.alloc(keyLen), "abc").ok == blake2bKeyedSync(Buffer.alloc(keyLen), "abc").ok;
}
