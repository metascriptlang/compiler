import {
	X25519PrivateKey, X25519PublicKey, sharedSecretSync, sharedSecret,
} from "std/crypto/pure/x25519Native";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex, decodeHex } from "std/core/encoding";

when (c) {
	import {
		X25519PrivateKey as NativePrivateKey,
		X25519PublicKey as NativePublicKey,
		sharedSecretSync as nativeShared,
	} from "./oracle/x25519";
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

const aliceSecret = "77076d0a7318a57d3c16c17251b26645" +
	"df4c2f87ebc0992ab177fba51db92c2a";
const bobSecret = "5dab087e624a8a4b79e17f8b83800ee66" +
	"f3bb1292618b6fd1c2f8b27ff88e0eb";
const alicePublic = "8520f0098930a754748b7ddcb43ef75a0" +
	"dbf3a0d26381af4eba4a98eaa9b4e6a";
const bobPublic = "de9edb7d7b7dc1b4d35b61c2ece43537" +
	"3f8343c85b78674dadfc7e146f882b4f";
const sharedHex = "4a5d9d5ba4ce2de1728e3bf480350f25" +
	"e07e21c947d19e3376f09b3c1e161742";

test "private X25519 key API preserves RFC7748 public and shared bytes" {
	const key = must(X25519PrivateKey.fromRawSync(aliceSecret.decodeHex()));
	assert must(key.publicKey().exportSync()).encodeHex() == alicePublic;
	const peer = must(X25519PublicKey.importSync(bobPublic.decodeHex()));
	assert must(sharedSecretSync(key, peer)).encodeHex() == sharedHex;
}

test "private X25519 key API validates lengths before ladder reads" {
	for (const length of [0, 1, 31, 33, 64] as int32[]) {
		const bytes = new Array<uint8>(length);
		const secret = X25519PrivateKey.fromRawSync(bytes);
		const publicKey = X25519PublicKey.importSync(bytes);
		assert !secret.ok && secret.error.kind == CryptoErrorKind.InvalidKey;
		assert !publicKey.ok && publicKey.error.kind == CryptoErrorKind.InvalidKey;
	}
	const key = must(X25519PrivateKey.fromRawSync(aliceSecret.decodeHex()));
	const lowOrder = must(X25519PublicKey.importSync(new Array<uint8>(32)));
	const result = sharedSecretSync(key, lowOrder);
	assert !result.ok && result.error.kind == CryptoErrorKind.KeyDerivationFailed;
	assert result.error.operation == "x25519.sharedSecret";
}

test "private X25519 key API handles the reverse and masked public key" {
	const key = must(X25519PrivateKey.fromRawSync(bobSecret.decodeHex()));
	assert must(key.publicKey().exportSync()).encodeHex() == bobPublic;
	const peer = must(X25519PublicKey.importSync(alicePublic.decodeHex()));
	assert must(sharedSecretSync(key, peer)).encodeHex() == sharedHex;
	const masked = alicePublic.decodeHex();
	masked[31] = (masked[31] | 128) as uint8;
	const alias = must(X25519PublicKey.importSync(masked));
	assert must(sharedSecretSync(key, alias)).encodeHex() == sharedHex;
}

test "private X25519 key API owns imports and copies public exports" {
	const caller = aliceSecret.decodeHex();
	const key = must(X25519PrivateKey.fromRawSync(caller));
	caller[1] = (caller[1] ^ 255) as uint8;
	assert must(key.publicKey().exportSync()).encodeHex() == alicePublic;
	const peerCaller = bobPublic.decodeHex();
	const peer = must(X25519PublicKey.importSync(peerCaller));
	peerCaller[1] = (peerCaller[1] ^ 255) as uint8;
	const copy = must(peer.exportSync());
	copy[1] = (copy[1] ^ 255) as uint8;
	assert must(peer.exportSync()).encodeHex() == bobPublic;
	assert must(sharedSecretSync(key, peer)).encodeHex() == sharedHex;
	const exported = must(key.publicKey().exportSync());
	exported[1] = (exported[1] ^ 255) as uint8;
	assert must(key.publicKey().exportSync()).encodeHex() == alicePublic;
}

test "private X25519 key API uses UTF8 bytes and refuses low order points" {
	const text = "é".repeat(16);
	const key = must(X25519PrivateKey.fromRawSync(text));
	assert must(key.publicKey().exportSync()).length == 32;
	assert !X25519PrivateKey.fromRawSync("é".repeat(32)).ok;
	assert X25519PublicKey.importSync(text).ok;
	assert !X25519PublicKey.importSync("é".repeat(32)).ok;
	for (const first of [0, 1] as uint8[]) {
		const bytes = new Array<uint8>(32);
		bytes[0] = first;
		const peer = must(X25519PublicKey.importSync(bytes));
		const failed = sharedSecretSync(key, peer);
		assert !failed.ok && failed.error.kind ==
			CryptoErrorKind.KeyDerivationFailed;
		assert failed.error.operation == "x25519.sharedSecret";
	}
}

test "private X25519 key API async and sync methods interoperate" {
	const key = must(await X25519PrivateKey.fromRaw(aliceSecret.decodeHex()));
	assert must(await key.publicKey().export()).encodeHex() == alicePublic;
	const peer = must(await X25519PublicKey.import(bobPublic.decodeHex()));
	assert must(await peer.export()).encodeHex() == bobPublic;
	assert must(await sharedSecret(key, peer)).encodeHex() == sharedHex;
	const badSecret = await X25519PrivateKey.fromRaw(new Array<uint8>(31));
	const badPublic = await X25519PublicKey.import(new Array<uint8>(33));
	assert !badSecret.ok && badSecret.error.kind == CryptoErrorKind.InvalidKey;
	assert !badPublic.ok && badPublic.error.kind == CryptoErrorKind.InvalidKey;
	const zero = must(await X25519PublicKey.import(new Array<uint8>(32)));
	const failed = await sharedSecret(key, zero);
	assert !failed.ok && failed.error.kind ==
		CryptoErrorKind.KeyDerivationFailed;
}

test "private X25519 key API generates usable sync and async keys" {
	const first = must(X25519PrivateKey.generateSync());
	const second = must(await X25519PrivateKey.generate());
	const firstPublic = first.publicKey();
	const secondPublic = second.publicKey();
	assert must(firstPublic.exportSync()).length == 32;
	assert must(await secondPublic.export()).length == 32;
	const forward = must(sharedSecretSync(first, secondPublic));
	const reverse = must(await sharedSecret(second, firstPublic));
	assert forward.length == 32;
	assert forward.encodeHex() == reverse.encodeHex();
}

when (c) {
	test "private X25519 key API matches native cached keys and shared bytes" {
		const peerBytes = bobPublic.decodeHex();
		const peer = must(X25519PublicKey.importSync(peerBytes));
		const nativePeer = must(NativePublicKey.importSync(peerBytes));
		for (const secret of [aliceSecret, bobSecret, "00".repeat(32)]) {
			const raw = secret.decodeHex();
			const key = must(X25519PrivateKey.fromRawSync(raw));
			const native = must(NativePrivateKey.fromRawSync(raw));
			assert must(key.publicKey().exportSync()).encodeHex() ==
				must(native.publicKey().exportSync()).encodeHex();
			assert must(sharedSecretSync(key, peer)).encodeHex() ==
				must(nativeShared(native, nativePeer)).encodeHex();
		}
	}

	function consumePrivate(sink key: X25519PrivateKey): void {}
	function consumePublic(sink key: X25519PublicKey): void {}

	test "private X25519 native destruction clears owned scalar and cache" {
		const caller = aliceSecret.decodeHex();
		const key = must(X25519PrivateKey.fromRawSync(caller));
		const scalar = key._scalar;
		const cachedPublic = key._public;
		const independentPublic = key.publicKey();
		consumePrivate(move key);
		for (const byte of scalar) assert byte == 0;
		for (const byte of cachedPublic) assert byte == 0;
		assert caller.encodeHex() == aliceSecret;
		const bob = must(X25519PrivateKey.fromRawSync(bobSecret.decodeHex()));
		assert must(sharedSecretSync(bob, independentPublic)).encodeHex() ==
			sharedHex;
	}

	test "private X25519 native public destruction clears only its copy" {
		const caller = alicePublic.decodeHex();
		const key = must(X25519PublicKey.importSync(caller));
		const owned = key._raw;
		consumePublic(move key);
		for (const byte of owned) assert byte == 0;
		assert caller.encodeHex() == alicePublic;
	}
}
