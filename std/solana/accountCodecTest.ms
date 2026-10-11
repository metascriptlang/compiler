import { Discriminator, Pubkey, decode, encode } from "std/solana";
import { CodecHiddenAccount, discriminator, hiddenAccount, hiddenAccountValid } from "./accountCodecFixture";
import { accountFloat32Bits, accountFloat32FromBits, accountFloat64Bits, accountFloat64FromBits } from "./accountCodecKernel";

enum CodecSparse { Zero = 0, Two = 2, Nine = 9 }
enum CodecWide { Zero = 0, Large = 300 }
enum CodecSigned { Below = -7, Zero = 0, Above = 70000 }
enum CodecBit { Read, Write, Admin }
type CodecAmount = distinct uint64;
struct CodecFlags { alive: boolean; kind: CodecSparse; }
struct CodecGolden {
	prefix: uint8;
	flags: CodecFlags;
	amount: uint64;
	wide: CodecWide;
	signed: CodecSigned;
	ratio: float32;
	measure: float64;
	serial: CodecAmount;
	bits: BitSet<CodecBit>;
	last: boolean;
}

export function discriminator(this typeof CodecGolden): Discriminator {
	return { bytes: [1, 2, 3, 4, 5, 6, 7, 8] };
}

function golden(): CodecGolden {
	return {
		prefix: 0xaa, flags: { alive: false, kind: CodecSparse.Nine },
		amount: 0xffffffffffffffff, wide: CodecWide.Large, signed: CodecSigned.Below,
		ratio: 1.5, measure: -2.25, serial: (0x8000000000000000 as uint64) as CodecAmount,
		bits: (5 as uint8) as BitSet<CodecBit>, last: true,
	};
}

function goldenBytes(): uint8[64] {
	return [
		1, 2, 3, 4, 5, 6, 7, 8,
		0xaa, 0, 9, 0, 0, 0, 0, 0,
		255, 255, 255, 255, 255, 255, 255, 255,
		0x2c, 1, 0, 0, 0xf9, 255, 255, 255,
		0, 0, 0xc0, 0x3f, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 2, 0xc0,
		0, 0, 0, 0, 0, 0, 0, 0x80,
		5, 1, 0, 0, 0, 0, 0, 0,
	];
}

function decodeCode<T>(bytes: Readonly<Span<uint8>>): uint64 {
	const result = decode<T>(bytes);
	return result.ok ? 0 : result.error.code;
}

function opaque(value: int32): int32 { return value; }

test "account codec encoding matches golden repr(C) offsets and canonical zero padding" {
	const encoded = encode(golden());
	assert encoded.ok;
	if (encoded.ok) {
		const expected = goldenBytes();
		assert encoded.value.length == expected.length;
		for (let i = 0; i < expected.length; i += 1) { assert encoded.value[i] == expected[i]; }
	}
	const decoded = decode<CodecGolden>(goldenBytes());
	assert decoded.ok;
	if (decoded.ok) {
		assert decoded.value.prefix == 0xaa && !decoded.value.flags.alive && decoded.value.last;
		assert decoded.value.flags.kind == CodecSparse.Nine && decoded.value.wide == CodecWide.Large;
		assert decoded.value.signed == CodecSigned.Below && decoded.value.amount == 0xffffffffffffffff;
		assert decoded.value.ratio == 1.5 && decoded.value.measure == -2.25;
		assert (decoded.value.serial as uint64) == 0x8000000000000000;
		assert (decoded.value.bits as uint8) == 5;
	}
}

test "account codec accepts ignored input padding but never copies it back into encoded output" {
	let bytes = goldenBytes();
	for (const offset of [11, 12, 13, 14, 15, 26, 27, 36, 37, 38, 39, 58, 59, 60, 61, 62, 63]) {
		bytes[offset] = 255;
	}
	const decoded = decode<CodecGolden>(bytes);
	assert decoded.ok;
	if (decoded.ok) {
		const encoded = encode(decoded.value);
		assert encoded.ok;
		if (encoded.ok) {
			const expected = goldenBytes();
			for (let i = 0; i < expected.length; i += 1) { assert encoded.value[i] == expected[i]; }
		}
	}
}

test "account codec uint64 extrema and numbers beyond JavaScript's exact Number band stay exact" {
	const words: uint64[] = [0, 1, 0x20000000000001, 0x8000000000000000, 0x8000000000000001, 0xffffffffffffffff];
	for (const word of words) {
		let value = golden();
		value.amount = word;
		value.serial = word as CodecAmount;
		const encoded = encode(value);
		assert encoded.ok;
		if (encoded.ok) {
			const decoded = decode<CodecGolden>(encoded.value);
			assert decoded.ok;
			if (decoded.ok) { assert decoded.value.amount == word && (decoded.value.serial as uint64) == word; }
		}
	}
}

test "account codec validates envelope errors in owner discriminator then data order" {
	let expected = Pubkey.zero();
	expected.bytes[0] = 7;
	let wrong = expected;
	wrong.bytes[0] = 8;
	const empty: uint8[0] = [];
	const owner = decode<CodecGolden>(empty, wrong, expected);
	assert !owner.ok;
	if (!owner.ok) { assert owner.error.code == 3007; }
	const missing = decode<CodecGolden>(empty, expected, expected);
	assert !missing.ok;
	if (!missing.ok) { assert missing.error.code == 3001; }
	const wrongTag: uint8[8] = [0, 0, 0, 0, 0, 0, 0, 0];
	assert decodeCode<CodecGolden>(wrongTag) == 3002;
	const onlyTag: uint8[8] = [1, 2, 3, 4, 5, 6, 7, 8];
	assert decodeCode<CodecGolden>(onlyTag) == 3003;
	const accepted = decode<CodecGolden>(goldenBytes(), expected, expected);
	assert accepted.ok;
}

test "account codec refuses sparse signed wide enum holes and invalid bool bytes including the tail" {
	for (const invalid of [2, 128, 255]) {
		let bytes = goldenBytes();
		bytes[9] = invalid as uint8;
		assert decodeCode<CodecGolden>(bytes) == 3003;
		bytes = goldenBytes();
		bytes[57] = invalid as uint8;
		assert decodeCode<CodecGolden>(bytes) == 3003;
	}
	let sparse = goldenBytes();
	sparse[10] = 1;
	assert decodeCode<CodecGolden>(sparse) == 3003;
	let wide = goldenBytes();
	wide[24] = 1;
	wide[25] = 1;
	assert decodeCode<CodecGolden>(wide) == 3003;
	let signed = goldenBytes();
	for (let i = 28; i < 32; i += 1) { signed[i] = 255; }
	assert decodeCode<CodecGolden>(signed) == 3003;
	let validPositive = goldenBytes();
	validPositive[28] = 0x70;
	validPositive[29] = 0x11;
	validPositive[30] = 1;
	validPositive[31] = 0;
	const positive = decode<CodecGolden>(validPositive);
	assert positive.ok;
	if (positive.ok) { assert positive.value.signed == CodecSigned.Above; }
}

test "account codec encode refuses sparse enum holes rather than producing undecodable bytes" {
	let value = golden();
	value.flags.kind = opaque(1) as CodecSparse;
	const sparse = encode(value);
	assert !sparse.ok;
	if (!sparse.ok) { assert sparse.error.code == 3003; }
	value = golden();
	value.wide = opaque(257) as CodecWide;
	const wide = encode(value);
	assert !wide.ok;
	if (!wide.ok) { assert wide.error.code == 3003; }
	value = golden();
	value.signed = opaque(-1) as CodecSigned;
	const signed = encode(value);
	assert !signed.ok;
	if (!signed.ok) { assert signed.error.code == 3003; }
}

test "account codec decode accepts a non-owning offset Span without copying or inspecting bytes outside the view" {
	const storage: uint8[] = new Array(76);
	for (let i = 0; i < storage.length; i += 1) { storage[i] = 255; }
	const expected = goldenBytes();
	for (let i = 0; i < expected.length; i += 1) { storage[5 + i] = expected[i]; }
	const view: Span<uint8> = storage[5..69];
	assert decodeCode<CodecGolden>(view) == 0;
	storage[5 + 57] = 2;
	assert decodeCode<CodecGolden>(view) == 3003;
	storage[5 + 57] = 1;
	const extended: Span<uint8> = storage[5..76];
	assert decodeCode<CodecGolden>(extended) == 0;
}

enum CodecHiddenKind { Zero = 50, Last = 60 }
struct CodecHiddenChild { shadow: uint64; }

test "account codec keeps imported hidden enum struct and fixed-array identities despite same-named local shadows" {
	const value = hiddenAccount();
	const encoded = encode(value);
	assert encoded.ok;
	if (encoded.ok) {
		const expected: uint8[18] = [11, 12, 13, 14, 15, 16, 17, 18, 7, 0, 9, 0, 9, 1, 0, 9, 0, 1];
		assert encoded.value.length == expected.length;
		for (let i = 0; i < expected.length; i += 1) { assert encoded.value[i] == expected[i]; }
		const decoded = decode<CodecHiddenAccount>(encoded.value);
		assert decoded.ok;
		if (decoded.ok) { assert hiddenAccountValid(decoded.value); }
		encoded.value[16] = 1;
		assert decodeCode<CodecHiddenAccount>(encoded.value) == 3003;
	}
	assert (CodecHiddenKind.Zero as int32) == 50;
	const shadow: CodecHiddenChild = { shadow: 10 };
	assert shadow.shadow == 10;
}

test "account codec float kernels preserve negative zero and finite extremal bit patterns" {
	let value = golden();
	value.ratio = -0.0;
	value.measure = -0.0;
	const encoded = encode(value);
	assert encoded.ok;
	if (encoded.ok) {
		assert encoded.value[35] == 0x80 && encoded.value[47] == 0x80;
		const decoded = decode<CodecGolden>(encoded.value);
		assert decoded.ok;
		if (decoded.ok) {
			assert accountFloat32Bits(decoded.value.ratio) == 0x80000000;
			assert accountFloat64Bits(decoded.value.measure) == 0x8000000000000000;
		}
	}
}

struct CodecWidths {
	i8: int8; u8: uint8; i16: int16; u16: uint16;
	i32: int32; u32: uint32; i64: int64; u64: uint64;
}

export function discriminator(this typeof CodecWidths): Discriminator {
	return { bytes: [0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28] };
}

test "account codec preserves each signed and unsigned integer width at its extrema" {
	const value: CodecWidths = {
		i8: -128, u8: 255, i16: -32768, u16: 65535,
		i32: -2147483648, u32: 0xffffffff,
		i64: -9223372036854775808, u64: 0xffffffffffffffff,
	};
	const expected: uint8[40] = [
		0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
		0x80, 255, 0, 0x80, 255, 255, 0, 0,
		0, 0, 0, 0x80, 255, 255, 255, 255,
		0, 0, 0, 0, 0, 0, 0, 0x80,
		255, 255, 255, 255, 255, 255, 255, 255,
	];
	const encoded = encode(value);
	assert encoded.ok;
	if (encoded.ok) {
		assert encoded.value.length == expected.length;
		for (let i = 0; i < expected.length; i += 1) { assert encoded.value[i] == expected[i]; }
	}
	const decoded = decode<CodecWidths>(expected);
	assert decoded.ok;
	if (decoded.ok) {
		assert decoded.value.i8 == value.i8 && decoded.value.u8 == value.u8;
		assert decoded.value.i16 == value.i16 && decoded.value.u16 == value.u16;
		assert decoded.value.i32 == value.i32 && decoded.value.u32 == value.u32;
		assert decoded.value.i64 == value.i64 && decoded.value.u64 == value.u64;
	}
}

enum CodecManyBit {
	B0, B1, B2, B3, B4, B5, B6, B7, B8, B9,
	B10, B11, B12, B13, B14, B15, B16, B17, B18, B19,
	B20, B21, B22, B23, B24, B25, B26, B27, B28, B29,
	B30, B31, B32, B33, B34, B35, B36, B37, B38, B39,
	B40, B41, B42, B43, B44, B45, B46, B47, B48, B49,
	B50, B51, B52, B53, B54, B55, B56, B57, B58, B59,
	B60, B61, B62, B63, B64,
}

struct CodecSets { word: BitSet<CodecBit>; bytes: BitSet<CodecManyBit>; }

export function discriminator(this typeof CodecSets): Discriminator {
	return { bytes: [31, 32, 33, 34, 35, 36, 37, 38] };
}

test "account codec preserves both word and byte-array BitSet raw storage without ordinal conversion" {
	const large = (0 as BitSet<CodecManyBit>).incl(CodecManyBit.B0).incl(CodecManyBit.B64);
	const value: CodecSets = { word: (5 as uint8) as BitSet<CodecBit>, bytes: large };
	const encoded = encode(value);
	assert encoded.ok;
	if (encoded.ok) {
		const expected: uint8[18] = [31, 32, 33, 34, 35, 36, 37, 38, 5, 1, 0, 0, 0, 0, 0, 0, 0, 1];
		assert encoded.value.length == expected.length;
		for (let i = 0; i < expected.length; i += 1) { assert encoded.value[i] == expected[i]; }
		const decoded = decode<CodecSets>(encoded.value);
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.word == value.word && decoded.value.bytes == value.bytes;
			assert decoded.value.bytes.has(CodecManyBit.B0) && decoded.value.bytes.has(CodecManyBit.B64);
		}
	}
}

test "account codec floats retain smallest subnormals and largest finite values on both widths" {
	const single: uint32[] = [1, 0x7f7fffff, 0x80000001];
	const double: uint64[] = [1, 0x7fefffffffffffff, 0x8000000000000001];
	for (let i = 0; i < single.length; i += 1) {
		let value = golden();
		value.ratio = accountFloat32FromBits(single[i]);
		value.measure = accountFloat64FromBits(double[i]);
		const encoded = encode(value);
		assert encoded.ok;
		if (encoded.ok) {
			const decoded = decode<CodecGolden>(encoded.value);
			assert decoded.ok;
			if (decoded.ok) {
				assert accountFloat32Bits(decoded.value.ratio) == single[i];
				assert accountFloat64Bits(decoded.value.measure) == double[i];
			}
		}
	}
}
