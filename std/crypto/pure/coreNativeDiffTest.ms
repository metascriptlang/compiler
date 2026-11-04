import { Buffer } from "std/core/buffer";
import * as vendor from "../index";
import * as pure from "./coreNative";
import { CryptoError } from "../errors";

class Seeded {
	state: uint32;
}

function next(rng: Seeded): uint32 {
	let x = rng.state;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	rng.state = x;
	return x;
}

function below(rng: Seeded, limit: int32): int32 {
	return ((next(rng) % (limit as uint32)) as int32);
}

function randomData(rng: Seeded, length: int32): Buffer {
	const bytes = new Array<uint8>(length);
	for (let i = 0; i < length; i++) bytes[i] = (next(rng) & 255) as uint8;
	return bytes as Buffer;
}

function randomText(rng: Seeded, alphabet: string, length: int32): string {
	let text = "";
	for (let i = 0; i < length; i++) {
		const at = below(rng, alphabet.length as int32);
		text = text + alphabet.slice(at, at + 1);
	}
	return text;
}

function sameResult(
	a: Result<Buffer, CryptoError>,
	b: Result<Buffer, CryptoError>,
): boolean {
	if (a.ok != b.ok) return false;
	if (!a.ok || !b.ok) return true;
	return a.value.encodeHex() == b.value.encodeHex();
}

const SIZES = [0, 1, 2, 3, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 2048];

function sizeFor(rng: Seeded, round: int32): int32 {
	if (round < SIZES.length) return SIZES[round] as int32;
	return below(rng, 2049);
}

test "hex and base64 match the vendor surface on random and invalid input" {
	const rng: Seeded = { state: 0x9e3779b9 };
	for (let round = 0; round < 400; round++) {
		const data = randomData(rng, sizeFor(rng, round));
		assert pure.toHex(data) == vendor.toHex(data);
		assert pure.toBase64(data) == vendor.toBase64(data);
		assert sameResult(
			pure.fromHex(vendor.toHex(data)),
			vendor.fromHex(vendor.toHex(data)),
		);
		const hex = randomText(rng, "0123456789abcdefABCDEFgz ", below(rng, 10));
		assert sameResult(pure.fromHex(hex), vendor.fromHex(hex));
		const b64 = randomText(
			rng,
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=!-_",
			below(rng, 13),
		);
		assert sameResult(pure.fromBase64(b64), vendor.fromBase64(b64));
	}
}

test "every hash the pure core lists is correctly reported, vendor hashes are a subset" {
	const names = pure.getHashes();
	for (const name of vendor.getHashes()) assert names.includes(name);
	for (const name of names) assert pure.isHashSupported(name);
	assert !pure.isHashSupported("SHA256") && !vendor.isHashSupported("SHA256");
}

test "streaming hash and HMAC match the vendor over random splits" {
	const rng: Seeded = { state: 0x2545f491 };
	for (const name of pure.getHashes()) {
		if (!vendor.isHashSupported(name)) continue;
		for (let round = 0; round < 60; round++) {
			const data = randomData(rng, sizeFor(rng, round));
			const key = randomData(rng, below(rng, 200));
			const h = pure.createHash(name);
			const m = pure.createHmac(name, key);
			let at = 0;
			while (at < data.length) {
				const step = below(rng, 150);
				const piece = data.slice(at, at + step) as Buffer;
				h.update(piece);
				m.update(piece);
				at += step;
			}
			const hashOk = vendor.digestSync(name, data);
			const macOk = vendor.hmacSync(name, key, data);
			assert hashOk.ok && macOk.ok;
			assert h.digest().encodeHex() == hashOk.value.encodeHex();
			assert m.digest().encodeHex() == macOk.value.encodeHex();
		}
	}
}

test "randomInt is uniform over small ranges by chi-square" {
	const critical = [0, 15.14, 18.42, 21.11, 23.51, 25.74, 27.86, 29.88, 31.83, 33.72];
	for (const range of [2, 3, 7, 10]) {
		const draws = 10000;
		const counts: float64[] = [];
		for (let i = 0; i < range; i++) counts.push(0);
		for (let n = 0; n < draws; n++) {
			const drawn = pure.randomIntSync(100, 100 + range);
			assert drawn.ok;
			counts[drawn.value - 100] += 1;
		}
		const expected = draws / range;
		let chi: float64 = 0;
		for (const count of counts) {
			chi += (count - expected) * (count - expected) / expected;
		}
		assert chi < critical[range - 1];
	}
}

test "randomInt reaches the edges of the safe range" {
	const top = 9007199254740991;
	const widest = 281474976710655;
	for (let n = 0; n < 50; n++) {
		const last = pure.randomIntSync(top - 1, top);
		assert last.ok && last.value == top - 1;
		const low = pure.randomIntSync(-top, -top + 1);
		assert low.ok && low.value == -top;
		const below0 = pure.randomIntSync(-widest, 0);
		assert below0.ok && below0.value >= -widest && below0.value < 0;
		const high = pure.randomIntSync(top - widest, top);
		assert high.ok && high.value >= top - widest && high.value < top;
	}
	assert !pure.randomIntSync(-top - 1, 0).ok;
	assert !pure.randomIntSync(0, top + 1).ok;
}
