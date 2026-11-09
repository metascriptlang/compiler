import { readFile } from "std/fs";
import { exit } from "std/process";
import { Buffer } from "std/core/buffer";
import { CryptoError, sha256Sync, toHex } from "std/crypto";
import { newUninitOutputBuffer, outputBytes } from "std/crypto/outputBuffer";
import {
	X25519PrivateKey, X25519PublicKey, sharedSecretSync,
} from "std/crypto/x25519";
import {
	X25519Tally,
	checkRawX25519,
	checkSharedSecretX25519,
	countFlag,
	decodeX25519Hex as fromHex,
	describeX25519Tally,
	loadX25519Cases,
	parseX25519Cases,
	requireCleanX25519,
	withWrongExpected,
} from "../crypto/vectors/x25519Cases";

import "../crypto/oracle/x25519";

@include("vendor/monocypher/src/monocypher.h");
extern function crypto_x25519(out: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void;

const WYCHEPROOF_PATH = "src/test/crypto/vectors/x25519_test.json";
const RFC_PATH = "src/test/crypto/vectors/x25519Rfc7748.json";
const BASE_POINT = "0900000000000000000000000000000000000000000000000000000000000000";

function monocypherRaw(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void {
	crypto_x25519(output, scalar, point);
}

function copyScalarKernel(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void {
	for (let i = 0; i < 32; i++) output[i] = scalar[i];
}

function scalarFlippingKernel(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void {
	crypto_x25519(output, scalar, point);
	scalar[0] = scalar[0] ^ 1;
}

function pointMaskingKernel(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void {
	crypto_x25519(output, scalar, point);
	point[31] = point[31] & 127;
}

function rawAsSharedSecret(scalar: Buffer, point: Buffer): Result<Buffer, CryptoError> {
	const output = newUninitOutputBuffer(32);
	crypto_x25519(outputBytes(output), outputBytes(scalar), outputBytes(point));
	return Result.ok(output);
}

function apiSharedSecret(
	scalar: Buffer,
	point: Buffer,
): Result<Buffer, CryptoError> {
	const privateKey = X25519PrivateKey.fromRawSync(scalar);
	if (!privateKey.ok) return Result.err(privateKey.error);
	const publicKey = X25519PublicKey.importSync(point);
	if (!publicKey.ok) return Result.err(publicKey.error);
	return sharedSecretSync(privateKey.value, publicKey.value);
}

function apiPublicKey(scalar: Buffer): Result<Buffer, CryptoError> {
	const key = X25519PrivateKey.fromRawSync(scalar);
	if (!key.ok) return Result.err(key.error);
	const publicKey = key.value.publicKey();
	return publicKey.exportSync();
}

function must<T>(result: Result<T, string>): T {
	if (!result.ok) throw new Error(result.error);
	return result.value;
}

function mustApi<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function raw(scalar: string, point: string): string {
	const output = newUninitOutputBuffer(32);
	const scalarBytes = fromHex(scalar);
	const pointBytes = fromHex(point);
	crypto_x25519(outputBytes(output), outputBytes(scalarBytes), outputBytes(pointBytes));
	return toHex(output);
}

function clamped(scalar: string): string {
	const bytes = fromHex(scalar);
	bytes[0] = (bytes[0] & 248) as uint8;
	bytes[31] = ((bytes[31] & 127) | 64) as uint8;
	return toHex(bytes);
}

function pointPlusPrime(offset: int32, highBit: boolean): string {
	const bytes = fromHex("ff".repeat(32));
	bytes[0] = (237 + offset) as uint8;
	bytes[31] = (highBit ? 255 : 127) as uint8;
	return toHex(bytes);
}

function smallPoint(value: int32, highBit: boolean): string {
	const bytes = fromHex("00".repeat(32));
	bytes[0] = value as uint8;
	bytes[31] = (highBit ? 128 : 0) as uint8;
	return toHex(bytes);
}

function fileSha256(path: string): string {
	const text = readFile(path);
	if (!text.ok) throw new Error(`cannot read ${path}`);
	return toHex(mustApi(sha256Sync(text.value)));
}

const wycheproof = must(loadX25519Cases(WYCHEPROOF_PATH));
const rfcCases = must(loadX25519Cases(RFC_PATH));

test "wycheproof files match the sha256 pinned in the vectors README" {
	assert fileSha256(WYCHEPROOF_PATH) == "35c3f5231cf25cc640b524d403461deee9e49441d5d915a3a25b2c8ff5adbe7d";
	assert fileSha256("src/test/crypto/vectors/LICENSE-wycheproof") ==
		"58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd";
}

test "wycheproof x25519 fixture keeps its pinned shape" {
	assert wycheproof.length == 518;
	assert countFlag(wycheproof, "Normal") == 1;
	assert countFlag(wycheproof, "Ktv") == 3;
	assert countFlag(wycheproof, "LowOrderPublic") == 31;
	assert countFlag(wycheproof, "ZeroSharedSecret") == 31;
	assert countFlag(wycheproof, "NonCanonicalPublic") == 19;
	assert countFlag(wycheproof, "SmallPublicKey") == 8;
	assert countFlag(wycheproof, "Twist") == 221;
	assert countFlag(wycheproof, "EdgeCaseMultiplication") == 394;
	assert countFlag(wycheproof, "EdgeCaseShared") == 14;
	assert countFlag(wycheproof, "EdgeCasePrivateKey") == 7;
	assert countFlag(wycheproof, "SpecialPublicKey") == 79;
}

test "rfc 7748 fixture keeps its generated shape" {
	assert rfcCases.length == 58;
	assert countFlag(rfcCases, "Rfc7748Ktv") == 6;
	assert countFlag(rfcCases, "ScalarClamp") == 15;
	assert countFlag(rfcCases, "PointHighBit") == 9;
	assert countFlag(rfcCases, "NonCanonicalPoint") == 14;
	assert countFlag(rfcCases, "LowOrderPoint") == 14;
	assert countFlag(rfcCases, "ZeroSharedSecret") == 18;
}

test "raw monocypher kernel matches every wycheproof output" {
	const tally = checkRawX25519(wycheproof, monocypherRaw);
	requireCleanX25519("wycheproof raw", tally);
	assert tally.total == 518;
	assert tally.valid == 264;
	assert tally.acceptableNonZero == 223;
	assert tally.acceptableZero == 31;
}

test "raw monocypher kernel matches every rfc 7748 and adversarial output" {
	const tally = checkRawX25519(rfcCases, monocypherRaw);
	requireCleanX25519("rfc raw", tally);
	assert tally.total == 58;
	assert tally.acceptableZero == 18;
}

test "api shared secret returns wycheproof outputs and refuses all-zero ones" {
	const tally = checkSharedSecretX25519(wycheproof, apiSharedSecret);
	requireCleanX25519("wycheproof api", tally);
	assert tally.passed == 518;
	assert tally.acceptableZero == 31;
}

test "api shared secret returns rfc 7748 outputs and refuses all-zero ones" {
	const tally = checkSharedSecretX25519(rfcCases, apiSharedSecret);
	requireCleanX25519("rfc api", tally);
	assert tally.passed == 58;
}

test "api public key is the raw product with the base point" {
	let checked = 0;
	for (const item of [...wycheproof, ...rfcCases]) {
		if (item.point != BASE_POINT) continue;
		assert toHex(mustApi(apiPublicKey(fromHex(item.scalar)))) == item.shared;
		checked++;
	}
	assert checked >= 3;
}

test "rfc 7748 section 6.1 key agreement" {
	const alice = fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
	const bob = fromHex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
	const alicePublic = mustApi(apiPublicKey(alice));
	const bobPublic = mustApi(apiPublicKey(bob));
	assert toHex(alicePublic) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a";
	assert toHex(bobPublic) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f";
	const expected = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
	assert toHex(mustApi(apiSharedSecret(alice, bobPublic))) == expected;
	assert toHex(mustApi(apiSharedSecret(bob, alicePublic))) == expected;
}

test "rfc 7748 section 5.2 iterated raw multiplication" {
	let scalar = BASE_POINT;
	let point = BASE_POINT;
	for (let i = 1; i <= 1000; i++) {
		const next = raw(scalar, point);
		point = scalar;
		scalar = next;
		if (i == 1) assert scalar == "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079";
	}
	assert scalar == "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51";
}

test "raw scalar multiplication ignores the clamped scalar bits" {
	const scalars = [
		"a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
		"4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		"0000000000000000000000000000000000000000000000000000000000000000",
	];
	const point = "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c";
	for (const scalar of scalars) {
		assert raw(scalar, point) == raw(clamped(scalar), point);
		assert raw(scalar, BASE_POINT) == raw(clamped(scalar), BASE_POINT);
	}
}

test "raw scalar multiplication ignores bit 255 of the point" {
	const scalar = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4";
	for (let value = 0; value < 256; value += 17) {
		assert raw(scalar, smallPoint(value, false)) == raw(scalar, smallPoint(value, true));
	}
	assert raw(scalar, pointPlusPrime(0, false)) == raw(scalar, pointPlusPrime(0, true));
}

test "raw scalar multiplication reduces a non-canonical point modulo the prime" {
	const scalar = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4";
	for (let offset = 0; offset <= 18; offset++) {
		const reduced = raw(scalar, smallPoint(offset, false));
		assert raw(scalar, pointPlusPrime(offset, false)) == reduced;
		assert raw(scalar, pointPlusPrime(offset, true)) == reduced;
	}
}

test "raw scalar multiplication of a low-order point is all-zero and the api refuses it" {
	const scalar = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4";
	const lowOrder = [
		smallPoint(0, false),
		smallPoint(1, false),
		"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
		"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
		pointPlusPrime(-1, false),
		pointPlusPrime(0, false),
		pointPlusPrime(1, false),
	];
	for (const point of lowOrder) {
		assert raw(scalar, point) == "00".repeat(32);
		assert !apiSharedSecret(fromHex(scalar), fromHex(point)).ok;
	}
}

test "control: a wrong expected output is reported with its test case id" {
	const tampered = withWrongExpected(wycheproof, 0);
	const tally = checkRawX25519(tampered, monocypherRaw);
	assert tally.failed == 1;
	assert tally.passed == 517;
	assert tally.failures[0].startsWith("tcId 1 ");
	assert checkSharedSecretX25519(tampered, apiSharedSecret).failed == 1;
}

test "control: a wrong expected output is reported at the last case too" {
	const tampered = withWrongExpected(rfcCases, rfcCases.length - 1);
	assert checkRawX25519(tampered, monocypherRaw).failed == 1;
}

test "control: a kernel that skips the multiplication fails the vectors" {
	const tally = checkRawX25519(wycheproof, copyScalarKernel);
	assert tally.failed > 500;
	assert checkRawX25519(rfcCases, copyScalarKernel).failed > 50;
}

test "control: a kernel that modifies its scalar input fails every case" {
	const tally = checkRawX25519(wycheproof, scalarFlippingKernel);
	assert tally.failed == 518;
	assert tally.failures[0].includes("kernel modified the scalar input");
}

test "control: a kernel that masks its point input fails exactly the high-bit points" {
	const tally = checkRawX25519(wycheproof, pointMaskingKernel);
	assert tally.failed == 21;
	assert tally.failures[0].includes("kernel modified the point input");
}

test "control: an api that returns all-zero secrets fails exactly the all-zero cases" {
	const wycheproofTally = checkSharedSecretX25519(wycheproof, rawAsSharedSecret);
	assert wycheproofTally.failed == 31;
	assert wycheproofTally.passed == 487;
	const rfcTally = checkSharedSecretX25519(rfcCases, rawAsSharedSecret);
	assert rfcTally.failed == 18;
}

const HEX = "00".repeat(32);

function oneCase(count: string, extra: string): string {
	return `{"numberOfTests":${count},"testGroups":[{"tests":[{"tcId":1,"comment":"c","flags":["F"],` +
		`"public":"${HEX}","private":"${HEX}","shared":"${HEX}","result":"valid"${extra}}]}]}`;
}

test "loader accepts a well-formed single case file" {
	const parsed = parseX25519Cases(oneCase("1", ""), "inline");
	assert parsed.ok;
	assert parsed.value.length == 1;
}

test "loader refuses a file whose numberOfTests is wrong, missing or not an integer" {
	assert !parseX25519Cases(oneCase("2", ""), "inline").ok;
	assert !parseX25519Cases(oneCase("\"1\"", ""), "inline").ok;
	const missing = oneCase("1", "").replace("\"numberOfTests\":1,", "");
	assert !parseX25519Cases(missing, "inline").ok;
}

test "loader refuses empty, missing and mistyped groups and tests" {
	assert !parseX25519Cases("{\"numberOfTests\":0,\"testGroups\":[]}", "inline").ok;
	assert !parseX25519Cases("{\"numberOfTests\":0}", "inline").ok;
	assert !parseX25519Cases("{\"numberOfTests\":0,\"testGroups\":{}}", "inline").ok;
	assert !parseX25519Cases("{\"numberOfTests\":0,\"testGroups\":[{\"tests\":[]}]}", "inline").ok;
	assert !parseX25519Cases("{\"numberOfTests\":1,\"testGroups\":[{\"tests\":{}}]}", "inline").ok;
	assert !parseX25519Cases("[]", "inline").ok;
	assert !parseX25519Cases("not json", "inline").ok;
}

test "loader refuses a case with a missing field, bad hex or unknown result" {
	assert !parseX25519Cases(oneCase("1", "").replace("\"flags\":[\"F\"],", ""), "inline").ok;
	assert !parseX25519Cases(oneCase("1", "").replace("\"tcId\":1,", ""), "inline").ok;
	assert !parseX25519Cases(oneCase("1", "").replace(HEX + "\",\"private", "zz\",\"private"), "inline").ok;
	assert !parseX25519Cases(oneCase("1", "").replace("\"valid\"", "\"invalid\""), "inline").ok;
}

function report(name: string, tally: X25519Tally): int32 {
	console.log(describeX25519Tally(name, tally));
	for (const failure of tally.failures) console.log(`  FAIL ${failure}`);
	return tally.failed;
}

when (!testBuild) {
	let failed: int32 = 0;
	failed += report("wycheproof raw", checkRawX25519(wycheproof, monocypherRaw));
	failed += report("rfc raw", checkRawX25519(rfcCases, monocypherRaw));
	failed += report("wycheproof api", checkSharedSecretX25519(wycheproof, apiSharedSecret));
	failed += report("rfc api", checkSharedSecretX25519(rfcCases, apiSharedSecret));
	if (failed > 0) {
		console.log(`x25519 assurance: ${failed} mismatches`);
		exit(1);
	}
}
