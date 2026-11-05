import {
	EcPrivateKey, EcCurve, ecdsaSignSync, ecdsaVerifySync,
} from "std/crypto/pure/ecNative";
import { CryptoError } from "std/crypto/errors";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

when (c) {
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
