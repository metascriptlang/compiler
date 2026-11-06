import { digestSync, toHex } from "std/crypto/oracle";
import { ripemd160Of, newRipemd160, updateRipemd160, finishRipemd160 } from "./ripemd160";

function vendorHex(data: uint8[]): string {
	const result = digestSync("ripemd160", data);
	if (!result.ok) throw new Error("vendor ripemd160 failed");
	return toHex(result.value);
}

function seededBytes(seed: uint32, n: int32): uint8[] {
	let x = seed | 1;
	const out = new Array<uint8>(n);
	for (let i = 0; i < n; i++) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		out[i] = (x & 255) as uint8;
	}
	return out;
}

test "ripemd160 matches the vendor on every length 0..2048" {
	for (let n = 0; n <= 2048; n++) {
		const data = seededBytes((n + 1) as uint32, n);
		assert ripemd160Of(data).encodeHex() == vendorHex(data);
	}
}

test "ripemd160 streaming matches the vendor at block boundaries" {
	for (const n of [63, 64, 65, 119, 120, 127, 128, 129, 4095, 4096, 4097]) {
		const data = seededBytes((n * 7) as uint32, n);
		const expected = vendorHex(data);
		for (const cut of [0, 1, 55, 56, 64, n >> 1, n]) {
			const s = newRipemd160();
			updateRipemd160(s, data.slice(0, cut));
			updateRipemd160(s, data.slice(cut));
			assert finishRipemd160(s).encodeHex() == expected;
		}
	}
}
