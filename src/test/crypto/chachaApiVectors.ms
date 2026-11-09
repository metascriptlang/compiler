import {
	ChaChaKey, sealSync, openSync, seal, open,
} from "std/crypto/pure/chachaNative";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex, decodeHex } from "std/core/encoding";
import { readFile } from "std/fs";
import {
	JsonKind, asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";

when (c) {
	import {
		ChaChaKey as NativeKey,
		sealSync as nativeSeal,
		openSync as nativeOpen,
	} from "./oracle/chacha20";
}

function pattern(length: int32): uint8[] {
	const bytes = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) {
		bytes[i] = ((i * 37 + 11) & 255) as uint8;
	}
	return bytes;
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "private ChaCha API opens or rejects every pinned Wycheproof wire blob" {
	const text = readFile(
		"std/crypto/test/vectors/xchacha20_poly1305_test.json",
	);
	assert text.ok;
	const parsed = parseJson(text.value);
	assert parsed.ok;
	const groups = parsed.value.getDynamicField("testGroups");
	assert groups.kind == JsonKind.Array;
	let valid = 0;
	let invalid = 0;
	let malformedNonce = 0;
	for (let g = 0; g < groups.length(); g++) {
		const tests = groups.at(g).getDynamicField("tests");
		assert tests.kind == JsonKind.Array;
		for (let t = 0; t < tests.length(); t++) {
			const vector = tests.at(t);
			const category = vector.getDynamicField("result").asString();
			assert category == "valid" || category == "invalid";
			const nonce = vector.getDynamicField("iv").asString();
			const wireHex = nonce +
				vector.getDynamicField("ct").asString() +
				vector.getDynamicField("tag").asString();
			const wire = wireHex.decodeHex();
			const key = must(ChaChaKey.import(
				vector.getDynamicField("key").asString().decodeHex(),
			));
			const opened = openSync(key, wire,
				vector.getDynamicField("aad").asString().decodeHex());
			const id = vector.getDynamicField("tcId").asInt32();
			if (category == "valid") {
				assert nonce.length == 48;
				assert opened.ok, `XChaCha tcId ${id}`;
				assert opened.value.encodeHex() ==
					vector.getDynamicField("msg").asString(),
					`XChaCha plaintext tcId ${id}`;
				valid++;
			} else {
				assert !opened.ok, `XChaCha accepted tcId ${id}`;
				invalid++;
				if (nonce.length != 48) malformedNonce++;
			}
			assert wire.encodeHex() == wireHex;
		}
	}
	assert valid == 246 && invalid == 69 && malformedNonce == 9;
	assert valid + invalid ==
		parsed.value.getDynamicField("numberOfTests").asInt32();
}

test "private ChaCha API keeps nonce ciphertext and tag wire format" {
	const key = must(ChaChaKey.import(new Array<uint8>(32)));
	const sealed = must(sealSync(key, "hé\0😀", "aad"));
	assert sealed.length == 48;
	assert must(openSync(key, sealed, "aad")).encodeHex() ==
		"68c3a900f09f9880";
	sealed[sealed.length - 1] = (sealed[sealed.length - 1] ^ 1) as uint8;
	const forged = openSync(key, sealed, "aad");
	assert !forged.ok && forged.error.kind ==
		CryptoErrorKind.AuthenticationFailed;
}

test "private ChaCha API requires exactly 32 UTF8 key bytes" {
	for (const length of [0, 1, 31, 33, 64] as int32[]) {
		const result = ChaChaKey.import(pattern(length));
		assert !result.ok && result.error.kind == CryptoErrorKind.InvalidKey;
		assert result.error.operation == "ChaChaKey.import";
	}
	assert ChaChaKey.import("é".repeat(16)).ok;
	assert !ChaChaKey.import("é".repeat(32)).ok;
}

test "private ChaCha API refuses short blobs and mismatched AAD" {
	const key = must(ChaChaKey.import(pattern(32)));
	for (const length of [0, 1, 23, 24, 39] as int32[]) {
		const result = openSync(key, pattern(length));
		assert !result.ok && result.error.kind == CryptoErrorKind.InvalidInput;
		assert result.error.operation == "open";
	}
	const sealed = must(sealSync(key, "", "hé\0😀"));
	assert sealed.length == 40;
	assert must(openSync(key, sealed, "hé\0😀")).length == 0;
	const wrong = openSync(key, sealed, "hé\0😁");
	const missing = openSync(key, sealed);
	assert !wrong.ok && wrong.error.kind == CryptoErrorKind.AuthenticationFailed;
	assert !missing.ok && missing.error.kind == CryptoErrorKind.AuthenticationFailed;
	const otherKey = must(ChaChaKey.import(new Array<uint8>(32)));
	assert !openSync(otherKey, sealed, "hé\0😀").ok;
}

test "private ChaCha API owns imported keys and copies each export" {
	const caller = pattern(32);
	const expected = caller.encodeHex();
	const key = must(ChaChaKey.import(caller));
	caller[0] = (caller[0] ^ 255) as uint8;
	assert key.exportRaw().encodeHex() == expected;
	const exported = key.exportRaw();
	exported[0] = (exported[0] ^ 255) as uint8;
	assert key.exportRaw().encodeHex() == expected;
	const generated = must(ChaChaKey.generate());
	assert generated.exportRaw().length == 32;
	assert must(openSync(generated, must(sealSync(generated, "")))).length == 0;
}

test "private ChaCha API preserves binary owners at block edges" {
	const callerKey = pattern(32);
	const keyBefore = callerKey.encodeHex();
	const key = must(ChaChaKey.import(callerKey));
	const aad = pattern(17);
	const aadBefore = aad.encodeHex();
	for (const length of [0, 1, 15, 16, 17, 63, 64, 65,
		127, 128, 129, 4096] as int32[]) {
		const plain = pattern(length);
		const expected = plain.encodeHex();
		const sealed = must(sealSync(key, plain, aad));
		const sealedBefore = sealed.encodeHex();
		assert sealed.length == length + 40;
		assert must(openSync(key, sealed, aad)).encodeHex() == expected;
		assert sealed.encodeHex() == sealedBefore;
		assert plain.encodeHex() == expected;
	}
	assert callerKey.encodeHex() == keyBefore;
	assert aad.encodeHex() == aadBefore;
	const first = must(sealSync(key, "same"));
	const second = must(sealSync(key, "same"));
	assert first.slice(0, 24).encodeHex() != second.slice(0, 24).encodeHex();
	assert must(openSync(key, first)).toString() == "same";
}

test "private ChaCha API async and sync consumers interoperate" {
	const key = must(ChaChaKey.import(pattern(32)));
	const text = "hé\0😀";
	const expected = "68c3a900f09f9880";
	assert must(openSync(key, must(await seal(key, text)))).encodeHex() == expected;
	assert must(await open(key, must(sealSync(key, text)))).encodeHex() == expected;
	const sealed = must(await seal(key, text, "aad"));
	assert must(await open(key, sealed, "aad")).encodeHex() == expected;
	const bad = await open(key, sealed, "bad");
	assert !bad.ok && bad.error.kind == CryptoErrorKind.AuthenticationFailed;
	const short = await open(key, pattern(39));
	assert !short.ok && short.error.kind == CryptoErrorKind.InvalidInput;
}

when (c) {
	test "private ChaCha API interoperates with native wire buffers" {
		const raw = pattern(32);
		const key = must(ChaChaKey.import(raw));
		const native = must(NativeKey.import(raw));
		for (const length of [0, 1, 63, 64, 65, 4096] as int32[]) {
			const plain = pattern(length);
			const expected = plain.encodeHex();
			const aad = "hé\0😀";
			assert must(nativeOpen(native, must(sealSync(key, plain, aad)), aad))
				.encodeHex() == expected;
			assert must(openSync(key, must(nativeSeal(native, plain, aad)), aad))
				.encodeHex() == expected;
		}
	}

	function consumeKey(sink key: ChaChaKey): void {}

	test "private ChaCha API native destruction clears cached key words" {
		const caller = pattern(32);
		const expected = caller.encodeHex();
		const key = must(ChaChaKey.import(caller));
		const words = key._words;
		consumeKey(move key);
		for (const word of words) assert word == 0;
		assert caller.encodeHex() == expected;
	}
}
