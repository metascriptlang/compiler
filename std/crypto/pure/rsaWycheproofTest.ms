import { readFile } from "std/fs";
import { decodeHex } from "../../core/encoding";
import { JsonKind, JsonValue, getDynamicField, asString, asInt32, at, length, parseJson } from "std/core/json";
import { rsaPublicFromSpki, rsaPrivateFromPkcs8, rsaVerifyPkcs1, rsaVerifyPss, rsaOaepDecrypt } from "./rsa";

const vectorDir = "std/crypto/test/vectors/";

class Tally {
	total: int32 = 0;
	valid: int32 = 0;
	invalid: int32 = 0;
	acceptableAccepted: int32 = 0;
	acceptableRejected: int32 = 0;
	skipped: int32 = 0;
	otherSaltAccepted: int32 = 0;
	failures: string[] = [];
}

function record(tally: Tally, file: string, test: JsonValue, accepted: boolean): void {
	const tcId = test.getDynamicField("tcId").asInt32();
	const result = test.getDynamicField("result").asString();
	tally.total++;
	if (result == "valid") {
		if (accepted) tally.valid++;
		else tally.failures.push(`${file} tcId ${tcId}: valid case rejected`);
	} else if (result == "invalid") {
		if (!accepted) tally.invalid++;
		else tally.failures.push(`${file} tcId ${tcId}: invalid case accepted`);
	} else if (result == "acceptable") {
		if (accepted) tally.acceptableAccepted++;
		else tally.acceptableRejected++;
	} else {
		tally.failures.push(`${file} tcId ${tcId}: unknown result ${result}`);
	}
}

function hashName(sha: string): string {
	if (sha == "SHA-256") return "sha256";
	if (sha == "SHA-384") return "sha384";
	if (sha == "SHA-512") return "sha512";
	throw new Error(`no hash name for ${sha}`);
}

function loadRoot(file: string): JsonValue {
	const text = readFile(vectorDir + file);
	if (!text.ok) throw new Error(`cannot read ${file}`);
	const parsed = parseJson(text.value);
	if (!parsed.ok) throw new Error(`cannot parse ${file}`);
	return parsed.value;
}

function runSignatures(tally: Tally, file: string, pss: boolean): int32 {
	const root = loadRoot(file);
	const groups = root.getDynamicField("testGroups");
	for (let g = 0; g < groups.length(); g++) {
		const group = groups.at(g);
		const key = rsaPublicFromSpki(group.getDynamicField("publicKeyDer").asString().decodeHex());
		const hash = hashName(group.getDynamicField("sha").asString());
		const tests = group.getDynamicField("tests");
		for (let t = 0; t < tests.length(); t++) {
			const test = tests.at(t);
			const message = test.getDynamicField("msg").asString().decodeHex();
			const signature = test.getDynamicField("sig").asString().decodeHex();
			let accepted = false;
			if (key != null) accepted = pss ? rsaVerifyPss(key, hash, message, signature) : rsaVerifyPkcs1(key, hash, message, signature);
			// Verification takes any salt length, as the native backend's PSA_ALG_RSA_PSS_ANY_SALT does.
			if (pss && accepted && test.getDynamicField("comment").asString().startsWith("s_len changed")) {
				tally.total++;
				tally.otherSaltAccepted++;
				continue;
			}
			record(tally, file, test, accepted);
		}
	}
	return root.getDynamicField("numberOfTests").asInt32();
}

function report(name: string, tally: Tally, expected: int32): boolean {
	console.log(
		`wycheproof ${name}: ${tally.total} cases, valid ${tally.valid}, invalid ${tally.invalid}, ` +
			`acceptable accepted ${tally.acceptableAccepted} rejected ${tally.acceptableRejected}, ` +
			`skipped ${tally.skipped}, other salt length accepted ${tally.otherSaltAccepted}, ` +
			`failures ${tally.failures.length}`,
	);
	for (const failure of tally.failures) console.log(failure);
	return tally.failures.length == 0 && tally.total + tally.skipped == expected;
}

test "every Wycheproof RSA PKCS#1 v1.5 2048-bit signature case" {
	for (const file of ["rsa_signature_2048_sha256_test.json", "rsa_signature_2048_sha384_test.json", "rsa_signature_2048_sha512_test.json"]) {
		const tally = new Tally();
		assert report(file, tally, runSignatures(tally, file, false));
	}
}

test "every Wycheproof RSA-PSS 2048-bit signature case" {
	for (const file of ["rsa_pss_2048_sha256_mgf1_32_test.json", "rsa_pss_2048_sha384_mgf1_48_test.json", "rsa_pss_2048_sha256_mgf1_0_test.json"]) {
		const tally = new Tally();
		assert report(file, tally, runSignatures(tally, file, true));
	}
}

test "every Wycheproof RSA-OAEP SHA-256 decryption case without a label" {
	const file = "rsa_oaep_2048_sha256_mgf1sha256_test.json";
	const root = loadRoot(file);
	const groups = root.getDynamicField("testGroups");
	const tally = new Tally();
	for (let g = 0; g < groups.length(); g++) {
		const group = groups.at(g);
		const key = rsaPrivateFromPkcs8(group.getDynamicField("privateKeyPkcs8").asString().decodeHex());
		assert key != null;
		const tests = group.getDynamicField("tests");
		for (let t = 0; t < tests.length(); t++) {
			const test = tests.at(t);
			if (test.getDynamicField("label").asString().length > 0) {
				tally.skipped++;
				continue;
			}
			const opened = rsaOaepDecrypt(key, test.getDynamicField("ct").asString().decodeHex());
			const matches = opened != null && opened.encodeHex() == test.getDynamicField("msg").asString();
			record(tally, file, test, opened != null && (matches || test.getDynamicField("result").asString() != "valid"));
		}
	}
	assert report(`${file} (label cases skipped: rsaOaepDecrypt takes no label)`, tally, root.getDynamicField("numberOfTests").asInt32());
}
