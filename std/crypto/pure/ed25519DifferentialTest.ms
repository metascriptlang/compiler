/**
 * Differential test of the pure Ed25519 against std/crypto/ed25519 (Monocypher on the C backend): seeded random
 * seeds and messages, then mutated signatures, foreign keys, small-order and non-canonical points. Run it on C;
 * on JS std/crypto/ed25519 is this same pure code.
 */
import { readFile } from "std/fs";
import { encodeHex, decodeHex } from "../../core/encoding";
import { getDynamicField, asString, at, length, parseJson } from "std/core/json";
import { Ed25519PrivateKey, Ed25519PublicKey, signSync, verifySync } from "std/crypto/ed25519";
import { ed25519PublicFromSeed, ed25519Sign, ed25519Verify } from "./ed25519";

class Rng {
	state: uint32 = 0x9e3779b9;
}

function next(rng: Rng): uint32 {
	let x = rng.state;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	rng.state = x;
	return x;
}

function below(rng: Rng, bound: int32): int32 {
	return (next(rng) % (bound as uint32)) as int32;
}

function randomBytes(rng: Rng, length: int32): uint8[] {
	const out = new Array<uint8>(length);
	for (let i = 0; i < length; i++) out[i] = (next(rng) & 0xff) as uint8;
	return out;
}

class Differences {
	cases: int32 = 0;
	found: string[] = [];
}

function vendorVerify(publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>, message: Readonly<uint8[]>): boolean {
	const key = Ed25519PublicKey.importSync(publicKey.slice(0));
	if (!key.ok) return false;
	return verifySync(key.value, signature.slice(0), message.slice(0));
}

function compareVerify(d: Differences, what: string, publicKey: Readonly<uint8[]>, signature: Readonly<uint8[]>, message: Readonly<uint8[]>): void {
	d.cases++;
	const pure = ed25519Verify(publicKey, signature, message);
	const vendor = vendorVerify(publicKey, signature, message);
	if (pure != vendor) {
		d.found.push(`${what}: pure ${pure} vendor ${vendor} pk ${publicKey.encodeHex()} sig ${signature.encodeHex()} msg ${message.encodeHex()}`);
	}
}

const messageLengths: Readonly<int32[]> = [0, 1, 31, 32, 63, 64, 65, 111, 112, 127, 128, 129, 255, 256, 1023, 1024, 2048];

// The eight torsion points and the non-canonical encodings of y = 0, 1 and -1 (y + P), each with both sign bits.
const oddPoints: Readonly<string[]> = [
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
	"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"0100000000000000000000000000000000000000000000000000000000000080",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
	"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
	"0000000000000000000000000000000000000000000000000000000000000080",
	"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
	"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
];

function addOrder(signature: Readonly<uint8[]>): uint8[] {
	const order = "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010".decodeHex();
	const out = signature.slice(0);
	let carry = 0;
	for (let i = 0; i < 32; i++) {
		const sum = (signature[32 + i] as int32) + (order[i] as int32) + carry;
		out[32 + i] = (sum & 255) as uint8;
		carry = sum >> 8;
	}
	return out;
}

test "pure Ed25519 matches the vendor on sign and on every accept or reject" {
	const rng: Rng = new Rng();
	const d: Differences = new Differences();
	let signatures = 0;
	for (let round = 0; round < 120; round++) {
		const seed = randomBytes(rng, 32);
		const length = round < messageLengths.length ? messageLengths[round] : below(rng, 2049);
		const message = randomBytes(rng, length);
		const publicKey = ed25519PublicFromSeed(seed);
		const signature = ed25519Sign(seed, publicKey, message);
		const vendorKey = Ed25519PrivateKey.fromSeedSync(seed.slice(0));
		assert vendorKey.ok;
		const vendorPublic = vendorKey.value.publicKey().exportSync();
		const vendorSignature = signSync(vendorKey.value, message.slice(0));
		assert vendorPublic.ok && vendorSignature.ok;
		signatures++;
		if (publicKey.encodeHex() != vendorPublic.value.toHex()) d.found.push(`public key of seed ${seed.encodeHex()}`);
		if (signature.encodeHex() != vendorSignature.value.toHex()) d.found.push(`signature of seed ${seed.encodeHex()} length ${length}`);
		compareVerify(d, "valid", publicKey, signature, message);
		const bit = below(rng, 512);
		const flipped = signature.slice(0);
		flipped[bit >> 3] = flipped[bit >> 3] ^ ((1 << (bit & 7)) as uint8);
		compareVerify(d, "flipped signature bit", publicKey, flipped, message);
		if (length > 0) {
			const changed = message.slice(0);
			const at = below(rng, length);
			changed[at] = changed[at] ^ 1;
			compareVerify(d, "changed message", publicKey, signature, changed);
		}
		compareVerify(d, "random key", randomBytes(rng, 32), signature, message);
		compareVerify(d, "S + L", publicKey, addOrder(signature), message);
		const point = oddPoints[round % oddPoints.length].decodeHex();
		compareVerify(d, "odd public key", point, signature, message);
		const oddR = signature.slice(0);
		for (let i = 0; i < 32; i++) oddR[i] = point[i];
		compareVerify(d, "odd R", publicKey, oddR, message);
	}
	console.log(`ed25519 differential: ${signatures} signatures, ${d.cases} verifications, ${d.found.length} differences`);
	for (const found of d.found) console.log(found);
	assert d.found.length == 0;
}

test "pure Ed25519 and the vendor accept the same Wycheproof cases" {
	const text = readFile("std/crypto/test/vectors/ed25519_test.json");
	assert text.ok;
	const parsed = parseJson(text.value);
	assert parsed.ok;
	const groups = parsed.value.getDynamicField("testGroups");
	const d: Differences = new Differences();
	for (let g = 0; g < groups.length(); g++) {
		const group = groups.at(g);
		const publicKey = group.getDynamicField("publicKey").getDynamicField("pk").asString().decodeHex();
		const tests = group.getDynamicField("tests");
		for (let t = 0; t < tests.length(); t++) {
			const item = tests.at(t);
			const what = `wycheproof ${item.getDynamicField("result").asString()}`;
			const signature = item.getDynamicField("sig").asString().decodeHex();
			compareVerify(d, what, publicKey, signature, item.getDynamicField("msg").asString().decodeHex());
		}
	}
	console.log(`ed25519 wycheproof differential: ${d.cases} cases, ${d.found.length} differences`);
	for (const found of d.found) console.log(found);
	assert d.found.length == 0;
}
