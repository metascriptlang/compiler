// Vectors: Wycheproof testvectors_v1 at commit d17cc89 (Apache-2.0, std/crypto/test/vectors/LICENSE-wycheproof).

import { expandKey, expandKeyDecrypt, gcmSealWithNonce, gcmOpen, cbcEncrypt, cbcDecrypt } from "./aes";
import { encodeHex, decodeHex } from "../../core/encoding";
import { readFile } from "../../fs";

const vectorDir = "std/crypto/test/vectors/";

interface GcmCase {
	tcId: int32;
	key: string;
	iv: string;
	aad: string;
	msg: string;
	ct: string;
	tag: string;
	result: string;
}

interface GcmGroup {
	ivSize: int32;
	tests: GcmCase[];
}

interface GcmFile {
	testGroups: GcmGroup[];
}

interface CbcCase {
	tcId: int32;
	key: string;
	iv: string;
	msg: string;
	ct: string;
	result: string;
}

interface CbcGroup {
	tests: CbcCase[];
}

interface CbcFile {
	testGroups: CbcGroup[];
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

function gcmCase(test: GcmCase): boolean {
	const xk = expandKey(test.key.decodeHex());
	const nonce = test.iv.decodeHex();
	const aad = test.aad.decodeHex();
	const sealedHex = test.iv + test.ct + test.tag;
	const opened = gcmOpen(xk, sealedHex.decodeHex(), aad);
	if (test.result != "valid") return opened == null;
	const sealed = gcmSealWithNonce(xk, nonce, test.msg.decodeHex(), aad);
	return sealed.encodeHex() == sealedHex && opened != null && opened.encodeHex() == test.msg;
}

// A nonce of any length but 12 bytes is refused before any work, so such a case counts as skipped once the refusal is seen.
function refusesNonce(test: GcmCase): boolean {
	try {
		gcmSealWithNonce(expandKey(test.key.decodeHex()), test.iv.decodeHex(), test.msg.decodeHex(), test.aad.decodeHex());
	} catch (error) {
		return true;
	}
	return false;
}

function runGcm(): Tally {
	const name = "aes_gcm_test.json";
	const parsed = JSON.parse<GcmFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		for (const test of group.tests) {
			if (group.ivSize != 96) {
				if (refusesNonce(test)) {
					tally.skipped += 1;
				} else {
					record(tally, false, `${name} #${test.tcId}: a ${group.ivSize}-bit nonce was not refused`);
				}
				continue;
			}
			record(tally, gcmCase(test), `${name} #${test.tcId}`);
		}
	}
	report(name, tally);
	console.log(`  skipped: nonces other than 96 bits, which the API refuses`);
	return tally;
}

function cbcCase(test: CbcCase): boolean {
	const key = test.key.decodeHex();
	const iv = test.iv.decodeHex();
	const plain = cbcDecrypt(expandKeyDecrypt(key), iv, test.ct.decodeHex());
	if (test.result != "valid") return plain == null;
	return cbcEncrypt(expandKey(key), iv, test.msg.decodeHex()).encodeHex() == test.ct && plain != null && plain.encodeHex() == test.msg;
}

function runCbc(): Tally {
	const name = "aes_cbc_pkcs5_test.json";
	const parsed = JSON.parse<CbcFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		for (const test of group.tests) record(tally, cbcCase(test), `${name} #${test.tcId}`);
	}
	report(name, tally);
	return tally;
}

test "Wycheproof AES-GCM 128 192 256" {
	const tally = runGcm();
	assert tally.failed == 0;
	assert tally.passed + tally.skipped == 316;
}

test "Wycheproof AES-CBC-PKCS5 128 192 256" {
	const tally = runCbc();
	assert tally.failed == 0;
	assert tally.passed == 216;
}
