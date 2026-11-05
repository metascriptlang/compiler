import {
	RsaPrivateKey, RsaPublicKey, RsaPadding,
	signSync, verifySync, encryptSync, decryptSync,
	sign, verify, encrypt, decrypt,
} from "std/crypto/pure/rsaNative";
import {
	keyAPkcs8, keyAPkcs1, keyASpki, keyAPkcs1Public, keyBSpki,
	key1024Pkcs8, key1024Spki, message,
	pkcs1Sha256, pkcs1Sha384, pkcs1Sha512, pkcs1Sha1,
	pssSha256, pssSha384, pssSha512,
	pssMaxSaltSha256, pssNoSaltSha256, oaepSha256,
} from "std/crypto/pure/rsaFixtures";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex, decodeHex } from "std/core/encoding";
import { readFile } from "std/fs";
import {
	JsonKind, asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";
import {
	rsaPublicFromSpki, rsaVerifyPkcs1,
} from "std/crypto/pure/rsa";

when (c) {
	import {
		RsaPrivateKey as NativePrivateKey,
		RsaPublicKey as NativePublicKey,
		signSync as nativeSign, verifySync as nativeVerify,
		encryptSync as nativeEncrypt, decryptSync as nativeDecrypt,
	} from "std/crypto/rsa";
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function refused<T>(
	result: Result<T, CryptoError>,
	kind: CryptoErrorKind,
	operation: string,
): void {
	assert !result.ok;
	if (!result.ok) {
		assert result.error.kind == kind;
		assert result.error.operation == operation;
	}
}

test "private RSA PKCS1 verify API checks all 776 pinned Wycheproof cases" {
	let valid = 0;
	let invalid = 0;
	let acceptable = 0;
	for (const hash of ["sha256", "sha384", "sha512"]) {
		const text = readFile(
			`std/crypto/test/vectors/rsa_signature_2048_${hash}_test.json`,
		);
		assert text.ok;
		const parsed = parseJson(text.value);
		assert parsed.ok;
		const groups = parsed.value.getDynamicField("testGroups");
		assert groups.kind == JsonKind.Array;
		let count = 0;
		for (let g = 0; g < groups.length(); g++) {
			const group = groups.at(g);
			const expectedHash = hash == "sha256" ? "SHA-256" :
				hash == "sha384" ? "SHA-384" : "SHA-512";
			assert group.getDynamicField("sha").asString() == expectedHash;
			const key = must(RsaPublicKey.importPemSync(
				group.getDynamicField("publicKeyPem").asString(),
			));
			const raw = rsaPublicFromSpki(
				group.getDynamicField("publicKeyDer").asString().decodeHex(),
			);
			assert raw != null;
			const tests = group.getDynamicField("tests");
			assert tests.kind == JsonKind.Array;
			for (let t = 0; t < tests.length(); t++) {
				const vector = tests.at(t);
				const id = vector.getDynamicField("tcId").asInt32();
				const data = vector.getDynamicField("msg").asString().decodeHex();
				const signature = vector.getDynamicField("sig").asString()
					.decodeHex();
				const accepted = verifySync(key, data, signature, hash, "pkcs1v15");
				const category = vector.getDynamicField("result").asString();
				if (category == "valid") {
					assert accepted, `RSA PKCS1 ${hash} tcId ${id}: valid rejected`;
					valid++;
				} else if (category == "invalid") {
					assert !accepted, `RSA PKCS1 ${hash} tcId ${id}: invalid accepted`;
					invalid++;
				} else {
					assert category == "acceptable" && id == 8;
					assert accepted == rsaVerifyPkcs1(raw, hash, data, signature),
						`RSA PKCS1 ${hash} tcId ${id}: changed acceptable-case policy`;
					acceptable++;
				}
				count++;
			}
		}
		assert count == parsed.value.getDynamicField("numberOfTests").asInt32();
		assert count == (hash == "sha384" ? 258 : 259);
	}
	assert valid == 24 && invalid == 749 && acceptable == 3;
}

test "private RSA key API preserves every native PEM format" {
	for (const pem of [keyAPkcs8, keyAPkcs1]) {
		const key = must(RsaPrivateKey.importPemSync(pem));
		assert must(key.exportPemSync()) == keyAPkcs8;
		assert must(key.publicKey().exportPemSync()) == keyASpki;
	}
	for (const pem of [keyASpki, keyAPkcs1Public]) {
		const publicKey = must(RsaPublicKey.importPemSync(pem));
		assert must(publicKey.exportPemSync()) == keyASpki;
	}
}

test "private RSA import refuses malformed foreign and undersized keys" {
	for (const pem of ["", "bad PEM", keyASpki, key1024Pkcs8]) {
		const result = RsaPrivateKey.importPemSync(pem);
		refused(result, CryptoErrorKind.InvalidKey, "RsaPrivateKey.importPem");
		when (c) {
			const native = NativePrivateKey.importPemSync(pem);
			assert !native.ok && !result.ok;
			assert native.error.message == result.error.message;
		}
	}
	for (const pem of ["", "bad PEM", keyAPkcs8, key1024Spki]) {
		const result = RsaPublicKey.importPemSync(pem);
		refused(result, CryptoErrorKind.InvalidKey, "RsaPublicKey.importPem");
		when (c) {
			const native = NativePublicKey.importPemSync(pem);
			assert !native.ok && !result.ok;
			assert native.error.message == result.error.message;
		}
	}
}

test "private RSA signing API matches all native PKCS1 hash fixtures" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const publicKey = key.publicKey();
	const hashes = ["sha256", "sha384", "sha512"];
	const signatures = [pkcs1Sha256, pkcs1Sha384, pkcs1Sha512];
	for (let i: int32 = 0; i < 3; i++) {
		const signature = must(signSync(key, message, hashes[i]));
		assert signature.encodeHex() == signatures[i];
		assert verifySync(publicKey, message, signature, hashes[i]);
		assert !verifySync(publicKey, message + "!", signature, hashes[i]);
	}
	assert must(signSync(key, message)).encodeHex() == pkcs1Sha256;
	assert verifySync(publicKey, message, pkcs1Sha256.decodeHex());
}

test "private RSA PSS accepts all hash fixtures and variable salt lengths" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const publicKey = key.publicKey();
	const other = must(RsaPublicKey.importPemSync(keyBSpki));
	const hashes = ["sha256", "sha384", "sha512"];
	const signatures = [pssSha256, pssSha384, pssSha512];
	for (let i: int32 = 0; i < 3; i++) {
		assert verifySync(
			publicKey, message, signatures[i].decodeHex(), hashes[i], "pss",
		);
		const signature = must(signSync(key, message, hashes[i], "pss"));
		assert verifySync(publicKey, message, signature, hashes[i], "pss");
		assert !verifySync(other, message, signature, hashes[i], "pss");
		assert !verifySync(publicKey, message + "!", signature, hashes[i], "pss");
	}
	for (const signature of [pssNoSaltSha256, pssMaxSaltSha256]) {
		assert verifySync(
			publicKey, message, signature.decodeHex(), "sha256", "pss",
		);
	}
}

test "private RSA keeps native sign refusal and SHA1 verification policy" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const publicKey = key.publicKey();
	for (const hash of ["sha1", "sha224", "md5", "sha3-256", "bogus"]) {
		for (const padding of ["pkcs1v15", "pss"] as RsaPadding[]) {
			const result = signSync(key, message, hash, padding);
			refused(result, CryptoErrorKind.SignatureFailed, "rsa.sign");
			when (c) {
				const nativeKey = must(NativePrivateKey.importPemSync(keyAPkcs8));
				const native = nativeSign(nativeKey, message, hash, padding);
				assert !native.ok && !result.ok;
				assert native.error.message == result.error.message;
			}
		}
	}
	assert verifySync(publicKey, message, pkcs1Sha1.decodeHex(), "sha1");
	for (const hash of ["sha224", "md5", "sha3-256", "bogus"]) {
		assert !verifySync(publicKey, message, pkcs1Sha256.decodeHex(), hash);
	}
	assert !verifySync(publicKey, message, []);
}

when (c) {
	test "private RSA signatures interoperate with native for every mode" {
		const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
		const publicKey = key.publicKey();
		const nativeKey = must(NativePrivateKey.importPemSync(keyAPkcs8));
		const nativePublic = nativeKey.publicKey();
		const text = "hé\0😀";
		for (const hash of ["sha256", "sha384", "sha512"]) {
			for (const padding of ["pkcs1v15", "pss"] as RsaPadding[]) {
				const signature = must(signSync(key, text, hash, padding));
				assert nativeVerify(nativePublic, text, signature, hash, padding);
				const native = must(nativeSign(nativeKey, text, hash, padding));
				assert verifySync(publicKey, text, native, hash, padding);
			}
		}
	}
}

test "private RSA OAEP decrypts independent fixture and refuses tampering" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const ciphertext = oaepSha256.decodeHex();
	assert must(decryptSync(key, ciphertext)).encodeHex() ==
		message.asBytes().encodeHex();
	ciphertext[50] = (ciphertext[50] ^ 1) as uint8;
	refused(decryptSync(key, ciphertext),
		CryptoErrorKind.DecryptionFailed, "rsa.decrypt");
	refused(decryptSync(key, []),
		CryptoErrorKind.DecryptionFailed, "rsa.decrypt");
}

test "private RSA OAEP preserves binary inputs and enforces payload limit" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const publicKey = key.publicKey();
	for (const length of [1, 190] as int32[]) {
		const data = new Array<uint8>(length);
		for (let i: int32 = 0; i < length; i++) {
			data[i] = ((i * 37 + 128) & 255) as uint8;
		}
		const expected = data.encodeHex();
		const ciphertext = must(encryptSync(publicKey, data));
		assert ciphertext.length == 256;
		assert must(decryptSync(key, ciphertext)).encodeHex() == expected;
		assert data.encodeHex() == expected;
		when (c) {
			const nativeKey = must(NativePrivateKey.importPemSync(keyAPkcs8));
			const opened = must(nativeDecrypt(nativeKey, ciphertext));
			assert opened.encodeHex() == expected;
			const native = must(nativeEncrypt(nativeKey.publicKey(), data));
			assert must(decryptSync(key, native)).encodeHex() == expected;
		}
	}
	refused(encryptSync(publicKey, new Array<uint8>(191)),
		CryptoErrorKind.EncryptionFailed, "rsa.encrypt");
}

test "private RSA async surface matches sync for UTF8 and NUL bytes" {
	const key = must(await RsaPrivateKey.importPem(keyAPkcs1));
	const publicKey = must(await RsaPublicKey.importPem(keyAPkcs1Public));
	assert must(await key.exportPem()) == keyAPkcs8;
	assert must(await publicKey.exportPem()) == keyASpki;
	const text = "hé\0😀";
	const signature = must(await sign(key, text));
	assert await verify(publicKey, text, signature);
	assert !await verify(publicKey, text + "!", signature);
	const ciphertext = must(await encrypt(publicKey, text));
	assert must(await decrypt(key, ciphertext)).encodeHex() ==
		"68c3a900f09f9880";
}

test "private RSA refuses unsupported key-generation sizes consistently" {
	for (const bits of [-1, 0, 1024, 1536, 2049, 8192] as int32[]) {
		const sync = RsaPrivateKey.generateSync(bits);
		const done = await RsaPrivateKey.generate(bits);
		refused(sync, CryptoErrorKind.InvalidInput, "RsaPrivateKey.generate");
		refused(done, CryptoErrorKind.InvalidInput, "RsaPrivateKey.generate");
		when (c) {
			const native = NativePrivateKey.generateSync(bits);
			assert !native.ok && !sync.ok;
			assert native.error.message == sync.error.message;
		}
	}
}

when (c) {
function consumePrivateKey(sink key: RsaPrivateKey): void {}

test "private RSA destruction wipes private data and keeps public half" {
	const key = must(RsaPrivateKey.importPemSync(keyAPkcs8));
	const data = key._data;
	assert data != null;
	if (data == null) throw new Error("missing private state");
	const privateBytes = [data.d, data.p, data.q, data.dp, data.dq, data.qi];
	const p = data.pModulus;
	const q = data.qModulus;
	const publicKey = key.publicKey();
	const signature = must(signSync(key, message));
	consumePrivateKey(move key);
	assert data.pModulus == null && data.qModulus == null;
	for (const bytes of privateBytes) {
		for (const byte of bytes) assert byte == 0;
	}
	for (const modulus of [p, q]) {
		if (modulus != null) {
			for (const words of [modulus.v, modulus.rr]) {
				for (const word of words) assert word == 0;
			}
			for (const words of [modulus.w, modulus.wrr, modulus.wone]) {
				for (const word of words) assert word == 0;
			}
		}
	}
	assert verifySync(publicKey, message, signature);
	assert must(publicKey.exportPemSync()) == keyASpki;
}
}
