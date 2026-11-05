import { EcPrivateKey, EcPublicKey, ecdhSync } from "std/crypto/pure/ecNative";
import {
	Curve, ownCurve, ecPrivateToSec1,
} from "std/crypto/pure/weierstrass";
import { pemEncode } from "std/crypto/pure/pem";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import { readFile } from "std/fs";
import { env } from "std/process";

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

function validAgreements(
	name: string,
	curve: Readonly<Curve>,
	start: int32,
	count: int32,
	total: int32,
): Result<int32, string> {
	const text = readFile(`std/crypto/test/vectors/${name}`);
	if (!text.ok) return Result.err(`${name}: cannot read corpus`);
	const parsed = JSON.parse<EcdhFile>(text.value);
	if (!parsed.ok) return Result.err(`${name}: cannot parse corpus`);
	if (parsed.value.testGroups.length != 1) {
		return Result.err(`${name}: expected one group`);
	}
	let ordinal = 0;
	let selected = 0;
	for (const vector of parsed.value.testGroups[0].tests) {
		const label = `${name} #${vector.tcId}`;
		if (vector.result != "valid" && vector.result != "invalid" &&
			vector.result != "acceptable") {
			return Result.err(`${label}: unexpected result label`);
		}
		if (vector.result != "valid") continue;
		const index = ordinal++;
		if (index < start || index >= start + count) continue;
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
		const publicPem = pemEncode("PUBLIC KEY", vector.public.decodeHex());
		const publicKey = EcPublicKey.importPemSync(publicPem);
		if (!publicKey.ok) return Result.err(`${label}: public import`);
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
		selected++;
	}
	if (ordinal != total || selected != count) {
		return Result.err(`${name}: selected ${selected}, valid ${ordinal}`);
	}
	return Result.ok(selected);
}

test "ECDH class API agrees with remaining valid vectors" {
	const only = env.get("MS_ECDH_CURVE");
	const shard = env.get("MS_ECDH_SHARD");
	const shards = ["0", "1", "2", "3", "4", "5"];
	let index: int32 = -1;
	for (let i: int32 = 0; i < shards.length; i++) {
		if (shards[i] == shard) index = i;
	}
	assert (only == "" && shard == "") ||
		((only == "p256" || only == "p384") && index >= 0),
		"invalid ECDH shard selector";
	for (const curve of [ownCurve(p256), ownCurve(p384)]) {
		if (only != "" && curve.name != only) continue;
		const total: int32 = curve.name == "p256" ? 330 : 771;
		const start: int32 = only == "" ? 32 : 32 + index * 128;
		assert start < total, "empty ECDH shard";
		const remaining = total - start;
		const count: int32 = only == "" || remaining < 128 ? remaining : 128;
		const file = curve.name == "p256"
			? "ecdh_secp256r1_test.json" : "ecdh_secp384r1_test.json";
		const result = validAgreements(file, curve, start, count, total);
		assert result.ok, result.ok ? "" : result.error;
		assert result.value == count;
	}
}
