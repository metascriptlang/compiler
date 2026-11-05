import {
	AesKey, sealSync, openSync, seal, open,
	cbcEncryptSync, cbcDecryptSync, cbcEncrypt, cbcDecrypt,
} from "std/crypto/pure/aesNative";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";

when (c) {
	import {
		AesKey as NativeKey,
		sealSync as nativeSeal, openSync as nativeOpen,
		cbcEncryptSync as nativeCbcEncrypt,
		cbcDecryptSync as nativeCbcDecrypt,
	} from "std/crypto/aes";
}
import { encodeHex, decodeHex } from "std/core/encoding";
import { readFile } from "std/fs";
import {
	JsonKind, asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "private AES GCM API checks supported Wycheproof cases and refusals" {
	const text = readFile("std/crypto/test/vectors/aes_gcm_test.json");
	assert text.ok;
	const parsed = parseJson(text.value);
	assert parsed.ok;
	const groups = parsed.value.getDynamicField("testGroups");
	assert groups.kind == JsonKind.Array;
	let valid = 0;
	let invalid = 0;
	let unsupportedKey = 0;
	let foreignNonceBlob = 0;
	for (let g = 0; g < groups.length(); g++) {
		const group = groups.at(g);
		assert group.getDynamicField("tagSize").asInt32() == 128;
		const tests = group.getDynamicField("tests");
		assert tests.kind == JsonKind.Array;
		for (let t = 0; t < tests.length(); t++) {
			const vector = tests.at(t);
			const raw = vector.getDynamicField("key").asString().decodeHex();
			const key = AesKey.import(raw);
			if (raw.length == 24) {
				assert !key.ok;
				assert key.error.kind == CryptoErrorKind.InvalidKey;
				unsupportedKey++;
				continue;
			}
			assert raw.length == 16 || raw.length == 32;
			assert key.ok;
			const nonce = vector.getDynamicField("iv").asString();
			const wireHex = nonce +
				vector.getDynamicField("ct").asString() +
				vector.getDynamicField("tag").asString();
			const wire = wireHex.decodeHex();
			const opened = openSync(key.value, wire,
				vector.getDynamicField("aad").asString().decodeHex());
			const id = vector.getDynamicField("tcId").asInt32();
			const category = vector.getDynamicField("result").asString();
			assert category == "valid" || category == "invalid";
			if (nonce.length != 24) {
				assert !opened.ok, `AES foreign nonce blob tcId ${id}`;
				foreignNonceBlob++;
			} else if (category == "valid") {
				assert opened.ok, `AES GCM tcId ${id}`;
				assert opened.value.encodeHex() ==
					vector.getDynamicField("msg").asString(),
					`AES GCM plaintext tcId ${id}`;
				valid++;
			} else {
				assert !opened.ok, `AES GCM accepted tcId ${id}`;
				invalid++;
			}
			assert wire.encodeHex() == wireHex;
		}
	}
	assert valid == 79 && invalid == 54;
	assert unsupportedKey == 103 && foreignNonceBlob == 80;
	assert valid + invalid + unsupportedKey + foreignNonceBlob ==
		parsed.value.getDynamicField("numberOfTests").asInt32();
}

test "private AES API opens the NIST empty GCM vector" {
	const key = must(AesKey.import(new Array<uint8>(16)));
	const sealed = (
		"000000000000000000000000" + "58e2fccefa7e3061367f1d57a4e7455a"
	).decodeHex();
	assert must(openSync(key, sealed)).length == 0;
}

test "private AES CBC API matches the NIST first block with PKCS7" {
	const key = must(AesKey.import(
		"2b7e151628aed2a6abf7158809cf4f3c".decodeHex(),
	));
	const iv = "000102030405060708090a0b0c0d0e0f".decodeHex();
	const plain = "6bc1bee22e409f96e93d7e117393172a".decodeHex();
	const cipher = must(cbcEncryptSync(key, plain, iv));
	assert cipher.length == 32;
	assert cipher.slice(0, 16).encodeHex() ==
		"7649abac8119b246cee98e9b12e9197d";
	assert must(cbcDecryptSync(key, cipher, iv)).encodeHex() ==
		plain.encodeHex();
}

function pattern(length: int32): uint8[] {
	const bytes = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) {
		bytes[i] = ((i * 37 + 11) & 255) as uint8;
	}
	return bytes;
}

test "private AES key API copies input and export and keeps native bounds" {
	for (const length of [16, 32] as int32[]) {
		const raw = pattern(length);
		const expected = raw.encodeHex();
		const key = must(AesKey.import(raw));
		raw[0] = (raw[0] ^ 255) as uint8;
		const exported = key.exportRaw();
		assert exported.encodeHex() == expected;
		exported[0] = (exported[0] ^ 255) as uint8;
		assert key.exportRaw().encodeHex() == expected;
		assert must(AesKey.generate(length * 8)).exportRaw().length == length;
	}
	assert must(AesKey.generate()).exportRaw().length == 32;
	for (const length of [0, 1, 15, 17, 24, 31, 33] as int32[]) {
		const result = AesKey.import(pattern(length));
		assert !result.ok && result.error.kind == CryptoErrorKind.InvalidKey;
		assert result.error.operation == "AesKey.import";
	}
	for (const bits of [0, 96, 192, 255] as int32[]) {
		const result = AesKey.generate(bits);
		assert !result.ok && result.error.kind == CryptoErrorKind.InvalidInput;
		assert result.error.operation == "AesKey.generate";
	}
}

test "private AES GCM async and sync authenticate byte boundaries" {
	for (const keyLength of [16, 32] as int32[]) {
		const key = must(AesKey.import(pattern(keyLength)));
		for (const length of [0, 1, 15, 16, 17, 63, 64, 65, 4096] as int32[]) {
			const plain = pattern(length);
			const expected = plain.encodeHex();
			const sealed = must(sealSync(key, plain, "hé\0😀"));
			assert sealed.length == length + 28;
			assert must(await open(key, sealed, "hé\0😀")).encodeHex() == expected;
			const asyncSealed = must(await seal(key, plain, "hé\0😀"));
			assert must(openSync(key, asyncSealed, "hé\0😀")).encodeHex() ==
				expected;
			assert plain.encodeHex() == expected;
			const before = sealed.encodeHex();
			const wrongAad = openSync(key, sealed, "wrong");
			assert !wrongAad.ok && wrongAad.error.kind ==
				CryptoErrorKind.AuthenticationFailed;
			assert sealed.encodeHex() == before;
			sealed[sealed.length - 1] = (sealed[sealed.length - 1] ^ 1) as uint8;
			const forged = await open(key, sealed, "hé\0😀");
			assert !forged.ok && forged.error.kind ==
				CryptoErrorKind.AuthenticationFailed;
		}
		const a = must(sealSync(key, "same"));
		const b = must(sealSync(key, "same"));
		assert a.slice(0, 12).encodeHex() != b.slice(0, 12).encodeHex();
		const text = must(await seal(key, "hé\0😀"));
		assert must(openSync(key, text)).encodeHex() == "68c3a900f09f9880";
		const short = openSync(key, new Array<uint8>(27));
		assert !short.ok && short.error.kind == CryptoErrorKind.InvalidInput;
	}
}

test "private AES CBC async matches sync and refuses bad IV and padding" {
	const iv = pattern(16);
	for (const keyLength of [16, 32] as int32[]) {
		const key = must(AesKey.import(pattern(keyLength)));
		for (const length of [0, 1, 15, 16, 17, 63, 64, 65, 4096] as int32[]) {
			const plain = pattern(length);
			const expected = plain.encodeHex();
			const cipher = must(cbcEncryptSync(key, plain, iv));
			assert cipher.length == (length / 16 + 1) * 16;
			assert must(await cbcEncrypt(key, plain, iv)).encodeHex() ==
				cipher.encodeHex();
			assert must(await cbcDecrypt(key, cipher, iv)).encodeHex() == expected;
			assert plain.encodeHex() == expected;
		}
		const emptyCipher = must(cbcEncryptSync(key, "", iv));
		const changedIv = iv.slice(0);
		changedIv[15] = (changedIv[15] ^ 1) as uint8;
		const padding = cbcDecryptSync(key, emptyCipher, changedIv);
		assert !padding.ok && padding.error.kind ==
			CryptoErrorKind.DecryptionFailed;
		for (const length of [0, 15, 17] as int32[]) {
			const badIv = pattern(length);
			const enc = await cbcEncrypt(key, "", badIv);
			const dec = await cbcDecrypt(key, emptyCipher, badIv);
			assert !enc.ok && enc.error.kind == CryptoErrorKind.InvalidInput;
			assert !dec.ok && dec.error.kind == CryptoErrorKind.InvalidInput;
		}
		for (const length of [0, 1, 15, 17] as int32[]) {
			const result = cbcDecryptSync(key, pattern(length), iv);
			assert !result.ok && result.error.kind ==
				CryptoErrorKind.DecryptionFailed;
		}
	}
}

when (c) {
	test "private AES native interoperability covers both key sizes and modes" {
		const iv = pattern(16);
		for (const length of [16, 32] as int32[]) {
			const raw = pattern(length);
			const key = must(AesKey.import(raw));
			const native = must(NativeKey.import(raw));
			for (const text of ["", "hé\0😀"]) {
				const expected = text.asBytes().encodeHex();
				assert must(nativeOpen(native, must(sealSync(key, text)))).encodeHex()
					== expected;
				assert must(openSync(key, must(nativeSeal(native, text)))).encodeHex()
					== expected;
				const cipher = must(cbcEncryptSync(key, text, iv));
				const nativeCipher = must(nativeCbcEncrypt(native, text, iv));
				assert cipher.encodeHex() == nativeCipher.encodeHex();
				assert must(nativeCbcDecrypt(native, cipher, iv)).encodeHex() ==
					expected;
				assert must(cbcDecryptSync(key, nativeCipher, iv)).encodeHex() ==
					expected;
			}
		}
	}

	function consumeKey(sink key: AesKey): void {}

	test "private AES native destruction clears raw and expanded key owners" {
		const caller = pattern(32);
		const expected = caller.encodeHex();
		const key = must(AesKey.import(caller));
		const raw = key._raw;
		const schedule = key._schedule;
		consumeKey(move key);
		for (const byte of raw) assert byte == 0;
		for (const word of schedule) assert word == 0;
		assert caller.encodeHex() == expected;
	}
}
