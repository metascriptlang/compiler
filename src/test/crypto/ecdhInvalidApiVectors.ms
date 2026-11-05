import { EcPrivateKey, EcPublicKey, ecdhSync } from "std/crypto/pure/ecNative";
import {
	Curve, ownCurve, ecPrivateToSec1,
} from "std/crypto/pure/weierstrass";
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
	tests: EcdhCase[];
}

interface EcdhFile {
	testGroups: EcdhGroup[];
}

function scalarBytes(hex: string, size: int32): uint8[] {
	const raw = hex.decodeHex();
	let start = 0;
	while (start < raw.length && raw[start] == 0) start++;
	if (raw.length - start > size) {
		throw new Error("ECDH invalid oracle: oversized private fixture");
	}
	const scalar = new Array<uint8>(size);
	for (let i = start; i < raw.length; i++) {
		scalar[size - raw.length + i] = raw[i];
	}
	return scalar;
}

struct RejectionSummary {
	rejected: int32;
	acceptedCase: int32 | null;
}

function rejectedCases(
	name: string,
	curve: Readonly<Curve>,
): RejectionSummary {
	const text = readFile(`std/crypto/test/vectors/${name}`);
	if (!text.ok) throw new Error(`${name}: cannot read corpus`);
	const parsed = JSON.parse<EcdhFile>(text.value);
	if (!parsed.ok) throw new Error(`${name}: cannot parse corpus`);
	if (parsed.value.testGroups.length != 1) {
		throw new Error(`${name}: expected one group`);
	}
	let rejected = 0;
	let controls = 0;
	for (const vector of parsed.value.testGroups[0].tests) {
		const label = `${name} #${vector.tcId}`;
		if (vector.result != "valid" && vector.result != "invalid" &&
			vector.result != "acceptable") {
			throw new Error(`${label}: unexpected result label`);
		}
		if (vector.result != "invalid" && vector.tcId != 1) continue;
		const d = scalarBytes(vector.private, curve.size);
		const privatePem = pemEncode("EC PRIVATE KEY", ecPrivateToSec1({
			curve: ownCurve(curve), d, point: [],
		}));
		const privateKey = EcPrivateKey.importPemSync(privatePem);
		if (!privateKey.ok) {
			throw new Error(`${label}: private fixture import failed`);
		}
		const publicPem = pemEncode("PUBLIC KEY", vector.public.decodeHex());
		const publicKey = EcPublicKey.importPemSync(publicPem);
		if (vector.result == "invalid") {
			if (publicKey.ok) {
				const shared = ecdhSync(privateKey.value, publicKey.value);
				if (shared.ok) {
					return { rejected, acceptedCase: vector.tcId };
				}
			}
			rejected++;
			continue;
		}
		if (vector.result != "valid" || !publicKey.ok) {
			throw new Error(`${label}: positive public control refused`);
		}
		const shared = ecdhSync(privateKey.value, publicKey.value);
		if (!shared.ok) {
			throw new Error(`${label}: positive agreement control refused`);
		}
		if (shared.value.length != curve.size ||
			shared.value.encodeHex() != vector.shared) {
			throw new Error(`${label}: positive shared-secret mismatch`);
		}
		controls++;
	}
	if (controls != 1) throw new Error(`${name}: missing positive control`);
	return { rejected, acceptedCase: null };
}

test "ECDH P-256 class API refuses all 52 invalid vectors" {
	const name = "ecdh_secp256r1_test.json";
	const summary = rejectedCases(name, p256);
	assert summary.acceptedCase == null,
		`${name} #${summary.acceptedCase ?? 0}: invalid ECDH accepted`;
	assert summary.rejected == 52;
}

test "ECDH P-384 class API refuses all 46 invalid vectors" {
	const name = "ecdh_secp384r1_test.json";
	const summary = rejectedCases(name, p384);
	assert summary.acceptedCase == null,
		`${name} #${summary.acceptedCase ?? 0}: invalid ECDH accepted`;
	assert summary.rejected == 46;
}
