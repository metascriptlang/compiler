import { encodeHex } from "../../core/encoding";
import { HashAlgorithm, createHash, digestSync, toHex } from "std/crypto/oracle";
import { newHash, updateHash, finishHash, hashOf } from "./hash";
import { kindSha256, kindSha224, kindSha512, kindSha384 } from "./state";

const kinds: int32[] = [kindSha256, kindSha224, kindSha512, kindSha384];
const names: HashAlgorithm[] = ["sha256", "sha224", "sha512", "sha384"];

let seed: uint32 = 0x9e3779b9;

function nextByte(): uint8 {
	seed = seed * 1664525 + 1013904223;
	return ((seed >> 24) & 255) as uint8;
}

function randomBytes(n: int32): uint8[] {
	const out = new Array<uint8>(n);
	for (let i = 0; i < n; i++) out[i] = nextByte();
	return out;
}

function vendor(algorithm: HashAlgorithm, data: uint8[]): string {
	const result = digestSync(algorithm, data);
	if (!result.ok) throw new Error("vendor digest failed");
	return toHex(result.value);
}

test "sha2 matches vendor digest for every length 0..2048" {
	for (let n = 0; n <= 2048; n++) {
		const data = randomBytes(n);
		for (let k = 0; k < 4; k++) assert hashOf(kinds[k], data).encodeHex() == vendor(names[k], data);
	}
}

test "sha2 streaming matches vendor createHash at random splits" {
	for (let round = 0; round < 400; round++) {
		const n = ((nextByte() as int32) << 3) + (nextByte() as int32);
		const data = randomBytes(n);
		const cut = n == 0 ? 0 : ((nextByte() as int32) * 7) % (n + 1);
		const k = round & 3;
		const pure = newHash(kinds[k]);
		updateHash(pure, data.slice(0, cut));
		updateHash(pure, data.slice(cut));
		const native = createHash(names[k]);
		native.update(data.slice(0, cut));
		native.update(data.slice(cut));
		assert finishHash(pure).encodeHex() == toHex(native.digest());
	}
}
