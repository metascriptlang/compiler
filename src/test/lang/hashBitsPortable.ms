// The 64x64 -> 128 mix behind hashWangYi1 gives the same bits through the four 32x32 partial products
// that a target without a 128-bit integer (i386, arm) takes as through the 128-bit product.
// Expected values are the high half XOR low half of the exact product.
extern function hiXorLoWide(a: uint64, b: uint64): uint64 from "msHiXorLo";
extern function hiXorLoPortable(a: uint64, b: uint64): uint64 from "msHiXorLoPortable";

const ALL_ONES = 0xffffffffffffffff as uint64;

function agree(a: uint64, b: uint64, expected: uint64): boolean {
	return hiXorLoPortable(a, b) == expected && hiXorLoWide(a, b) == expected;
}

test "the portable mix equals the exact product for zero and one" {
	assert agree(0 as uint64, 0 as uint64, 0 as uint64);
	assert agree(1 as uint64, 1 as uint64, 1 as uint64);
}

test "the portable mix equals the exact product for all-ones operands" {
	assert agree(ALL_ONES, ALL_ONES, ALL_ONES);
	assert agree(ALL_ONES, 1 as uint64, ALL_ONES);
}

test "the portable mix carries between the 32-bit halves" {
	assert agree(0xffffffff as uint64, 0xffffffff as uint64, 0xfffffffe00000001 as uint64);
	assert agree(0x100000000 as uint64, 0x100000000 as uint64, 1 as uint64);
	assert agree(0x8000000000000000 as uint64, 2 as uint64, 1 as uint64);
	assert agree(0x8000000080000000 as uint64, 0x8000000080000000 as uint64, 0x80000000 as uint64);
}

test "the portable mix equals the exact product for the hash constants and arbitrary high bits" {
	assert agree(0xa0761d6478bd642f as uint64, 0xe7037ed1a0b428db as uint64, 0x1ff5c2923a788d2c as uint64);
	assert agree(0xdeadbeefcafebabe as uint64, 0x0123456789abcdef as uint64, 0x7e4bd22a04f6dd7f as uint64);
}
