import {
	EcPrivateKey, EcPublicKey, EcCurve, ecdsaSignSync, ecdsaVerifySync,
	ecdsaSign, ecdsaVerify, ecdhSync, ecdh,
} from "std/crypto/pure/ecNative";
import { CryptoError } from "std/crypto/errors";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
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
	} from "std/crypto/ec";

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
