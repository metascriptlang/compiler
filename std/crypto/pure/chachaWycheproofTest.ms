import { readFile } from "std/fs";
import { keyWords, xchachaSealInto, xchachaOpenInto, chacha20Poly1305SealInto, chacha20Poly1305OpenInto } from "./chacha";

class WycheproofCase {
	tcId: int32;
	key: string;
	iv: string;
	aad: string;
	msg: string;
	ct: string;
	tag: string;
	result: string;
}

class WycheproofGroup {
	ivSize: int32;
	tests: WycheproofCase[];
}

class WycheproofFile {
	numberOfTests: int32;
	testGroups: WycheproofGroup[];
}

class Tally {
	passed: int32;
	failed: int32;
	refused: int32;
	skipped: int32;
}

function loadVectors(name: string): WycheproofFile {
	const text = readFile(`std/crypto/test/vectors/${name}`);
	if (!text.ok) throw new Error(`${name}: ${text.error.message}`);
	const parsed = JSON.parse<WycheproofFile>(text.value);
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	return parsed.value;
}

function joined(parts: uint8[][]): uint8[] {
	const out: uint8[] = [];
	for (const part of parts) for (let i = 0; i < part.length; i++) out.push(part[i]);
	return out;
}

function report(name: string, tally: Tally, total: int32): void {
	console.log(`${name}: ${tally.passed} passed, ${tally.refused} refused by length, ${tally.skipped} skipped, ${tally.failed} failed of ${total}`);
}

/** A valid case must seal to ct || tag and open back to msg; an invalid one must not open. */
function checkIetf(c: WycheproofCase, tally: Tally): void {
	const kw = new Array<uint32>(8);
	if (!keyWords(c.key.decodeHex(), kw)) {
		tally.failed += 1;
		return;
	}
	const nonce = c.iv.decodeHex();
	const aad = c.aad.decodeHex();
	const msg = c.msg.decodeHex();
	const expected = joined([c.ct.decodeHex(), c.tag.decodeHex()]);
	const out = new Array<uint8>(expected.length < 16 ? 0 : expected.length - 16);
	const opened = chacha20Poly1305OpenInto(kw, nonce, aad, expected, out);
	if (nonce.length != 12) {
		if (opened || c.result == "valid") tally.failed += 1;
		else tally.refused += 1;
		return;
	}
	if (c.result == "invalid") {
		if (opened) tally.failed += 1;
		else tally.passed += 1;
		return;
	}
	const sealed = new Array<uint8>(msg.length + 16);
	const ok = opened && out.encodeHex() == c.msg && chacha20Poly1305SealInto(kw, nonce, aad, msg, sealed) && sealed.encodeHex() == expected.encodeHex();
	if (ok) tally.passed += 1;
	else {
		console.log(`chacha20poly1305 tcId ${c.tcId} failed`);
		tally.failed += 1;
	}
}

function checkXchacha(c: WycheproofCase, tally: Tally): void {
	const nonce = c.iv.decodeHex();
	if (nonce.length != 24) {
		tally.skipped += 1;
		return;
	}
	const kw = new Array<uint32>(8);
	if (!keyWords(c.key.decodeHex(), kw)) {
		tally.failed += 1;
		return;
	}
	const aad = c.aad.decodeHex();
	const msg = c.msg.decodeHex();
	const expected = joined([nonce, c.ct.decodeHex(), c.tag.decodeHex()]);
	const out = new Array<uint8>(expected.length < 40 ? 0 : expected.length - 40);
	const opened = xchachaOpenInto(kw, aad, expected, out);
	if (c.result == "invalid") {
		if (opened) tally.failed += 1;
		else tally.passed += 1;
		return;
	}
	const sealed = new Array<uint8>(msg.length + 40);
	for (let i = 0; i < 24; i++) sealed[i] = nonce[i];
	const ok = opened && out.encodeHex() == c.msg && xchachaSealInto(kw, aad, msg, sealed) && sealed.encodeHex() == expected.encodeHex();
	if (ok) tally.passed += 1;
	else {
		console.log(`xchacha20poly1305 tcId ${c.tcId} failed`);
		tally.failed += 1;
	}
}

test "wycheproof chacha20poly1305: every case seals, opens or is refused as the file says" {
	const file = loadVectors("chacha20_poly1305_test.json");
	const tally: Tally = { passed: 0, failed: 0, refused: 0, skipped: 0 };
	for (const group of file.testGroups) for (const c of group.tests) checkIetf(c, tally);
	report("chacha20_poly1305_test.json", tally, file.numberOfTests);
	assert tally.failed == 0;
	assert tally.passed + tally.refused == file.numberOfTests;
}

test "wycheproof xchacha20poly1305: every 24-byte-nonce case seals or opens as the file says" {
	const file = loadVectors("xchacha20_poly1305_test.json");
	const tally: Tally = { passed: 0, failed: 0, refused: 0, skipped: 0 };
	for (const group of file.testGroups) for (const c of group.tests) checkXchacha(c, tally);
	report("xchacha20_poly1305_test.json", tally, file.numberOfTests);
	assert tally.failed == 0;
	assert tally.passed + tally.skipped == file.numberOfTests;
}
