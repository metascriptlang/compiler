import { encodeHex } from "std/core/encoding";
import {
	finishHash,
	finishHashInto,
	hashOf,
	newHash,
	updateHash,
} from "std/crypto/pure/hash";
import {
	finishHmac,
	finishHmacInto,
	hmacOf,
	newHmac,
	updateHmac,
} from "std/crypto/pure/hmac";
import { kindSha256, kindSha512 } from "std/crypto/pure/state";

test "short hash output is refused without changing state or destination" {
	const message = "abc".asBytes().slice(0);
	for (const kind of [kindSha256, kindSha512]) {
		const expected = hashOf(kind, message);
		for (const size of [0, (expected.length - 1) as int32]) {
			const state = newHash(kind);
			updateHash(state, message);
			const output = new Array<uint8>(size);
			output.fill(0xaa);
			let refused = false;
			try {
				finishHashInto(state, output);
			} catch (error) {
				refused = true;
			}
			assert refused;
			assert !state.finished;
			for (const byte of output) assert byte == 0xaa;
			assert finishHash(state).encodeHex() == expected.encodeHex();
		}
	}
}

test "short HMAC output is refused without consuming the keyed message" {
	const key = "key".asBytes().slice(0);
	const message = "abc".asBytes().slice(0);
	for (const kind of [kindSha256, kindSha512]) {
		const expected = hmacOf(kind, key, message);
		for (const size of [0, (expected.length - 1) as int32]) {
			const state = newHmac(kind, key);
			updateHmac(state, message);
			const output = new Array<uint8>(size);
			output.fill(0xaa);
			let refused = false;
			try {
				finishHmacInto(state, output);
			} catch (error) {
				refused = true;
			}
			assert refused;
			assert !state.inner.finished;
			for (const byte of output) assert byte == 0xaa;
			assert finishHmac(state).encodeHex() == expected.encodeHex();
		}
	}
}

test "hash output writes its digest and preserves an oversized tail" {
	const message = "abc".asBytes().slice(0);
	for (const kind of [kindSha256, kindSha512]) {
		const expected = hashOf(kind, message);
		const output = new Array<uint8>(expected.length + 1);
		output.fill(0xaa);
		const state = newHash(kind);
		updateHash(state, message);
		finishHashInto(state, output);
		assert output.slice(0, expected.length).encodeHex() ==
			expected.encodeHex();
		assert output[expected.length] == 0xaa;
	}
}

test "HMAC output writes its digest and preserves an oversized tail" {
	const key = "key".asBytes().slice(0);
	const message = "abc".asBytes().slice(0);
	for (const kind of [kindSha256, kindSha512]) {
		const expected = hmacOf(kind, key, message);
		const output = new Array<uint8>(expected.length + 1);
		output.fill(0xaa);
		const state = newHmac(kind, key);
		updateHmac(state, message);
		finishHmacInto(state, output);
		assert output.slice(0, expected.length).encodeHex() ==
			expected.encodeHex();
		assert output[expected.length] == 0xaa;
	}
}
