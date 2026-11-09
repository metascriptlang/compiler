import { Buffer } from "std/core/buffer";
import { digestSync, HashAlgorithm } from "../oracle";
import { encodeHex } from "std/core/encoding";
import { sha3Of } from "std/crypto/pure/sha3";

class Rng {
	s: uint32;
}

function nextByte(rng: Rng): uint8 {
	let x = rng.s;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	rng.s = x;
	return (x & 255) as uint8;
}

function randomBytes(rng: Rng, n: int32): uint8[] {
	const out = new Array<uint8>(n);
	for (let i = 0; i < n; i++) out[i] = nextByte(rng);
	return out;
}

function vendorHex(algorithm: HashAlgorithm, data: uint8[]): string {
	const r = digestSync(algorithm, data as Buffer);
	if (!r.ok) throw new Error("vendor digest failed");
	return r.value.encodeHex();
}

test "sha3 matches the vendor C digest on seeded random inputs" {
	const rng: Rng = { s: 0x9e3779b9 };
	const sizes: int32[] = [224, 256, 384, 512];
	const names: HashAlgorithm[] = ["sha3-224", "sha3-256", "sha3-384", "sha3-512"];
	let compared = 0;
	for (let k = 0; k < 4; k++) {
		const bits = sizes[k];
		const rate = 200 - (bits >> 2);
		const lengths: int32[] = [];
		for (let n = 0; n <= 2048; n += 7) lengths.push(n);
		for (let m = 1; m <= 4; m++) {
			lengths.push(m * rate - 1);
			lengths.push(m * rate);
			lengths.push(m * rate + 1);
		}
		for (const n of lengths) {
			const data = randomBytes(rng, n);
			assert sha3Of(bits, data).encodeHex() == vendorHex(names[k], data);
			compared += 1;
		}
	}
	assert compared == 4 * (293 + 12);
}
