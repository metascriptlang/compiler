import { EcPrivateKey, EcPublicKey, ecdhSync } from "std/crypto/pure/ecNative";
import { CryptoErrorKind } from "std/crypto/errors";
import { Curve, ownCurve, ecPrivateToSec1 } from "std/crypto/pure/weierstrass";
import { pemEncode } from "std/crypto/pure/pem";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import { readFile } from "std/fs";

interface EcdhCase {
	tcId: int32;
	public: string;
	private: string;
	shared: string;
	result: string;
}

interface EcdhGroup {
	curve: string;
	tests: EcdhCase[];
}

interface EcdhFile {
	testGroups: EcdhGroup[];
}

function nonTailAgreements(
	name: string,
	curve: Readonly<Curve>,
	rootTailCase: int32,
): Result<int32, string> {
	const text = readFile(`std/crypto/test/vectors/${name}`);
	if (!text.ok) return Result.err(`${name}: cannot read corpus`);
	const parsed = JSON.parse<EcdhFile>(text.value);
	if (!parsed.ok) return Result.err(`${name}: cannot parse corpus`);
	if (parsed.value.testGroups.length != 1 ||
		parsed.value.testGroups[0].curve !=
			(curve.name == "p256" ? "secp256r1" : "secp384r1")) {
		return Result.err(`${name}: unexpected curve group`);
	}
	let selected = 0;
	let deferred = 0;
	let agreed = 0;
	for (const vector of parsed.value.testGroups[0].tests) {
		const label = `${name} #${vector.tcId}`;
		if (vector.result != "valid" && vector.result != "invalid" &&
			vector.result != "acceptable") {
			return Result.err(`${label}: unexpected result label`);
		}
		if (vector.result != "acceptable") continue;
		if (vector.tcId == rootTailCase) {
			deferred++;
			continue;
		}
		selected++;
		const publicPem = pemEncode("PUBLIC KEY", vector.public.decodeHex());
		const publicKey = EcPublicKey.importPemSync(publicPem);
		if (!publicKey.ok) {
			if (publicKey.error.kind != CryptoErrorKind.InvalidKey) {
				return Result.err(`${label}: unexpected import error kind`);
			}
			continue;
		}
		const raw = vector.private.decodeHex();
		let first = 0;
		while (first < raw.length && raw[first] == 0) first++;
		if (raw.length - first > curve.size) {
			return Result.err(`${label}: oversized scalar`);
		}
		const d = new Array<uint8>(curve.size);
		for (let i = first; i < raw.length; i++) {
			d[curve.size - raw.length + i] = raw[i];
		}
		const privatePem = pemEncode("EC PRIVATE KEY", ecPrivateToSec1({
			curve: ownCurve(curve), d, point: [],
		}));
		const privateKey = EcPrivateKey.importPemSync(privatePem);
		if (!privateKey.ok) return Result.err(`${label}: private import`);
		if (privateKey.value.curve != curve.name ||
			publicKey.value.curve != curve.name) {
			return Result.err(`${label}: curve mismatch`);
		}
		const shared = ecdhSync(privateKey.value, publicKey.value);
		if (!shared.ok) return Result.err(`${label}: agreement refused`);
		if (shared.value.length != curve.size ||
			shared.value.encodeHex() != vector.shared) {
			return Result.err(`${label}: shared mismatch`);
		}
		agreed++;
	}
	if (selected != 229 || deferred != 1) {
		return Result.err(`${name}: selected ${selected}, deferred ${deferred}`);
	}
	return Result.ok(agreed);
}

test "ECDH P-256 class API observes 229 non-tail acceptable vectors" {
	const result = nonTailAgreements("ecdh_secp256r1_test.json", p256, 421);
	assert result.ok, result.ok ? "" : result.error;
	assert result.value == 11, "P-256 non-tail accepted cohort changed";
}

test "ECDH P-384 class API observes 229 non-tail acceptable vectors" {
	const result = nonTailAgreements("ecdh_secp384r1_test.json", p384, 856);
	assert result.ok, result.ok ? "" : result.error;
	assert result.value == 11, "P-384 non-tail accepted cohort changed";
}
