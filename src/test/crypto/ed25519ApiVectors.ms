import {
	Ed25519PrivateKey, Ed25519PublicKey, signSync, verifySync, sign, verify,
} from "std/crypto/pure/ed25519Native";
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex, decodeHex } from "std/core/encoding";

when (c) {
	import {
		Ed25519PrivateKey as NativePrivateKey,
		Ed25519PublicKey as NativePublicKey,
		signSync as nativeSign,
		verifySync as nativeVerify,
	} from "std/crypto/ed25519";
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

const seedHex = "9d61b19deffd5a60ba844af492ec2cc44" +
	"449c5697b326919703bac031cae7f60";
const publicHex = "d75a980182b10ab7d54bfed3c964073a0" +
	"ee172f3daa62325af021a68f707511a";
const signatureHex =
	"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f" +
	"b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

test "private Ed25519 key API preserves RFC8032 test1 bytes" {
	const key = must(Ed25519PrivateKey.fromSeedSync(seedHex.decodeHex()));
	assert must(key.exportSeedSync()).encodeHex() == seedHex;
	const publicKey = key.publicKey();
	assert must(publicKey.exportSync()).encodeHex() == publicHex;
	const signature = must(signSync(key, ""));
	assert signature.encodeHex() == signatureHex;
	assert verifySync(publicKey, signature, "");
	assert !verifySync(publicKey, signature, "changed");
}

test "private Ed25519 key API refuses wrong seed and public lengths" {
	for (const length of [0, 1, 31, 33, 64] as int32[]) {
		const bytes = new Array<uint8>(length);
		const secret = Ed25519PrivateKey.fromSeedSync(bytes);
		const publicKey = Ed25519PublicKey.importSync(bytes);
		assert !secret.ok && secret.error.kind == CryptoErrorKind.InvalidKey;
		assert !publicKey.ok && publicKey.error.kind == CryptoErrorKind.InvalidKey;
		assert secret.error.operation == "Ed25519PrivateKey.fromSeed";
		assert publicKey.error.operation == "Ed25519PublicKey.import";
	}
}

test "private Ed25519 key API preserves RFC8032 test2 bytes" {
	const seed = "4ccd089b28ff96da9db6c346ec114e0f" +
		"5b8a319f35aba624da8cf6ed4fb8a6fb";
	const publicBytes = "3d4017c3e843895a92b70aa74d1b7ebc" +
		"9c982ccf2ec4968cc0cd55f12af4660c";
	const expected =
		"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" +
		"085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
	const key = must(Ed25519PrivateKey.fromSeedSync(seed.decodeHex()));
	const publicKey = key.publicKey();
	assert must(publicKey.exportSync()).encodeHex() == publicBytes;
	const message = "72".decodeHex();
	const signature = must(signSync(key, message));
	assert signature.encodeHex() == expected;
	assert verifySync(publicKey, signature, message);
}

test "private Ed25519 key API owns imports and copies exports" {
	const caller = seedHex.decodeHex();
	const key = must(Ed25519PrivateKey.fromSeedSync(caller));
	caller[0] = (caller[0] ^ 255) as uint8;
	assert must(key.exportSeedSync()).encodeHex() == seedHex;
	const seedCopy = must(key.exportSeedSync());
	seedCopy[0] = (seedCopy[0] ^ 255) as uint8;
	assert must(key.exportSeedSync()).encodeHex() == seedHex;
	const publicCaller = publicHex.decodeHex();
	const imported = must(Ed25519PublicKey.importSync(publicCaller));
	publicCaller[0] = (publicCaller[0] ^ 255) as uint8;
	const exported = must(imported.exportSync());
	exported[0] = (exported[0] ^ 255) as uint8;
	assert must(imported.exportSync()).encodeHex() == publicHex;
	const publicKey = key.publicKey();
	const copy = must(publicKey.exportSync());
	copy[0] = (copy[0] ^ 255) as uint8;
	assert must(key.publicKey().exportSync()).encodeHex() == publicHex;
}

test "private Ed25519 key API uses UTF8 and refuses malformed signatures" {
	const key = must(Ed25519PrivateKey.fromSeedSync("é".repeat(16)));
	assert must(key.exportSeedSync()).encodeHex() == "c3a9".repeat(16);
	assert !Ed25519PrivateKey.fromSeedSync("é".repeat(32)).ok;
	assert Ed25519PublicKey.importSync("é".repeat(16)).ok;
	const publicKey = key.publicKey();
	for (const length of [0, 1, 63, 65] as int32[]) {
		assert !verifySync(publicKey, new Array<uint8>(length), "");
	}
	const weak = must(Ed25519PublicKey.importSync(new Array<uint8>(32)));
	assert !verifySync(weak, new Array<uint8>(64), "");
	const plain = [0, 255, 128, 1, 0] as uint8[];
	const before = plain.encodeHex();
	assert verifySync(publicKey, must(signSync(key, plain)), plain);
	assert plain.encodeHex() == before;
}

test "private Ed25519 key API async and sync methods interoperate" {
	const key = must(await Ed25519PrivateKey.fromSeed(seedHex.decodeHex()));
	assert must(await key.exportSeed()).encodeHex() == seedHex;
	const publicKey = must(await Ed25519PublicKey.import(publicHex.decodeHex()));
	assert must(await publicKey.export()).encodeHex() == publicHex;
	const text = "hé\0😀";
	const signature = must(await sign(key, text));
	assert verifySync(publicKey, signature, text);
	assert await verify(publicKey, must(signSync(key, text)), text);
	assert !await verify(publicKey, signature, "hé\0😁");
	assert !await verify(publicKey, new Array<uint8>(63), text);
	const badSeed = await Ed25519PrivateKey.fromSeed(new Array<uint8>(31));
	const badPublic = await Ed25519PublicKey.import(new Array<uint8>(33));
	assert !badSeed.ok && badSeed.error.kind == CryptoErrorKind.InvalidKey;
	assert !badPublic.ok && badPublic.error.kind == CryptoErrorKind.InvalidKey;
}

test "private Ed25519 key API generates usable sync and async keys" {
	const first = must(Ed25519PrivateKey.generateSync());
	const second = must(await Ed25519PrivateKey.generate());
	for (const key of [first, second]) {
		assert must(key.exportSeedSync()).length == 32;
		const publicKey = key.publicKey();
		assert must(await publicKey.export()).length == 32;
		const signature = must(await sign(key, "generated\0key"));
		assert signature.length == 64;
		assert await verify(publicKey, signature, "generated\0key");
	}
}

when (c) {
	test "private Ed25519 key API matches native deterministic signatures" {
		const seed = seedHex.decodeHex();
		const key = must(Ed25519PrivateKey.fromSeedSync(seed));
		const native = must(NativePrivateKey.fromSeedSync(seed));
		const publicKey = must(Ed25519PublicKey.importSync(
			must(native.publicKey().exportSync()),
		));
		const nativePublic = must(NativePublicKey.importSync(
			must(key.publicKey().exportSync()),
		));
		for (const text of ["", "hé\0😀"]) {
			const signature = must(signSync(key, text));
			const expected = must(nativeSign(native, text));
			assert signature.encodeHex() == expected.encodeHex();
			assert nativeVerify(nativePublic, signature, text);
			assert verifySync(publicKey, expected, text);
		}
	}

	function consumePrivate(sink key: Ed25519PrivateKey): void {}
	function consumePublic(sink key: Ed25519PublicKey): void {}

	test "private Ed25519 native destruction clears only owned private state" {
		const caller = seedHex.decodeHex();
		const key = must(Ed25519PrivateKey.fromSeedSync(caller));
		const seed = key._seed;
		const cachedPublic = key._public;
		const publicKey = key.publicKey();
		const signature = must(signSync(key, ""));
		consumePrivate(move key);
		for (const byte of seed) assert byte == 0;
		for (const byte of cachedPublic) assert byte == 0;
		assert caller.encodeHex() == seedHex;
		assert verifySync(publicKey, signature, "");
	}

	test "private Ed25519 native public destruction clears only its copy" {
		const caller = publicHex.decodeHex();
		const key = must(Ed25519PublicKey.importSync(caller));
		const owned = key._raw;
		consumePublic(move key);
		for (const byte of owned) assert byte == 0;
		assert caller.encodeHex() == publicHex;
	}
}
