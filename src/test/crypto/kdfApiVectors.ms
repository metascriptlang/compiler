import {
	HashAlgorithm, createHmac,
} from "std/crypto/pure/coreNative";
import {
	pbkdf2Sync, hkdfSync, pbkdf2, hkdf,
} from "std/crypto/pure/kdfNative";
import { CryptoErrorKind } from "std/crypto/errors";
import { hashKind } from "std/crypto/pure/hash";
import { pbkdf2Of, hkdfOf } from "std/crypto/pure/hmac";
import { encodeHex, decodeHex } from "std/core/encoding";
import { readFile } from "std/fs";
import {
	JsonKind, asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";

when (c) {
	import {
		pbkdf2Sync as nativePbkdf2,
		hkdfSync as nativeHkdf,
	} from "std/crypto/oracle";
}

struct KdfVector {
	algorithm: HashAlgorithm;
	pbkdf2: string;
	hkdf: string;
}

const vectors: KdfVector[] = [
	{
		algorithm: "sha256",
		pbkdf2: "6c9e55682453dbd7350762e21b2b5d8bbb6acbd7663b1031c4c4ecc53984e060" +
			"55bf89e6f52cb61ac4f05ec99ac5da97920809070937ddc1e4219df4f615a26111",
		hkdf: "088a080a6ceb42beca972263d5ee0bb15ab9c86bdcf1d25886503b0db2885c416" +
			"d85003cf0b59d74e7431cdd0547475aa158e4b9c4030e48f242d5e149219d956c",
	},
	{
		algorithm: "sha512",
		pbkdf2:
			"ad488d7865b4c649742846bddceb9da4223229f6b70b5e28b71e9c5011b2b41f7" +
			"ce4f6a95997cfed7fa97cd87313286cd568e74e1dc13d7a0fabfbd9869f1b915d",
		hkdf: "e02b2f719f2bae9d8a92516daf058bab7ed8bdb07bc091d64b9cedce1505ce504" +
			"b0918da41a2283a4a192dd4d9b4ffda9d6af305f515ee7c10b89f22472397a611",
	},
	{
		algorithm: "sha384",
		pbkdf2:
			"8c8d4f38056e673ae03ea8501eba1594b91f915133a22d9fa212079d54e378d8cb" +
			"88d2804d2a9958a4fdb4976d172533045de1d79cf1882220b25f9c6c368af397",
		hkdf: "0e7a7a52e90a9b9984732555212a1741b7e4d8a921fbc5cf4abf36b6cd5e84b3f" +
			"6a285d5db45df1bd4329cc566fcbda853df20147cfdfb720157facfa4bea60ed2",
	},
	{
		algorithm: "sha224",
		pbkdf2:
			"9c5f8540abbec3fd74c4431c92540ec0aa18e69f2038f10a542ffd94882bdda27" +
			"342eb0256fcc6a31d0648b06ed88ac9f7cf79381e00088ab2f0fb40f99326bbae",
		hkdf: "0231fdc2a9091757bc3b8f3325b2b31fd001a4c7ad0958824243f576b4f5c4d9" +
			"8868a7179a5398ac25749da0546523a2d4b523c6a14586228a35c2922cc82535d0",
	},
	{
		algorithm: "sha1",
		pbkdf2: "91814acfbc595c3a53b87da3e389c522f9df1e03312df909e172336c5506e78e" +
			"fe126992b156d6fdfb25afbfc31b4fadcbc04abc84273c404b10a3cb293c01cb8b",
		hkdf: "75fd41e948f8e8530d963bb3a4ccf2587740b0e24ef8968459a78be7f9bb62d22" +
			"f1bceb1b633accdeb4abdb37c4bd1426adaa791d43f147fb3720028bf04fea7f9",
	},
	{
		algorithm: "md5",
		pbkdf2:
			"c90bf4bbdbf89e8038dfd3f9fc3962c1f2a55276f11eb7ce6624fa675d4ae39d" +
			"e3d7a7c99e1e23401213bd233afb48bbc4a97513c0210933c6cc651b380b34fc1f",
		hkdf: "976532df79153ee3a8df14a14728060c1ae4e23726e3a962d95146b925a182ffe" +
			"a4a7aecf4ac2eee75ac364c62beb6e35d5f64410704a2c17d237df9810e89a27e",
	},
	{
		algorithm: "ripemd160",
		pbkdf2:
			"f84c74e353a5e3bb399b7a087736abaaa2d6bc422af77b9e255bdcb0d5feb2773" +
			"aff6f815bc11aa1a852ca4ad3bcf7947866d1865acf1060331fbd7d180e3e192b",
		hkdf: "0bb711f7cbef95dfaa955ba51e4f9ae13035378b57a3a379851644ceccb3fec92" +
			"691d87e3fea96d2f47b4e1c32541d2831cdc851b1a1810c592f84144c721b0cab",
	},
	{
		algorithm: "sha3-224",
		pbkdf2: "d7e897acc729e8e40918a5f7fa47fc8f1b81f294abd138817bcdf5f2e87445a4" +
			"fa8b04ffa0575e6f1c6fead37718daab73c79c7e2b64d49fabf1e6a4c25a391331",
		hkdf: "82e981302785f8b9120e9f5163fa3c9f39af84b913846efcbdb946e299243588" +
			"dea8a0974cf1567cf4beb582ff146ee7f7287e54c867195778a614b6bad245aa81",
	},
	{
		algorithm: "sha3-256",
		pbkdf2: "4cc633db65fe456d51c53707c4f91f295e1d9658090786876d8e9332e757cfe0" +
			"8aafc1fd6625aa39c95cd96ff3d0edd56c9cccecfcbc59cf3bcc953f261e0ce88c",
		hkdf: "13a9e64aa164c9e24d1d1100b2dd5a7e55732ba879a35917760ac204a500af8d" +
			"cbf12aef3c42fed55e7c25088fb27252a43507709f36f2b93d4f7b5ba1d73f0428",
	},
	{
		algorithm: "sha3-384",
		pbkdf2: "8d13719a7c89a1c2a18506905f935c2530b90a146d607e4e27b071179ce3f17f" +
			"2eecd747b8720e0af2edc479bd6fce61abb142637ce58a7e4b37c5dadb7c655af8",
		hkdf: "7c252596d8f8b1679252e6c2dcd92a67f76afe30ded43a73f5b0bc66de000cec" +
			"1131abec95266c250ce6a2f1a50e329d8ea5b7b04a244ae9c273f2dfeaae23f849",
	},
	{
		algorithm: "sha3-512",
		pbkdf2: "8e1b9cc1a89c9b2e6cebed4efbb126de6413a60d62ec2991c52ee3b8d2e7c613" +
			"e9f4a076fb25a818538253c672a27836ce8fb2c957818d5296cfb7ca021bd2a235",
		hkdf: "875309256fb83454b951bf4f2120adb2ba60e60b9bf9e1c4c4f2a512fcafc7e90" +
			"f351661b082ec0e60027f7876f3a64c7d806b6072b2df589c9a35b68a96661d7e",
	},
];

function pattern(length: int32, factor: int32, offset: int32): uint8[] {
	const out = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) {
		out[i] = ((i * factor + offset) & 255) as uint8;
	}
	return out;
}

const password = pattern(195, 37, 11);
const salt = pattern(147, 17, 3);
const info: uint8[] = [0x68, 0xc3, 0xa9, 0x00, 0xf0, 0x9f, 0x98, 0x80];

function derivedPassword(algorithm: HashAlgorithm): uint8[] {
	when (kdfApi == "legacy") {
		return pbkdf2Of(hashKind(algorithm), password, salt, 2, 65);
	} else {
		const result = pbkdf2Sync(password, salt, 2, 65, algorithm);
		if (!result.ok) throw new Error(result.error.message);
		return result.value;
	}
}

function derivedKey(algorithm: HashAlgorithm): uint8[] {
	when (kdfApi == "legacy") {
		return hkdfOf(hashKind(algorithm), password, salt, info, 65);
	} else {
		const result = hkdfSync(algorithm, password, salt, info, 65);
		if (!result.ok) throw new Error(result.error.message);
		return result.value;
	}
}

when (c) {
	test "native PBKDF2 and HKDF accept all eleven digest families" {
		for (const vector of vectors) {
			const pb = nativePbkdf2(password, salt, 2, 65, vector.algorithm);
			const hk = nativeHkdf(vector.algorithm, password, salt, info, 65);
			assert pb.ok && hk.ok, vector.algorithm;
			assert pb.value.encodeHex() == vector.pbkdf2, vector.algorithm;
			assert hk.value.encodeHex() == vector.hkdf, vector.algorithm;
		}
	}
}

test "private HKDF API matches every pinned Wycheproof SHA case" {
	const algorithms: HashAlgorithm[] = ["sha1", "sha256", "sha384", "sha512"];
	let valid = 0;
	let invalid = 0;
	for (const algorithm of algorithms) {
		const text = readFile(
			`std/crypto/test/vectors/hkdf_${algorithm}_test.json`,
		);
		assert text.ok;
		const parsed = parseJson(text.value);
		assert parsed.ok;
		const groups = parsed.value.getDynamicField("testGroups");
		assert groups.kind == JsonKind.Array;
		let count = 0;
		for (let g = 0; g < groups.length(); g++) {
			const tests = groups.at(g).getDynamicField("tests");
			assert tests.kind == JsonKind.Array;
			for (let t = 0; t < tests.length(); t++) {
				const vector = tests.at(t);
				const result = hkdfSync(algorithm,
					vector.getDynamicField("ikm").asString().decodeHex(),
					vector.getDynamicField("salt").asString().decodeHex(),
					vector.getDynamicField("info").asString().decodeHex(),
					vector.getDynamicField("size").asInt32());
				const category = vector.getDynamicField("result").asString();
				const id = vector.getDynamicField("tcId").asInt32();
				assert category == "valid" || category == "invalid";
				if (category == "valid") {
					assert result.ok, `HKDF ${algorithm} tcId ${id}`;
					assert result.value.encodeHex() ==
						vector.getDynamicField("okm").asString(),
						`HKDF output ${algorithm} tcId ${id}`;
					valid++;
				} else {
					assert !result.ok, `HKDF accepted ${algorithm} tcId ${id}`;
					assert result.error.kind == CryptoErrorKind.InvalidInput;
					assert result.error.operation == "hkdf";
					invalid++;
				}
				count++;
			}
		}
		assert count == parsed.value.getDynamicField("numberOfTests").asInt32();
		assert count == (algorithm == "sha1" ? 87 :
			algorithm == "sha256" ? 86 : 83);
	}
	assert valid == 327 && invalid == 12;
}

test "private PBKDF2 API matches 297 bounded Wycheproof cases" {
	const algorithms: HashAlgorithm[] = [
		"sha1", "sha224", "sha256", "sha384", "sha512",
	];
	let checked = 0;
	let deferred = 0;
	for (const algorithm of algorithms) {
		const text = readFile(
			`std/crypto/test/vectors/pbkdf2_hmac${algorithm}_test.json`,
		);
		assert text.ok;
		const parsed = parseJson(text.value);
		assert parsed.ok;
		const groups = parsed.value.getDynamicField("testGroups");
		assert groups.kind == JsonKind.Array;
		let count = 0;
		for (let g = 0; g < groups.length(); g++) {
			const tests = groups.at(g).getDynamicField("tests");
			assert tests.kind == JsonKind.Array;
			for (let t = 0; t < tests.length(); t++) {
				const vector = tests.at(t);
				assert vector.getDynamicField("result").asString() == "valid";
				const iterations = vector.getDynamicField("iterationCount")
					.asInt32();
				const id = vector.getDynamicField("tcId").asInt32();
				count++;
				if (iterations > 100000) {
					assert algorithm == "sha1" && id == 4;
					assert iterations == 16777216;
					deferred++;
					continue;
				}
				const result = pbkdf2Sync(
					vector.getDynamicField("password").asString().decodeHex(),
					vector.getDynamicField("salt").asString().decodeHex(),
					iterations, vector.getDynamicField("dkLen").asInt32(),
					algorithm,
				);
				assert result.ok, `PBKDF2 ${algorithm} tcId ${id}`;
				assert result.value.encodeHex() ==
					vector.getDynamicField("dk").asString(),
					`PBKDF2 output ${algorithm} tcId ${id}`;
				checked++;
			}
		}
		assert count == parsed.value.getDynamicField("numberOfTests").asInt32();
		assert count == (algorithm == "sha1" ? 64 :
			algorithm == "sha256" ? 60 : 58);
	}
	assert checked == 297 && deferred == 1;
}

test "private SHA-256 KDF remains the passing neighbour" {
	assert derivedPassword("sha256").encodeHex() == vectors[0].pbkdf2;
	assert derivedKey("sha256").encodeHex() == vectors[0].hkdf;
}

test "private PBKDF2 reaches every native digest family" {
	for (const vector of vectors) {
		assert derivedPassword(vector.algorithm).encodeHex() ==
			vector.pbkdf2, vector.algorithm;
	}
}

test "private HKDF reaches every family starting with SHA3-512" {
	for (let i: int32 = 10; i >= 0; i--) {
		const vector = vectors[i];
		assert derivedKey(vector.algorithm).encodeHex() ==
			vector.hkdf, vector.algorithm;
	}
}

test "KDF async and sync preserve UTF-8 NUL bytes and empty parameters" {
	const text = "hé\0😀";
	for (const vector of vectors) {
		const algorithm = vector.algorithm;
		for (const iterations of [1, 2] as int32[]) {
			const sync = pbkdf2Sync(text, "", iterations, 65, algorithm);
			const done = await pbkdf2(text, "", iterations, 65, algorithm);
			const octets = pbkdf2Sync(info, new Uint8Array(0), iterations, 65, algorithm);
			assert sync.ok && done.ok && octets.ok, algorithm;
			assert sync.value.encodeHex() == done.value.encodeHex();
			assert sync.value.encodeHex() == octets.value.encodeHex();
			when (c) {
				const native = nativePbkdf2(text, "", iterations, 65, algorithm);
				assert native.ok, algorithm;
				assert sync.value.encodeHex() == native.value.encodeHex();
			}
		}
		const sync = hkdfSync(algorithm, text, "", "", 65);
		const done = await hkdf(algorithm, text, "", "", 65);
		const octets = hkdfSync(algorithm, info, new Uint8Array(0), new Uint8Array(0), 65);
		assert sync.ok && done.ok && octets.ok, algorithm;
		assert sync.value.encodeHex() == done.value.encodeHex();
		assert sync.value.encodeHex() == octets.value.encodeHex();
		when (c) {
			const native = nativeHkdf(algorithm, text, "", "", 65);
			assert native.ok, algorithm;
			assert sync.value.encodeHex() == native.value.encodeHex();
		}
	}
	assert password.encodeHex() == pattern(195, 37, 11).encodeHex();
	assert salt.encodeHex() == pattern(147, 17, 3).encodeHex();
	assert info.encodeHex() == "68c3a900f09f9880";
}

test "KDF refuses native parameter bounds" {
	for (const vector of vectors) {
		const algorithm = vector.algorithm;
		for (const iterations of [0, -1] as int32[]) {
			const result = pbkdf2Sync("", "", iterations, 32, algorithm);
			assert !result.ok && result.error.kind ==
				CryptoErrorKind.InvalidInput;
			when (c) {
				const native = nativePbkdf2("", "", iterations, 32, algorithm);
				assert !native.ok;
				assert result.error.message == native.error.message;
				assert result.error.operation == native.error.operation;
			}
		}
		for (const length of [0, -1, 1048577] as int32[]) {
			const result = pbkdf2Sync("", "", 1, length, algorithm);
			assert !result.ok && result.error.kind ==
				CryptoErrorKind.InvalidInput;
			when (c) {
				const native = nativePbkdf2("", "", 1, length, algorithm);
				assert !native.ok;
				assert result.error.message == native.error.message;
				assert result.error.operation == native.error.operation;
			}
		}
		const size = createHmac(algorithm, "").digest().length as int32;
		for (const length of [0, -1, 255 * size + 1] as int32[]) {
			const result = hkdfSync(algorithm, "", "", "", length);
			assert !result.ok && result.error.kind ==
				CryptoErrorKind.InvalidInput;
			when (c) {
				const native = nativeHkdf(algorithm, "", "", "", length);
				assert !native.ok;
				assert result.error.message == native.error.message;
				assert result.error.operation == native.error.operation;
			}
		}
	}
}

test "PBKDF2 accepts the native one-MiB limit and carries block indices" {
	const result = pbkdf2Sync("", "", 1, 1048576, "sha3-512");
	assert result.ok && result.value.length == 1048576;
	const expected =
		"d69305732aef7258d2b3c6e9149bb3f242f41860f95ef4b05375b180a42f9f30f" +
		"f2bcf3aa3c3a1bbe0faf591b7bab323051cdd05da89414e7f6e71ae2e576309";
	assert result.value.slice(1048512).encodeHex() == expected;
	when (c) {
		const native = nativePbkdf2("", "", 1, 1048576, "sha3-512");
		assert native.ok;
		assert result.value.encodeHex() == native.value.encodeHex();
	}
}

test "HKDF emits block 255 at the narrow and wide SHA-3 limits" {
	const algorithms: HashAlgorithm[] = ["sha3-224", "sha3-512"];
	for (const algorithm of algorithms) {
		const size = createHmac(algorithm, "").digest().length as int32;
		const result = hkdfSync(algorithm, "", "", "", 255 * size);
		assert result.ok && result.value.length == 255 * size;
		const expected = algorithm == "sha3-224"
			? "d9d2dc40ab4cc7e332f2119e4d57bdf18057a32e6e8120c8bf4e7d8d"
			: "e31efa632f9a4f3ac2ac501c1e02e0fee9fb5b8ae4bdeed0f529fc6fe5671712" +
				"932948b49e11f456a7eb6b11ff2836c08ad59d5bd6c9b9ca00bed6831a0254d3";
		assert result.value.slice(254 * size).encodeHex() == expected;
		when (c) {
			const native = nativeHkdf(algorithm, "", "", "", 255 * size);
			assert native.ok;
			assert result.value.encodeHex() == native.value.encodeHex();
		}
	}
}
