import { x25519ScalarMult } from "std/crypto/x25519/pilot";
import {
	checkRawX25519, loadX25519Cases,
} from "../crypto/vectors/x25519Cases";

function bytes(hex: string): uint8[32] {
	let value: uint8[32] = [];
	const digits = "0123456789abcdef";
	for (let i = 0; i < 32; i++) {
		value[i] = (digits.indexOf(hex.slice(i * 2, i * 2 + 1)) * 16 +
			digits.indexOf(hex.slice(i * 2 + 1, i * 2 + 2))) as uint8;
	}
	return value;
}

function matches(actual: uint8[32], expected: uint8[32]): boolean {
	for (let i = 0; i < 32; i++) {
		if (actual[i] != expected[i]) { return false; }
	}
	return true;
}

function multiply(scalar: uint8[32], point: uint8[32]): uint8[32] {
	let result: uint8[32] = [];
	x25519ScalarMult(
		(result as Span<uint8> as Ptr<uint8>),
		(scalar as Span<uint8> as Ptr<uint8>),
		(point as Span<uint8> as Ptr<uint8>),
	);
	return result;
}

test "RFC 7748 section 5.2 first X25519 vector" {
	const scalar = bytes(
		"a546e36bf0527c9d3b16154b82465edd" +
		"62144c0ac1fc5a18506a2244ba449ac4",
	);
	const point = bytes(
		"e6db6867583030db3594c1a424b15f7c" +
		"726624ec26b3353b10a903a6d0ab1c4c",
	);
	assert matches(multiply(scalar, point), bytes(
		"c3da55379de9c6908e94ea4df28d084f" +
		"32eccf03491c71f754b4075577a28552",
	));
}

test "RFC 7748 section 5.2 second X25519 vector" {
	const scalar = bytes(
		"4b66e9d4d1b4673c5ad22691957d6af5" +
		"c11b6421e0ea01d42ca4169e7918ba0d",
	);
	const point = bytes(
		"e5210f12786811d3f4b7959d0538ae2c" +
		"31dbe7106fc03c3efc4cd549c715a493",
	);
	assert matches(multiply(scalar, point), bytes(
		"95cbde9476e8907d7aade45cb4b873f8" +
		"8b595a68799fa152e6f8f7647aac7957",
	));
}

test "RFC 7748 section 6.1 Alice and Bob agree" {
	const alice = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	const bob = bytes(
		"5dab087e624a8a4b79e17f8b83800ee6" +
		"6f3bb1292618b6fd1c2f8b27ff88e0eb",
	);
	let base: uint8[32] = [];
	base[0] = 9;
	const alicePublic = multiply(alice, base);
	const bobPublic = multiply(bob, base);
	assert matches(alicePublic, bytes(
		"8520f0098930a754748b7ddcb43ef75a" +
		"0dbf3a0d26381af4eba4a98eaa9b4e6a",
	));
	assert matches(bobPublic, bytes(
		"de9edb7d7b7dc1b4d35b61c2ece43537" +
		"3f8343c85b78674dadfc7e146f882b4f",
	));
	assert matches(multiply(alice, bobPublic), bytes(
		"4a5d9d5ba4ce2de1728e3bf480350f25" +
		"e07e21c947d19e3376f09b3c1e161742",
	));
	assert matches(multiply(bob, alicePublic), multiply(alice, bobPublic));
}

test "point high bit is ignored and inputs remain unchanged" {
	const scalar = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	let point: uint8[32] = [];
	point[0] = 9;
	const originalScalar = scalar;
	const plain = multiply(scalar, point);
	point[31] = 0x80;
	const masked = multiply(scalar, point);
	assert matches(plain, masked);
	assert matches(scalar, originalScalar);
	assert point[31] == 0x80;
}

test "zero point yields raw zero bytes" {
	const scalar = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	let point: uint8[32] = [];
	assert matches(multiply(scalar, point), point);
}

test "clamping ignores the low and high scalar bits" {
	let scalar = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	let point: uint8[32] = [];
	point[0] = 9;
	const expected = multiply(scalar, point);
	scalar[0] |= 7;
	scalar[31] ^= 0xc0;
	assert matches(multiply(scalar, point), expected);
}

test "output may alias either input" {
	let scalar = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	let point: uint8[32] = [];
	point[0] = 9;
	const expected = multiply(scalar, point);
	x25519ScalarMult(
		(scalar as Span<uint8> as Ptr<uint8>),
		(scalar as Span<uint8> as Ptr<uint8>),
		(point as Span<uint8> as Ptr<uint8>),
	);
	assert matches(scalar, expected);
	let other: uint8[32] = [];
	other[0] = 9;
	const original = bytes(
		"77076d0a7318a57d3c16c17251b26645" +
		"df4c2f87ebc0992ab177fba51db92c2a",
	);
	x25519ScalarMult(
		(other as Span<uint8> as Ptr<uint8>),
		(original as Span<uint8> as Ptr<uint8>),
		(other as Span<uint8> as Ptr<uint8>),
	);
	assert matches(other, expected);
}

test "pilot matches every Wycheproof output without changing inputs" {
	const cases = loadX25519Cases(
		"src/test/crypto/vectors/x25519_test.json",
	);
	assert cases.ok;
	if (cases.ok) {
		const tally = checkRawX25519(cases.value, x25519ScalarMult);
		assert tally.passed == 518 && tally.failed == 0,
			tally.failures.join("\n");
	}
}

test "pilot matches every RFC and adversarial output" {
	const cases = loadX25519Cases(
		"src/test/crypto/vectors/x25519Rfc7748.json",
	);
	assert cases.ok;
	if (cases.ok) {
		const tally = checkRawX25519(cases.value, x25519ScalarMult);
		assert tally.passed == 58 && tally.failed == 0,
			tally.failures.join("\n");
	}
}

test "pilot matches RFC 7748 after one thousand iterations" {
	let scalar: uint8[32] = [];
	scalar[0] = 9;
	let point = scalar;
	for (let i: int32 = 0; i < 1000; i++) {
		const next = multiply(scalar, point);
		point = scalar;
		scalar = next;
	}
	assert matches(scalar, bytes(
		"684cf59ba83309552800ef566f2f4d3c" +
		"1c3887c49360e3875f2eb94d99532c51",
	));
}

test "output and both inputs may share one region" {
	let data: uint8[32] = [];
	data[0] = 9;
	const expected = multiply(data, data);
	const ptr = data as Span<uint8> as Ptr<uint8>;
	x25519ScalarMult(ptr, ptr, ptr);
	assert matches(data, expected);
}
