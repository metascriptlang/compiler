import {
	argon2HashSync, argon2HashRawSync, argon2VerifySync,
	argon2Hash, argon2HashRaw, argon2Verify, defaultArgon2Limits,
} from "std/crypto/pure/argon2Native";

when (c) {
	import {
		argon2HashSync as nativeHash,
		argon2HashRawSync as nativeRaw,
		argon2VerifySync as nativeVerify,
	} from "std/crypto/oracle/argon2";
}
import { CryptoError, CryptoErrorKind } from "std/crypto/errors";
import { encodeHex } from "std/core/encoding";
import { Argon2Mode, argon2Encode } from "std/crypto/pure/argon2";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

const phc = "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$" +
	"NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi";

test "private Argon2 API preserves raw and encoded reference bytes" {
	assert must(argon2HashRawSync("password", "somesalt", 2, 64, 2, 24))
		.encodeHex() == "350ac37222f436ccb5c0972f1ebd3bf6b958bf2071841362";
	assert must(argon2HashSync("password", "somesalt", 2, 64, 2, 24)) == phc;
	assert argon2VerifySync(phc, "password");
	assert !argon2VerifySync(phc, "passwore");
}

test "private Argon2 API reports native parameter errors" {
	const salt = argon2HashSync("password", "short", 1, 64, 1, 32);
	assert !salt.ok && salt.error.kind == CryptoErrorKind.InvalidInput;
	assert salt.error.message == "Salt is too short";
	assert salt.error.operation == "argon2Hash";
}

test "private Argon2 API reports each parameter boundary on both entrypoints" {
	const cases: string[] = [];
	const raws = [
		argon2HashRawSync("pw", "somesalt", 1, 64, 1, 3),
		argon2HashRawSync("pw", "somesal", 1, 64, 1, 32),
		argon2HashRawSync("pw", "somesalt", 0, 64, 1, 32),
		argon2HashRawSync("pw", "somesalt", 1, 64, 0, 32),
		argon2HashRawSync("pw", "somesalt", 1, 7, 1, 32),
		argon2HashRawSync("pw", "somesalt", 1, 15, 2, 32),
	];
	for (const r of raws) {
		assert !r.ok && r.error.kind == CryptoErrorKind.InvalidInput;
		assert r.error.operation == "argon2HashRaw";
		cases.push(r.error.message);
	}
	assert cases.join("|") == "Output is too short|Salt is too short|" +
		"Time cost is too small|Too few lanes|Memory cost is too small|" +
		"Memory cost is too small";
	const lanes = argon2HashSync("pw", "somesalt", 1, 64, 16777216, 32);
	assert !lanes.ok && lanes.error.message == "Too many lanes";
	const huge = argon2HashRawSync("pw", "somesalt", 1, 8388608, 1, 32);
	assert !huge.ok && huge.error.kind == CryptoErrorKind.HashFailed;
}

test "private Argon2 API hashes UTF8 and binary bytes identically" {
	const text = "h\u00e9\0";
	const bytes = [104, 195, 169, 0] as uint8[];
	assert must(argon2HashRawSync(text, "somesalt", 1, 8, 1, 16)).encodeHex()
		== must(argon2HashRawSync(bytes, "somesalt", 1, 8, 1, 16)).encodeHex();
	const encoded = must(argon2HashSync(bytes, "somesalt", 1, 8, 1, 16));
	assert argon2VerifySync(encoded, text);
	assert !argon2VerifySync(encoded, "h\u00e9");
}

test "private Argon2 verify accepts only bounded argon2id encodings" {
	assert argon2VerifySync(phc, "password", { memoryCost: 64, timeCost: 2, parallelism: 2 });
	assert !argon2VerifySync(phc, "password", { memoryCost: 63, timeCost: 2, parallelism: 2 });
	assert !argon2VerifySync(phc, "password", { memoryCost: 64, timeCost: 1, parallelism: 2 });
	assert !argon2VerifySync(phc, "password", { memoryCost: 64, timeCost: 2, parallelism: 1 });
	for (const mode of [Argon2Mode.Argon2i, Argon2Mode.Argon2d]) {
		const other = argon2Encode([112, 119], [115, 111, 109, 101, 115, 97, 108, 116],
			1, 8, 1, 16, mode);
		assert other.ok && !argon2VerifySync(other.value, "pw");
	}
	assert !argon2VerifySync(phc.replace("m=64", "m=064"), "password");
	assert !argon2VerifySync(phc.replace("v=19", "v=18"), "password");
	assert !argon2VerifySync("", "password");
	assert !argon2VerifySync(phc + "$", "password");
	assert defaultArgon2Limits.memoryCost == 262144;
	assert defaultArgon2Limits.timeCost == 12 && defaultArgon2Limits.parallelism == 16;
	assert !argon2VerifySync("$argon2id$v=19$m=262152,t=1,p=1$c29tZXNhbHQ$" +
		"NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", "password");
}

test "private Argon2 async methods match sync results" {
	assert must(await argon2HashRaw("password", "somesalt", 2, 64, 2, 24)).encodeHex()
		== "350ac37222f436ccb5c0972f1ebd3bf6b958bf2071841362";
	assert must(await argon2Hash("password", "somesalt", 2, 64, 2, 24)) == phc;
	assert await argon2Verify(phc, "password");
	assert !await argon2Verify(phc, "passwore");
	const bad = await argon2Hash("password", "short", 1, 64, 1, 32);
	assert !bad.ok && bad.error.kind == CryptoErrorKind.InvalidInput;
}

when (c) {
	test "private Argon2 API interoperates with native hashes and raw bytes" {
		for (const p of [1, 2] as int32[]) {
			const mine = must(argon2HashSync("h\u00e9\0", "saltsalt", 1, 16, p, 20));
			const theirs = must(nativeHash("h\u00e9\0", "saltsalt", 1, 16, p, 20));
			assert mine == theirs;
			assert nativeVerify(mine, "h\u00e9\0") && argon2VerifySync(theirs, "h\u00e9\0");
			assert must(argon2HashRawSync("pw", "saltsalt", 2, 16, p, 33)).encodeHex() ==
				must(nativeRaw("pw", "saltsalt", 2, 16, p, 33)).encodeHex();
		}
		const ni = nativeHash("pw", "short", 1, 64, 1, 32);
		const pi = argon2HashSync("pw", "short", 1, 64, 1, 32);
		assert !ni.ok && !pi.ok && ni.error.message == pi.error.message;
	}
}
