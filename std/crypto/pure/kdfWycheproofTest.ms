import { hmacOf, pbkdf2Of, hkdfOf } from "./hmac";
import { kindSha1, kindSha224, kindSha256, kindSha384, kindSha512 } from "./state";
import { encodeHex, decodeHex } from "../../core/encoding";
import { readFile } from "../../fs";

const vectorDir = "std/crypto/test/vectors/";
const pbkdf2MaxIterations = 100000;

interface MacCase {
	tcId: int32;
	key: string;
	msg: string;
	tag: string;
	result: string;
}

interface MacGroup {
	tagSize: int32;
	tests: MacCase[];
}

interface MacFile {
	testGroups: MacGroup[];
}

interface HkdfCase {
	tcId: int32;
	ikm: string;
	salt: string;
	info: string;
	size: int32;
	okm: string;
	result: string;
}

interface HkdfGroup {
	tests: HkdfCase[];
}

interface HkdfFile {
	testGroups: HkdfGroup[];
}

interface Pbkdf2Case {
	tcId: int32;
	password: string;
	salt: string;
	iterationCount: int32;
	dkLen: int32;
	dk: string;
	result: string;
}

interface Pbkdf2Group {
	tests: Pbkdf2Case[];
}

interface Pbkdf2File {
	testGroups: Pbkdf2Group[];
}

class Tally {
	passed: int32 = 0;
	failed: int32 = 0;
	skipped: int32 = 0;
	failures: string[] = [];
}

function vectorText(name: string): string {
	const text = readFile(vectorDir + name);
	if (!text.ok) throw new Error(`cannot read ${name}`);
	return text.value;
}

function record(tally: Tally, ok: boolean, label: string): void {
	if (ok) {
		tally.passed += 1;
	} else {
		tally.failed += 1;
		tally.failures.push(label);
	}
}

function report(name: string, tally: Tally): void {
	console.log(`${name}: ${tally.passed} passed, ${tally.failed} failed, ${tally.skipped} skipped`);
	for (const label of tally.failures) console.log(`  failed ${label}`);
}

function runMac(name: string, kind: int32): Tally {
	const parsed = JSON.parse<MacFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		const tagBytes = group.tagSize / 8;
		for (const test of group.tests) {
			const tag = hmacOf(kind, test.key.decodeHex(), test.msg.decodeHex()).slice(0, tagBytes).encodeHex();
			record(tally, (tag == test.tag) == (test.result == "valid"), `${name} #${test.tcId}`);
		}
	}
	report(name, tally);
	return tally;
}

function runHkdf(name: string, kind: int32): Tally {
	const parsed = JSON.parse<HkdfFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		for (const test of group.tests) {
			let okm = "";
			let refused = false;
			try {
				okm = hkdfOf(kind, test.ikm.decodeHex(), test.salt.decodeHex(), test.info.decodeHex(), test.size).encodeHex();
			} catch (e) {
				refused = true;
			}
			const accepted = !refused && okm == test.okm;
			record(tally, accepted == (test.result == "valid"), `${name} #${test.tcId}`);
		}
	}
	report(name, tally);
	return tally;
}

function runPbkdf2(name: string, kind: int32): Tally {
	const parsed = JSON.parse<Pbkdf2File>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		for (const test of group.tests) {
			if (test.iterationCount > pbkdf2MaxIterations) {
				tally.skipped += 1;
				console.log(`  skipped ${name} #${test.tcId}: ${test.iterationCount} iterations`);
				continue;
			}
			const dk = pbkdf2Of(kind, test.password.decodeHex(), test.salt.decodeHex(), test.iterationCount, test.dkLen).encodeHex();
			record(tally, (dk == test.dk) == (test.result == "valid"), `${name} #${test.tcId}`);
		}
	}
	report(name, tally);
	return tally;
}

test "Wycheproof HMAC SHA-1 SHA-224 SHA-256 SHA-384 SHA-512" {
	assert runMac("hmac_sha1_test.json", kindSha1).failed == 0;
	assert runMac("hmac_sha224_test.json", kindSha224).failed == 0;
	assert runMac("hmac_sha256_test.json", kindSha256).failed == 0;
	assert runMac("hmac_sha384_test.json", kindSha384).failed == 0;
	assert runMac("hmac_sha512_test.json", kindSha512).failed == 0;
}

test "Wycheproof HKDF SHA-1 SHA-256 SHA-384 SHA-512" {
	assert runHkdf("hkdf_sha1_test.json", kindSha1).failed == 0;
	assert runHkdf("hkdf_sha256_test.json", kindSha256).failed == 0;
	assert runHkdf("hkdf_sha384_test.json", kindSha384).failed == 0;
	assert runHkdf("hkdf_sha512_test.json", kindSha512).failed == 0;
}

test "Wycheproof PBKDF2 HMAC-SHA-1 SHA-224 SHA-256 SHA-384 SHA-512" {
	assert runPbkdf2("pbkdf2_hmacsha1_test.json", kindSha1).failed == 0;
	assert runPbkdf2("pbkdf2_hmacsha224_test.json", kindSha224).failed == 0;
	assert runPbkdf2("pbkdf2_hmacsha256_test.json", kindSha256).failed == 0;
	assert runPbkdf2("pbkdf2_hmacsha384_test.json", kindSha384).failed == 0;
	assert runPbkdf2("pbkdf2_hmacsha512_test.json", kindSha512).failed == 0;
}
