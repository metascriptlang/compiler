import { Buffer } from "std/core/buffer";
import {
	HashAlgorithm,
	digestSync,
	hmacSync,
	createHmac,
	toHex,
} from "std/crypto/pure/coreNative";

import { readFile } from "std/fs";
import { decodeHex } from "std/core/encoding";
import {
	JsonKind, asInt32, asString, at, getDynamicField, length, parseJson,
} from "std/core/json";

struct HashVector {
	algorithm: HashAlgorithm;
	expected: string;
}

const vectors: HashVector[] = [
	{
		algorithm: "ripemd160",
		expected: "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc",
	},
	{
		algorithm: "sha3-224",
		expected: "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf",
	},
	{
		algorithm: "sha3-256",
		expected: "3a985da74fe225b2045c172d6bd390bd855" +
			"f086e3e9d525b46bfe24511431532",
	},
	{
		algorithm: "sha3-384",
		expected: "ec01498288516fc926459f58e2c6ad8df" +
			"9b473cb0fc08c2596da7cf0e49be4b29" +
			"8d88cea927ac7f539f1edf228376d25",
	},
	{
		algorithm: "sha3-512",
		expected: "b751850b1a57168a5693cd924b6b096e" +
			"08f621827444f70d884f5d0240d2712e10" +
			"e116e9192af3c91a7ec57647e39340573" +
			"40b4cf408d5a56592f8274eec53f0",
	},
];

test "private HMAC APIs match every pinned Wycheproof SHA tag" {
	const algorithms: HashAlgorithm[] = [
		"sha1", "sha224", "sha256", "sha384", "sha512",
	];
	let valid = 0;
	let invalid = 0;
	let full = 0;
	let truncated = 0;
	for (const algorithm of algorithms) {
		const text = readFile(
			`std/crypto/test/vectors/hmac_${algorithm}_test.json`,
		);
		assert text.ok;
		const parsed = parseJson(text.value);
		assert parsed.ok;
		const groups = parsed.value.getDynamicField("testGroups");
		assert groups.kind == JsonKind.Array;
		let count = 0;
		for (let g = 0; g < groups.length(); g++) {
			const group = groups.at(g);
			const bits = group.getDynamicField("tagSize").asInt32();
			assert bits > 0 && bits % 8 == 0;
			const tagBytes = bits / 8;
			const tests = group.getDynamicField("tests");
			assert tests.kind == JsonKind.Array;
			for (let t = 0; t < tests.length(); t++) {
				const vector = tests.at(t);
				const key = vector.getDynamicField("key").asString().decodeHex();
				const message = vector.getDynamicField("msg").asString()
					.decodeHex();
				const actual = hmacSync(algorithm, key, message);
				const id = vector.getDynamicField("tcId").asInt32();
				assert actual.ok, `HMAC ${algorithm} tcId ${id}`;
				const stream = createHmac(algorithm, key);
				const split = (message.length as int32) / 2;
				stream.update(message.slice(0, split));
				stream.update(message.slice(split));
				assert toHex(stream.digest()) == toHex(actual.value),
					`HMAC streaming ${algorithm} tcId ${id}`;
				assert tagBytes <= actual.value.length;
				const tag = vector.getDynamicField("tag").asString();
				assert tag.length == tagBytes * 2;
				const category = vector.getDynamicField("result").asString();
				assert category == "valid" || category == "invalid";
				assert (toHex(actual.value.slice(0, tagBytes)) == tag) ==
					(category == "valid"), `HMAC tag ${algorithm} tcId ${id}`;
				if (category == "valid") valid++;
				else invalid++;
				if (tagBytes == actual.value.length) full++;
				else {
					assert tagBytes * 2 == actual.value.length;
					truncated++;
				}
				count++;
			}
		}
		assert count == parsed.value.getDynamicField("numberOfTests").asInt32();
		assert count == (algorithm == "sha1" ? 170 :
			algorithm == "sha224" ? 172 : 174);
	}
	assert valid == 330 && invalid == 534;
	assert full == 435 && truncated == 429;
}

test "private digest API reaches every RIPEMD-160 and SHA-3 kernel" {
	for (const vector of vectors) {
		const digest = digestSync(vector.algorithm, "abc");
		assert digest.ok, vector.algorithm;
		assert toHex(digest.value) == vector.expected, vector.algorithm;
	}
}

test "private digest API uses the exact UTF-8 octets including NUL" {
	const expected: uint8[] = [0x68, 0xc3, 0xa9, 0x00, 0xf0, 0x9f, 0x98, 0x80];
	const fromString = digestSync("sha256", "hé\0😀");
	const fromOctets = digestSync("sha256", expected);
	assert fromString.ok && fromOctets.ok;
	assert toHex(fromString.value) == toHex(fromOctets.value);
}

test "private digest API preserves UTF-8 and embedded NUL byte inputs" {
	const message = "hé\0😀";
	const bytes = Buffer.fromString(message, "utf8");
	for (const vector of vectors) {
		const fromString = digestSync(vector.algorithm, message);
		const fromBytes = digestSync(vector.algorithm, bytes);
		assert fromString.ok && fromBytes.ok, vector.algorithm;
		assert toHex(fromString.value) == toHex(fromBytes.value);
		assert fromString.value.length * 2 == vector.expected.length;
	}
}
