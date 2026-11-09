import { hmacOf, pbkdf2Of, hkdfOf } from "std/crypto/pure/hmac";
import { hashKind } from "std/crypto/pure/hash";
import { newHashState } from "std/crypto/pure/state";
import { encodeHex } from "std/core/encoding";
import { HashAlgorithm, hmacSync, pbkdf2Sync, hkdfSync } from "../oracle";

const algorithms: HashAlgorithm[] = ["sha1", "sha224", "sha256", "sha384", "sha512", "md5"];
const boundaryLengths: int32[] = [0, 1, 55, 56, 63, 64, 65, 111, 112, 119, 120, 127, 128, 129, 191, 192, 255, 256, 257, 1023, 1024, 2047, 2048];

class Seeded {
	state: uint32 = 0x9e3779b9;
}

function nextWord(rng: Seeded): uint32 {
	let x = rng.state;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	rng.state = x;
	return x;
}

function below(rng: Seeded, bound: int32): int32 {
	return (nextWord(rng) % (bound as uint32)) as int32;
}

function randomBytes(rng: Seeded, count: int32): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = (nextWord(rng) & 255) as uint8;
	return out;
}

function pureHmac(algorithm: HashAlgorithm, key: uint8[], data: uint8[]): string {
	return hmacOf(hashKind(algorithm), key, data).encodeHex();
}

function vendorHmac(algorithm: HashAlgorithm, key: uint8[], data: uint8[]): string {
	const r = hmacSync(algorithm, key, data);
	return r.ok ? r.value.encodeHex() : "refused";
}

function purePbkdf2(algorithm: HashAlgorithm, password: uint8[], salt: uint8[], iterations: int32, length: int32): string {
	try {
		return pbkdf2Of(hashKind(algorithm), password, salt, iterations, length).encodeHex();
	} catch (e) {
		return "refused";
	}
}

function vendorPbkdf2(algorithm: HashAlgorithm, password: uint8[], salt: uint8[], iterations: int32, length: int32): string {
	const r = pbkdf2Sync(password, salt, iterations, length, algorithm);
	return r.ok ? r.value.encodeHex() : "refused";
}

function pureHkdf(algorithm: HashAlgorithm, ikm: uint8[], salt: uint8[], info: uint8[], length: int32): string {
	try {
		return hkdfOf(hashKind(algorithm), ikm, salt, info, length).encodeHex();
	} catch (e) {
		return "refused";
	}
}

function vendorHkdf(algorithm: HashAlgorithm, ikm: uint8[], salt: uint8[], info: uint8[], length: int32): string {
	const r = hkdfSync(algorithm, ikm, salt, info, length);
	return r.ok ? r.value.encodeHex() : "refused";
}

function hashSize(algorithm: HashAlgorithm): int32 {
	return newHashState(hashKind(algorithm)).outputSize;
}

test "HMAC matches the vendor over boundary and random key and message lengths" {
	const rng = new Seeded();
	let cases = 0;
	for (const algorithm of algorithms) {
		for (const keyLength of boundaryLengths) {
			for (const dataLength of boundaryLengths) {
				const key = randomBytes(rng, keyLength);
				const data = randomBytes(rng, dataLength);
				assert pureHmac(algorithm, key, data) == vendorHmac(algorithm, key, data);
				cases += 1;
			}
		}
		for (let i = 0; i < 300; i++) {
			const key = randomBytes(rng, below(rng, 300));
			const data = randomBytes(rng, below(rng, 2049));
			assert pureHmac(algorithm, key, data) == vendorHmac(algorithm, key, data);
			cases += 1;
		}
	}
	console.log(`hmac differential: ${cases} cases`);
}

test "PBKDF2 matches the vendor on outputs and refusals" {
	const rng = new Seeded();
	let cases = 0;
	for (const algorithm of algorithms) {
		for (let i = 0; i < 40; i++) {
			const password = randomBytes(rng, below(rng, 200));
			const salt = randomBytes(rng, below(rng, 100));
			const iterations = 1 + below(rng, 40);
			const length = 1 + below(rng, 300);
			assert purePbkdf2(algorithm, password, salt, iterations, length) == vendorPbkdf2(algorithm, password, salt, iterations, length);
			cases += 1;
		}
		const password = randomBytes(rng, 16);
		const salt = randomBytes(rng, 16);
		const shapes: int32[][] = [[0, 32], [-1, 32], [1, 0], [1, -1], [1, 1048577], [1, 1]];
		for (const shape of shapes) {
			assert purePbkdf2(algorithm, password, salt, shape[0], shape[1]) == vendorPbkdf2(algorithm, password, salt, shape[0], shape[1]);
			cases += 1;
		}
	}
	console.log(`pbkdf2 differential: ${cases} cases`);
}

test "HKDF matches the vendor on outputs and refusals" {
	const rng = new Seeded();
	let cases = 0;
	for (const algorithm of algorithms) {
		const max = 255 * hashSize(algorithm);
		for (let i = 0; i < 60; i++) {
			const ikm = randomBytes(rng, below(rng, 200));
			const salt = randomBytes(rng, below(rng, 200));
			const info = randomBytes(rng, below(rng, 200));
			const length = 1 + below(rng, 600);
			assert pureHkdf(algorithm, ikm, salt, info, length) == vendorHkdf(algorithm, ikm, salt, info, length);
			cases += 1;
		}
		const ikm = randomBytes(rng, 22);
		const empty = new Array<uint8>(0);
		const lengths: int32[] = [-1, 0, 1, max - 1, max, max + 1];
		for (const length of lengths) {
			assert pureHkdf(algorithm, ikm, empty, empty, length) == vendorHkdf(algorithm, ikm, empty, empty, length);
			cases += 1;
		}
	}
	console.log(`hkdf differential: ${cases} cases`);
}
