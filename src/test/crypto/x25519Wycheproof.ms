import { readFile } from "std/fs";
import {
	JsonKind,
	asInt32,
	asString,
	at,
	getDynamicField,
	length,
	parseJson,
} from "std/core/json";
import { decodeHex, encodeHex } from "std/core/encoding";
import { x25519 } from "std/crypto/pure/x25519";

test "raw X25519 matches every pinned Wycheproof shared secret" {
	const text = readFile("std/crypto/test/vectors/x25519_test.json");
	assert text.ok;
	const parsed = parseJson(text.value);
	assert parsed.ok;
	const root = parsed.value;
	const groups = root.getDynamicField("testGroups");
	assert groups.kind == JsonKind.Array;
	let total = 0;
	let valid = 0;
	let acceptable = 0;
	for (let groupIndex = 0; groupIndex < groups.length(); groupIndex++) {
		const tests = groups.at(groupIndex).getDynamicField("tests");
		assert tests.kind == JsonKind.Array;
		for (let caseIndex = 0; caseIndex < tests.length(); caseIndex++) {
			const vector = tests.at(caseIndex);
			const scalar = vector.getDynamicField("private");
			const point = vector.getDynamicField("public");
			const shared = vector.getDynamicField("shared");
			const result = vector.getDynamicField("result");
			assert scalar.kind == JsonKind.String;
			assert point.kind == JsonKind.String;
			assert shared.kind == JsonKind.String;
			assert result.kind == JsonKind.String;
			const scalarBytes = scalar.asString().decodeHex();
			const pointBytes = point.asString().decodeHex();
			assert scalarBytes.length == 32;
			assert pointBytes.length == 32;
			assert shared.asString().length == 64;
			const category = result.asString();
			assert category == "valid" || category == "acceptable";
			const actual = x25519(scalarBytes, pointBytes).encodeHex();
			const id = vector.getDynamicField("tcId").asInt32();
			assert actual == shared.asString(), `X25519 tcId ${id}`;
			if (category == "valid") valid++;
			else acceptable++;
			total++;
		}
	}
	assert total == root.getDynamicField("numberOfTests").asInt32();
	assert valid == 264;
	assert acceptable == 254;
}
