// Vectors: Wycheproof testvectors_v1 at commit d17cc89 (Apache-2.0, std/crypto/test/vectors/LICENSE-wycheproof).

import { EcPublicKey, ecdsaVerifySync } from "./ecNative";
import { Curve, ownCurve, ecPublicFromSpki, ecPointValid, ecdhShared } from "./weierstrass";
import { p256 } from "./p256";
import { p384 } from "./p384";
import { encodeHex } from "../../core/encoding";
import { readFile } from "../../fs";

const vectorDir = "std/crypto/test/vectors/";

interface EcdsaCase {
	tcId: int32;
	msg: string;
	sig: string;
	result: string;
}

interface EcdsaGroup {
	publicKeyPem: string;
	sha: string;
	tests: EcdsaCase[];
}

interface EcdsaFile {
	testGroups: EcdsaGroup[];
}

interface EcdhCase {
	tcId: int32;
	public: string;
	private: string;
	shared: string;
	result: string;
	flags: string[];
}

interface EcdhGroup {
	tests: EcdhCase[];
}

interface EcdhFile {
	testGroups: EcdhGroup[];
}

class Tally {
	passed: int32 = 0;
	failed: int32 = 0;
	acceptableRefused: int32 = 0;
	skipped: Map<string, int32> = new Map<string, int32>();
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

function skip(tally: Tally, reason: string): void {
	tally.skipped.set(reason, (tally.skipped.get(reason) ?? 0) + 1);
}

function skippedCount(tally: Tally): int32 {
	let total = 0;
	for (const [reason, count] of tally.skipped) total += count;
	return total;
}

function report(name: string, tally: Tally): void {
	console.log(`${name}: ${tally.passed} passed, ${tally.failed} failed, ${skippedCount(tally)} skipped, ${tally.acceptableRefused} acceptable refused`);
	for (const [reason, count] of tally.skipped) console.log(`  skipped ${count}: ${reason}`);
	for (const label of tally.failures) console.log(`  failed ${label}`);
}

function hashName(sha: string): string {
	return sha.toLowerCase().replace("-", "");
}

function runEcdsa(name: string): Tally {
	const parsed = JSON.parse<EcdsaFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		const key = EcPublicKey.importPemSync(group.publicKeyPem);
		if (!key.ok) throw new Error(`${name}: a group key was refused`);
		const hash = hashName(group.sha);
		for (const test of group.tests) {
			const verified = ecdsaVerifySync(key.value, test.msg.decodeHex(), test.sig.decodeHex(), hash);
			if (test.result == "acceptable") {
				if (!verified) tally.acceptableRefused += 1;
				tally.passed += 1;
			} else {
				record(tally, verified == (test.result == "valid"), `${name} #${test.tcId}`);
			}
		}
	}
	report(name, tally);
	return tally;
}

/** The private scalar as `size` bytes: Wycheproof writes it as a signed DER integer, with or without leading zeros. */
function scalarBytes(hex: string, size: int32): uint8[] | null {
	const raw = hex.decodeHex();
	let start = 0;
	while (start < raw.length && raw[start] == 0) start++;
	if (raw.length - start > size) return null;
	const out = new Array<uint8>(size);
	for (let i = start; i < raw.length; i++) out[size - raw.length + i] = raw[i];
	return out;
}

function hasFlag(test: EcdhCase, flag: string): boolean {
	for (const f of test.flags) {
		if (f == flag) return true;
	}
	return false;
}

/** The shared secret through the SPKI parser, the point check and the scalar multiplication, or null where any refuses. */
function agree(curve: Readonly<Curve>, test: EcdhCase): uint8[] | null {
	const data = ecPublicFromSpki(test.public.decodeHex(), [ownCurve(p256), ownCurve(p384)]);
	if (data == null || data.curve.name != curve.name || !ecPointValid(data.curve, data.point)) return null;
	const d = scalarBytes(test.private, curve.size);
	if (d == null) return null;
	return ecdhShared(data.curve, d, data.point);
}

function runEcdh(name: string, curve: Readonly<Curve>): Tally {
	const parsed = JSON.parse<EcdhFile>(vectorText(name));
	if (!parsed.ok) throw new Error(`${name}: ${parsed.error}`);
	const tally = new Tally();
	for (const group of parsed.value.testGroups) {
		for (const test of group.tests) {
			const shared = agree(curve, test);
			const label = `${name} #${test.tcId}`;
			if (hasFlag(test, "CompressedPublic") || hasFlag(test, "CompressedPoint")) {
				if (shared == null) {
					skip(tally, "compressed public point, which the SPKI parser refuses");
				} else {
					record(tally, false, `${label}: a compressed point was accepted`);
				}
			} else if (test.result == "invalid") {
				record(tally, shared == null, label);
			} else if (shared == null) {
				if (test.result == "valid") {
					record(tally, false, label);
				} else {
					tally.acceptableRefused += 1;
					tally.passed += 1;
				}
			} else {
				record(tally, encodeHex(shared) == test.shared, label);
			}
		}
	}
	report(name, tally);
	return tally;
}

test "Wycheproof ECDSA P-256 with SHA-256 and SHA-512, DER signatures" {
	const a = runEcdsa("ecdsa_secp256r1_sha256_test.json");
	const b = runEcdsa("ecdsa_secp256r1_sha512_test.json");
	assert a.failed == 0 && b.failed == 0;
	assert a.passed == 484 && b.passed == 554;
}

test "Wycheproof ECDSA P-384 with SHA-384, SHA-256 and SHA-512, DER signatures" {
	const a = runEcdsa("ecdsa_secp384r1_sha384_test.json");
	const b = runEcdsa("ecdsa_secp384r1_sha256_test.json");
	const c = runEcdsa("ecdsa_secp384r1_sha512_test.json");
	assert a.failed == 0 && b.failed == 0 && c.failed == 0;
	assert a.passed == 504 && b.passed == 472 && c.passed == 542;
}

test "Wycheproof ECDH P-256 and P-384 over SPKI public keys" {
	const a = runEcdh("ecdh_secp256r1_test.json", p256);
	const b = runEcdh("ecdh_secp384r1_test.json", p384);
	assert a.failed == 0 && b.failed == 0;
	assert a.passed == 604 && skippedCount(a) == 8;
	assert b.passed == 1045 && skippedCount(b) == 2;
}
