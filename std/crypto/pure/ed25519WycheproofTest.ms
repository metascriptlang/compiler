import { readFile } from "std/fs";
import { decodeHex } from "../../core/encoding";
import {
	JsonKind,
	JsonValue,
	getDynamicField,
	asString,
	asInt32,
	at,
	length,
	parseJson,
} from "std/core/json";
import { ed25519Verify } from "./ed25519";

const vectorPath = "std/crypto/test/vectors/ed25519_test.json";

class Tally {
	total: int32 = 0;
	valid: int32 = 0;
	invalid: int32 = 0;
	acceptableAccepted: int32 = 0;
	acceptableRejected: int32 = 0;
	failures: string[] = [];
}

function runCase(
	tally: Tally,
	publicKey: Readonly<uint8[]>,
	test: JsonValue,
): void {
	const tcId = test.getDynamicField("tcId").asInt32();
	const result = test.getDynamicField("result").asString();
	const message = test.getDynamicField("msg").asString().decodeHex();
	const signature = test.getDynamicField("sig").asString().decodeHex();
	const accepted = ed25519Verify(publicKey, signature, message);
	tally.total++;
	if (result == "valid") {
		if (accepted) tally.valid++;
		else tally.failures.push(`tcId ${tcId}: valid signature rejected`);
	} else if (result == "invalid") {
		if (!accepted) tally.invalid++;
		else tally.failures.push(`tcId ${tcId}: invalid signature accepted`);
	} else if (result == "acceptable") {
		if (accepted) tally.acceptableAccepted++;
		else tally.acceptableRejected++;
	} else {
		tally.failures.push(`tcId ${tcId}: unknown result ${result}`);
	}
}

test "every Wycheproof ed25519 case: valid verifies, invalid is refused" {
	const text = readFile(vectorPath);
	assert text.ok;
	const parsed = parseJson(text.value);
	assert parsed.ok;
	const root = parsed.value;
	const groups = root.getDynamicField("testGroups");
	assert groups.kind == JsonKind.Array;
	const tally: Tally = new Tally();
	for (let g = 0; g < groups.length(); g++) {
		const group = groups.at(g);
		const publicKey = group
			.getDynamicField("publicKey")
			.getDynamicField("pk")
			.asString()
			.decodeHex();
		const tests = group.getDynamicField("tests");
		for (let t = 0; t < tests.length(); t++) {
			runCase(tally, publicKey, tests.at(t));
		}
	}
	console.log(
		`wycheproof ed25519: ${tally.total} cases, valid ${tally.valid}, ` +
			`invalid ${tally.invalid}, ` +
			`acceptable accepted ${tally.acceptableAccepted} ` +
			`rejected ${tally.acceptableRejected}, ` +
			`failures ${tally.failures.length}`,
	);
	for (const failure of tally.failures) console.log(failure);
	assert tally.failures.length == 0;
	assert tally.total == root.getDynamicField("numberOfTests").asInt32();
}
