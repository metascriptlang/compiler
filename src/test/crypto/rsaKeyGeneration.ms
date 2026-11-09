import {
	RsaPrivateKey, signSync, verifySync, encryptSync, decryptSync,
} from "std/crypto/pure/rsaNative";
import { CryptoError } from "std/crypto/errors";
import { pemDecode } from "std/crypto/pure/pem";
import { rsaPublicFromSpki } from "std/crypto/pure/rsa";
import { bytesBitLength } from "std/crypto/pure/rsaKey";
import { encodeHex } from "std/core/encoding";

when (c) {
	import {
		RsaPrivateKey as NativePrivateKey,
		verifySync as nativeVerify,
	} from "./oracle/rsa";
}

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "private RSA generates working 2048 3072 and 4096-bit keys" {
	for (const bits of [2048, 3072, 4096] as int32[]) {
		const key = bits == 2048
			? must(RsaPrivateKey.generateSync(bits))
			: must(await RsaPrivateKey.generate(bits));
		const publicKey = key.publicKey();
		const block = pemDecode(must(publicKey.exportPemSync()));
		assert block != null;
		if (block == null) throw new Error("generated PEM did not decode");
		const parsed = rsaPublicFromSpki(block.der);
		assert parsed != null;
		if (parsed == null) throw new Error("generated SPKI did not parse");
		assert bytesBitLength(parsed.n) == bits, bits.toString();
		assert parsed.e.encodeHex() == "010001";
		const text = "generated RSA\0hé😀";
		const signature = must(signSync(key, text));
		assert signature.length == bits / 8;
		assert verifySync(publicKey, text, signature);
		assert !verifySync(publicKey, text + "!", signature);
		const pem = must(await key.exportPem());
		const imported = must(await RsaPrivateKey.importPem(pem));
		assert verifySync(imported.publicKey(), text, signature);
		const ciphertext = must(encryptSync(publicKey, text));
		assert ciphertext.length == bits / 8;
		assert must(decryptSync(imported, ciphertext)).encodeHex() ==
			text.asBytes().encodeHex();
		when (c) {
			const native = must(NativePrivateKey.importPemSync(pem));
			assert nativeVerify(native.publicKey(), text, signature);
		}
	}
}
