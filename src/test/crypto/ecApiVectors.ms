import {
	EcPrivateKey, EcPublicKey, EcCurve, ecdsaSignSync, ecdsaVerifySync,
	ecdsaSign, ecdsaVerify, ecdhSync, ecdh,
} from "std/crypto/pure/ecNative";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { readFile } from "std/fs";
import {
	asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";
import { pemEncode } from "std/crypto/pure/pem";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import {
	ownCurve, ecPublicPoint, ecPublicFromSpki, ecPublicToSpki,
	ecPrivateToSec1, ecdsaRawToDer, ecdsaDerToRaw,
} from "std/crypto/pure/weierstrass";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "private EC public PEM accepts bounded BER length encodings" {
	let checked = 0;
	let refused = 0;
	for (const name of ["p256", "p384"] as EcCurve[]) {
		const file = name == "p256" ? "secp256r1" : "secp384r1";
		const ids = name == "p256" ?
			[391, 392, 393, 394, 490, 491, 492, 493, 576, 577] :
			[826, 827, 828, 829, 925, 926, 927, 928, 1011, 1012];
		const text = readFile(
			`std/crypto/test/vectors/ecdh_${file}_test.json`,
		);
		assert text.ok;
		const root = parseJson(text.value);
		assert root.ok;
		const groups = root.value.getDynamicField("testGroups");
		for (let g = 0; g < groups.length(); g++) {
			const tests = groups.at(g).getDynamicField("tests");
			for (let t = 0; t < tests.length(); t++) {
				const vector = tests.at(t);
				const id = vector.getDynamicField("tcId").asInt32();
				if (!ids.includes(id)) continue;
				checked++;
				const curve = ownCurve(name == "p256" ? p256 : p384);
				const der = vector.getDynamicField("public")
					.asString().decodeHex();
				assert ecPublicFromSpki(der, [curve]) == null;
				const imported = EcPublicKey.importPemSync(
					pemEncode("PUBLIC KEY", der),
				);
				if (!imported.ok) {
					refused++;
					continue;
				}
				assert imported.value.curve == name;
				let scalar = vector.getDynamicField("private")
					.asString().decodeHex();
				while (scalar.length > curve.size && scalar[0] == 0) {
					scalar = scalar.slice(1);
				}
				assert scalar.length <= curve.size;
				const privateKey = must(EcPrivateKey.importPemSync(pemEncode(
					"EC PRIVATE KEY",
					ecPrivateToSec1({ curve, d: scalar, point: [] }),
				)));
				assert must(ecdhSync(privateKey, imported.value)).encodeHex() ==
					vector.getDynamicField("shared").asString(), `${file}:${id}`;
				const lines = must(imported.value.exportPemSync()).split("\n");
				const canonical = lines.slice(1, lines.length - 2)
					.join("").decodeBase64();
				assert ecPublicFromSpki(canonical, [curve]) != null;
			}
		}
	}
	assert checked == 20;
	assert refused == 0, `bounded BER public PEM refused ${refused}/20`;
}

test "private EC PEM framing retains length bounds and root exhaustion" {
	for (const name of ["p256", "p384"] as EcCurve[]) {
		const curve = ownCurve(name == "p256" ? p256 : p384);
		const scalar: uint8[] = new Array<uint8>(curve.size);
		scalar[curve.size - 1] = 1;
		const point = ecPublicPoint(curve, scalar);
		assert point != null;
		const der = ecPublicToSpki({ curve, point });
		const malformed: uint8[][] = [
			[0x30, 0x80, ...der.slice(2), 0, 0],
			[0x30, 0x84, 0x7f, 0xff, 0xff, 0xff, ...der.slice(2)],
			[0x30, 0x84, 0x80, 0, 0, 0, ...der.slice(2)],
			[0x30, 0x84, 0xff, 0xff, 0xff, 0xff, ...der.slice(2)],
			[0x30, 0x84, 0, 0],
			[0x30, 0x85, 0, 0, 0, 0, der[1], ...der.slice(2)],
			[...der, 0, 0],
		];
		for (const bytes of malformed) {
			const result = EcPublicKey.importPemSync(
				pemEncode("PUBLIC KEY", bytes),
			);
			assert !result.ok;
			assert result.error.kind == CryptoErrorKind.InvalidKey;
			assert result.error.operation == "EcPublicKey.importPem";
		}
	}
}

test "private EC signature DER keeps minimal lengths and root exhaustion" {
	for (const size of [32, 48]) {
		const raw: uint8[] = new Array<uint8>(size * 2);
		raw[size - 1] = 1;
		raw[size * 2 - 1] = 1;
		const der = ecdsaRawToDer(raw);
		assert ecdsaDerToRaw(der, size) != null;
		const longLength: uint8[] = [0x30, 0x81, der[1], ...der.slice(2)];
		assert ecdsaDerToRaw(longLength, size) == null;
		assert ecdsaDerToRaw([...der, 0, 0], size) == null;
	}
}

test "private EC compressed public PEM preserves canonical exports" {
	let refused = 0;
	for (const name of ["p256", "p384"] as EcCurve[]) {
		const file = name == "p256" ? "secp256r1" : "secp384r1";
		const text = readFile(`std/crypto/test/vectors/ecdh_${file}_test.json`);
		assert text.ok;
		const root = parseJson(text.value);
		assert root.ok;
		const tests = root.value.getDynamicField("testGroups").at(0).getDynamicField("tests");
		const plain = tests.at(0);
		const compressed = tests.at(1);
		assert plain.getDynamicField("tcId").asInt32() == 1;
		assert compressed.getDynamicField("tcId").asInt32() == 2;
		assert compressed.getDynamicField("result").asString() == "acceptable";
		const canonical = pemEncode("PUBLIC KEY", plain.getDynamicField("public").asString().decodeHex());
		const control = must(EcPublicKey.importPemSync(canonical));
		assert must(control.exportPemSync()) == canonical;
		const imported = EcPublicKey.importPemSync(pemEncode(
			"PUBLIC KEY", compressed.getDynamicField("public").asString().decodeHex(),
		));
		if (!imported.ok) {
			refused++;
			continue;
		}
		assert imported.value.curve == name;
		assert must(imported.value.exportPemSync()) == canonical;
	}
	assert refused == 0, `compressed public PEM refused ${refused}/2`;
}

test "private EC compressed embedded points preserve scalar agreement" {
	let refused = 0;
	for (const name of ["p256", "p384"] as EcCurve[]) {
		const curve = ownCurve(name == "p256" ? p256 : p384);
		const d: uint8[] = new Array<uint8>(curve.size);
		d[curve.size - 1] = 1;
		const point = ecPublicPoint(curve, d);
		assert point != null;
		const canonical = pemEncode("EC PRIVATE KEY", ecPrivateToSec1({ curve, d, point }));
		const control = must(EcPrivateKey.importPemSync(canonical));
		assert must(control.exportPemSync()) == canonical;
		const compressed: uint8[] = [2 | (point[point.length - 1] & 1), ...point.slice(1, 1 + curve.size)];
		const imported = EcPrivateKey.importPemSync(pemEncode(
			"EC PRIVATE KEY", ecPrivateToSec1({ curve, d, point: compressed }),
		));
		if (!imported.ok) {
			refused++;
		} else {
			assert must(imported.value.exportPemSync()) == canonical;
			assert must(imported.value.publicKey().exportPemSync()) ==
				must(control.publicKey().exportPemSync());
		}
		compressed[0] ^= 1;
		const mismatch = EcPrivateKey.importPemSync(pemEncode(
			"EC PRIVATE KEY", ecPrivateToSec1({ curve, d, point: compressed }),
		));
		assert !mismatch.ok;
		assert mismatch.error.kind == CryptoErrorKind.InvalidKey;
	}
	assert refused == 0, `compressed embedded PEM refused ${refused}/2`;
}

test "private EC compressed public PEM rejects noncanonical X and wrong widths" {
	for (const name of ["p256", "p384"] as EcCurve[]) {
		const curve = ownCurve(name == "p256" ? p256 : p384);
		for (const prefix of [2, 3] as uint8[]) {
			const excessive: uint8[] = new Array<uint8>(1 + curve.size);
			excessive.fill(255);
			excessive[0] = prefix;
			const noncanonical = EcPublicKey.importPemSync(pemEncode(
				"PUBLIC KEY", ecPublicToSpki({ curve, point: excessive }),
			));
			assert !noncanonical.ok;
			assert noncanonical.error.kind == CryptoErrorKind.InvalidKey;
			for (const width of [0, curve.size - 1, curve.size + 1]) {
				const point: uint8[] = new Array<uint8>(1 + width);
				point[0] = prefix;
				assert !EcPublicKey.importPemSync(pemEncode(
					"PUBLIC KEY", ecPublicToSpki({ curve, point }),
				)).ok;
			}
		}
	}
}

test "private EC malformed PEM errors keep their kind and operation" {
	for (const pem of ["", "not a pem",
		"-----BEGIN PUBLIC KEY-----\nAA==\n-----END PUBLIC KEY-----\n"]) {
		const publicKey = EcPublicKey.importPemSync(pem);
		assert !publicKey.ok;
		assert publicKey.error.kind == CryptoErrorKind.InvalidKey;
		assert publicKey.error.operation == "EcPublicKey.importPem";
		const privateKey = EcPrivateKey.importPemSync(pem);
		assert !privateKey.ok;
		assert privateKey.error.kind == CryptoErrorKind.InvalidKey;
		assert privateKey.error.operation == "EcPrivateKey.importPem";
	}
}

test "private EC signing and curve mismatch errors preserve their contract" {
	const key = must(EcPrivateKey.generateSync("p256"));
	for (const hash of ["sha1", "md5", "sha224", "nope", ""]) {
		const signature = ecdsaSignSync(key, "message", hash);
		assert !signature.ok;
		assert signature.error.kind == CryptoErrorKind.SignatureFailed;
		assert signature.error.operation == "ec.ecdsaSign";
		assert signature.error.message ==
			`ECDSA signing failed (hash ${hash}; sha1 is refused)`;
		assert !ecdsaVerifySync(key.publicKey(), "message", [], hash);
	}
	const other = must(EcPrivateKey.generateSync("p384"));
	const shared = ecdhSync(key, other.publicKey());
	assert !shared.ok;
	assert shared.error.kind == CryptoErrorKind.KeyDerivationFailed;
	assert shared.error.operation == "ec.ecdh";
	assert shared.error.message ==
		"ECDH key agreement failed (are the curves the same?)";
}

test "private EC signs UTF8 NUL and binary bytes without changing owners" {
	for (const curve of ["p256", "p384"] as EcCurve[]) {
		const key = must(EcPrivateKey.generateSync(curve));
		const publicKey = key.publicKey();
		const text = "hé\0😀";
		const bytes = "68c3a900f09f9880".decodeHex();
		for (const hash of ["sha256", "sha384", "sha512"]) {
			const signature = must(ecdsaSignSync(key, text, hash));
			assert ecdsaVerifySync(publicKey, bytes, signature, hash);
			assert must(ecdsaSignSync(key, bytes, hash)).encodeHex() ==
				signature.encodeHex();
			assert !ecdsaVerifySync(publicKey, text + "!", signature, hash);
		}
		assert bytes.encodeHex() == "68c3a900f09f9880";
	}
}

test "private EC async generation PEM sign and agreement cover both curves" {
	for (const curve of ["p256", "p384"] as EcCurve[]) {
		const key = must(await EcPrivateKey.generate(curve));
		assert key.curve == curve;
		const pem = must(await key.exportPem());
		const imported = must(await EcPrivateKey.importPem(pem));
		assert must(imported.exportPemSync()) == pem;
		const publicPem = must(await imported.publicKey().exportPem());
		const publicKey = must(await EcPublicKey.importPem(publicPem));
		assert publicKey.curve == curve;
		assert must(publicKey.exportPemSync()) == publicPem;
		const signature = must(await ecdsaSign(imported, "hé\0😀"));
		assert await ecdsaVerify(publicKey, "hé\0😀", signature);
		const peer = must(await EcPrivateKey.generate(curve));
		assert must(await ecdh(imported, peer.publicKey())).encodeHex() ==
			must(ecdhSync(peer, publicKey)).encodeHex();
	}
}

when (c) {
	import {
		EcPrivateKey as NativePrivateKey,
		EcPublicKey as NativePublicKey,
		ecdsaSignSync as nativeSign,
		ecdsaVerifySync as nativeVerify,
		ecdhSync as nativeEcdh,
	} from "std/crypto/oracle/ec";

	test "private EC PEM signatures and agreement interoperate with native API" {
		for (const curve of ["p256", "p384"] as EcCurve[]) {
			const key = must(EcPrivateKey.generateSync(curve));
			const pem = must(key.exportPemSync());
			const nativeKey = must(NativePrivateKey.importPemSync(pem));
			const publicKey = key.publicKey();
			const nativePublic = must(NativePublicKey.importPemSync(
				must(publicKey.exportPemSync()),
			));
			const message = "hé\0😀";
			for (const hash of ["sha256", "sha384", "sha512"]) {
				assert nativeVerify(nativePublic, message,
					must(ecdsaSignSync(key, message, hash)), hash);
				assert ecdsaVerifySync(publicKey, message,
					must(nativeSign(nativeKey, message, hash)), hash);
			}
			const peer = must(EcPrivateKey.generateSync(curve));
			const nativePeer = must(NativePublicKey.importPemSync(
				must(peer.publicKey().exportPemSync()),
			));
			assert must(ecdhSync(key, peer.publicKey())).encodeHex() ==
				must(nativeEcdh(nativeKey, nativePeer)).encodeHex();
		}
	}

	function consumePrivate(sink key: EcPrivateKey): void {}

	test "private EC destruction clears the scalar but not the public point" {
		for (const curve of ["p256", "p384"] as EcCurve[]) {
			const key = must(EcPrivateKey.generateSync(curve));
			const publicKey = key.publicKey();
			const signature = must(ecdsaSignSync(key, "message"));
			const scalar = key._data.d;
			let any: uint32 = 0;
			for (const byte of scalar) any |= byte as uint32;
			assert any != 0;
			consumePrivate(move key);
			for (const byte of scalar) assert byte == 0;
			assert ecdsaVerifySync(publicKey, "message", signature);
		}
	}
}
