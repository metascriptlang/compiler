import {
	blake2bSync, blake2bKeyedSync, createBlake2b,
	blake2b, blake2bKeyed,
} from "std/crypto/pure/blake2bNative";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex } from "std/core/encoding";

when (c) {
	import { Blake2bState } from "std/crypto/pure/blake2b";
	import {
		blake2bSync as nativeHash,
		blake2bKeyedSync as nativeKeyed,
		createBlake2b as nativeCreate,
	} from "./oracle/blake2b";
}

function pattern(length: int32): uint8[] {
	const bytes = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) bytes[i] = (i & 255) as uint8;
	return bytes;
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "private Blake2b API preserves default32 independent vectors" {
	assert must(blake2bSync("abc")).encodeHex() ==
		"bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319";
	assert must(blake2bKeyedSync("key", "abc")).encodeHex() ==
		"0330531d097355a3f72e80d55c1245ccf79f1704431c6e3887938320442c23c0";
}

test "private Blake2b streaming API preserves RFC7693 abc64" {
	const hash = must(createBlake2b(64));
	hash.update("a").update("bc");
	const expected =
		"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d" +
		"87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
	assert hash.digest().encodeHex() == expected;
	assert must(blake2bSync("abc", 64)).encodeHex() == expected;
}

test "private Blake2b API preserves key versus hash size error precedence" {
	const key = blake2bKeyedSync("", "abc", 0);
	assert !key.ok && key.error.kind == CryptoErrorKind.InvalidKey;
	assert key.error.operation == "blake2bKeyed";
	const size = blake2bSync("abc", 65);
	assert !size.ok && size.error.kind == CryptoErrorKind.InvalidInput;
	const stream = createBlake2b(0);
	assert !stream.ok && stream.error.operation == "createBlake2b";
}

test "private Blake2b async methods preserve UTF8 and binary bytes" {
	const text = "hé\0😀";
	const bytes = [104, 195, 169, 0, 240, 159, 152, 128] as uint8[];
	assert must(await blake2b(text)).encodeHex() ==
		must(blake2bSync(bytes)).encodeHex();
	const key = "é".repeat(32);
	assert must(await blake2bKeyed(key, text, 48)).encodeHex() ==
		must(blake2bKeyedSync(key, bytes, 48)).encodeHex();
	assert !(await blake2b(text, 0)).ok;
	assert !(await blake2bKeyed("", text)).ok;
}

test "private Blake2b streaming covers every output size" {
	const bytes = pattern(129);
	for (let size: int32 = 1; size <= 64; size++) {
		const expected = must(blake2bSync(bytes, size));
		const hash = must(createBlake2b(size));
		hash.update(bytes.slice(0, 127)).update(bytes.slice(127));
		const digest = hash.digest();
		assert digest.length == size;
		assert digest.encodeHex() == expected.encodeHex();
	}
}

test "private Blake2b keeps caller owners at all block edges" {
	const key = pattern(64);
	const keyBefore = key.encodeHex();
	for (const length of [0, 1, 127, 128, 129, 255, 256, 257,
		4096] as int32[]) {
		const bytes = pattern(length);
		const before = bytes.encodeHex();
		const hash = must(createBlake2b());
		hash.update([] as uint8[]).update(bytes.slice(0, 1))
			.update(bytes.slice(1));
		assert hash.digest().encodeHex() == must(blake2bSync(bytes)).encodeHex();
		assert must(blake2bKeyedSync(key, bytes)).length == 32;
		assert bytes.encodeHex() == before;
	}
	assert key.encodeHex() == keyBefore;
}

test "private Blake2b refuses invalid output and UTF8 key sizes" {
	for (const size of [-2147483648, -1, 0, 65, 2147483647] as int32[]) {
		const plain = blake2bSync("abc", size);
		const keyed = blake2bKeyedSync("key", "abc", size);
		const stream = createBlake2b(size);
		assert !plain.ok && plain.error.kind == CryptoErrorKind.InvalidInput;
		assert !keyed.ok && keyed.error.kind == CryptoErrorKind.InvalidInput;
		assert !stream.ok && stream.error.kind == CryptoErrorKind.InvalidInput;
		assert plain.error.operation == "blake2b";
		assert keyed.error.operation == "blake2bKeyed";
	}
	assert blake2bKeyedSync(pattern(1), "").ok;
	assert blake2bKeyedSync(pattern(64), "").ok;
	assert !blake2bKeyedSync(pattern(65), "").ok;
	assert blake2bKeyedSync("é".repeat(32), "").ok;
	assert !blake2bKeyedSync("é".repeat(33), "").ok;
}

test "private Blake2b consumed state is cleared and cannot be reused" {
	const hash = must(createBlake2b()).update("secret\0message");
	const state = hash._state;
	const digest = hash.digest();
	const expected = digest.encodeHex();
	assert state.finished;
	for (const word of state.h) assert word == 0;
	for (const byte of state.block) assert byte == 0;
	when (js) {
		for (const word of state.m) assert word == 0;
		for (const word of state.v) assert word == 0;
	}
	let digestError = "";
	let updateError = "";
	try { hash.digest(); } catch (error) { digestError = error.message; }
	try { hash.update("more"); } catch (error) { updateError = error.message; }
	assert digestError ==
		"Blake2b.digest: the hasher already produced its digest";
	assert updateError ==
		"Blake2b.update: the hasher already produced its digest";
	assert digest.encodeHex() == expected;
}

when (c) {
	test "private Blake2b every output size matches native keyed and streamed" {
		const bytes = pattern(129);
		const key = pattern(64);
		for (let size: int32 = 1; size <= 64; size++) {
			assert must(blake2bSync(bytes, size)).encodeHex() ==
				must(nativeHash(bytes, size)).encodeHex();
			assert must(blake2bKeyedSync(key, bytes, size)).encodeHex() ==
				must(nativeKeyed(key, bytes, size)).encodeHex();
			const native = must(nativeCreate(size));
			native.update(bytes.slice(0, 128)).update(bytes.slice(128));
			assert native.digest().encodeHex() ==
				must(blake2bSync(bytes, size)).encodeHex();
		}
	}

	test "private Blake2b native destruction finalises abandoned state" {
		const state = abandonChained();
		for (const word of state.h) assert word == 0;
		for (const byte of state.block) assert byte == 0;
	}

	test "private Blake2b named scope finalises at its last owner" {
		const state = abandonDirect();
		for (const word of state.h) assert word == 0;
		for (const byte of state.block) assert byte == 0;
	}

	function abandonChained(): Blake2bState {
		const hash = must(createBlake2b()).update("unfinished secret");
		const state = hash._state;
		return state;
	}

	function abandonDirect(): Blake2bState {
		const hash = must(createBlake2b());
		hash.update("unfinished secret");
		const state = hash._state;
		return state;
	}
}
