import {
	Modulus, fromBytes, reduceBytes, toBytes,
} from "std/crypto/pure/montgomery";
import { p256Math, p384Math } from "std/crypto/pure/pcurve";

function refused(
	md: Readonly<Modulus>, bytes: Readonly<uint8[]>, from: int32,
	reduce: boolean,
): boolean {
	try {
		if (reduce) {
			reduceBytes(md, bytes, from);
		} else {
			fromBytes(md, bytes, from);
		}
	} catch (error) {
		return error.message == "montgomery.load: invalid span";
	}
	return false;
}

function modulusWithWords(words: int32): Modulus {
	const md = p256Math.field;
	return {
		words, m: md.m, mPrime: md.mPrime, r2: md.r2,
		one: md.one, invExp: md.invExp,
	};
}

test "Montgomery canonical decoding refuses out-of-bounds input segments" {
	for (const md of [p256Math.field, p256Math.order,
		p384Math.field, p384Math.order]) {
		const size = 4 * md.words;
		const exact = new Array<uint8>(size);
		assert refused(md, exact, -1, false), "fromBytes accepted negative offset";
		assert refused(md, exact, 1, false), "fromBytes accepted truncated segment";
		assert refused(md, exact, 0x7fffffff, false), "fromBytes accepted huge offset";
		assert refused(md, new Array<uint8>(size - 1), 0, false),
			"fromBytes accepted short input";
		assert refused(md, [], 0, false), "fromBytes accepted empty input";
	}
}

test "Montgomery reduction refuses out-of-bounds input segments" {
	for (const md of [p256Math.field, p256Math.order,
		p384Math.field, p384Math.order]) {
		const size = 4 * md.words;
		const exact = new Array<uint8>(size);
		assert refused(md, exact, -1, true), "reduceBytes accepted negative offset";
		assert refused(md, exact, 1, true), "reduceBytes accepted truncated segment";
		assert refused(md, exact, 0x7fffffff, true), "reduceBytes accepted huge offset";
		assert refused(md, new Array<uint8>(size - 1), 0, true),
			"reduceBytes accepted short input";
		assert refused(md, [], 0, true), "reduceBytes accepted empty input";
	}
}

test "Montgomery readers refuse unsupported limb counts" {
	const counts: int32[] = [0, -1, 7, 9, 13, 0x7fffffff];
	for (const words of counts) {
		const md = modulusWithWords(words);
		assert refused(md, new Array<uint8>(64), 0, false),
			"fromBytes accepted unsupported limb count";
		assert refused(md, new Array<uint8>(64), 0, true),
			"reduceBytes accepted unsupported limb count";
	}
}

test "Montgomery readers preserve valid offset and modulus boundaries" {
	for (const md of [p256Math.field, p256Math.order,
		p384Math.field, p384Math.order]) {
		const size = 4 * md.words;
		const bytes = new Array<uint8>(size + 2);
		bytes[0] = 0xff;
		bytes[size] = 1;
		bytes[size + 1] = 0xff;
		const expected = "00".repeat(size - 1) + "01";
		const parsed = fromBytes(md, bytes, 1);
		assert parsed != null;
		assert toBytes(md, parsed!).encodeHex() == expected;
		assert toBytes(md, reduceBytes(md, bytes, 1)).encodeHex() == expected;
		const modulus = toBytes(md, md.m);
		assert fromBytes(md, modulus, 0) == null;
		assert toBytes(md, reduceBytes(md, modulus, 0)).encodeHex() == "00".repeat(size);
	}
}
